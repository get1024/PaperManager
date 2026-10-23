import Foundation
import PDFKit

struct ImportSummary {
    var imported = 0
    var replaced = 0
    var skipped = 0
    var failed = 0
    var messages: [String] = []

    var text: String {
        var parts = [PMLocalization.format("已导入 %d", imported)]
        if replaced > 0 { parts.append(PMLocalization.format("已替换 %d", replaced)) }
        if skipped > 0 { parts.append(PMLocalization.format("已跳过 %d", skipped)) }
        if failed > 0 { parts.append(PMLocalization.format("失败 %d", failed)) }
        return parts.joined(separator: " / ")
    }
}

enum ImportDuplicateAction: String, CaseIterable, Identifiable {
    case skip, replace
    var id: String { rawValue }
    var label: String { PMLocalization.text(self == .skip ? "跳过" : "替换书目信息") }
}

struct ImportCandidate: Identifiable {
    let id = UUID()
    var paper: Paper
    var sourceURL: URL?
    var duplicateID: UUID?
    var isSelected = true
    var duplicateAction: ImportDuplicateAction = .skip
}

// Keep the user's folder grant alive between preparation and confirmation.
final class ImportFileAccess {
    private let accessedURLs: [URL]
    init(urls: [URL]) {
        accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
}

struct ImportPlan: Identifiable {
    let id = UUID()
    var candidates: [ImportCandidate]
    var failures: [String] = []
    var unsupportedFiles = 0
    var fileAccess: ImportFileAccess?
}

@MainActor
enum ImportService {
    static func importURLs(_ urls: [URL], into store: LibraryStore, targetFilter: LibraryFilter?) async -> ImportSummary {
        let plan = await prepare(urls, store: store)
        return await commit(plan, into: store, targetFilter: targetFilter)
    }

    static func prepare(_ urls: [URL], store: LibraryStore) async -> ImportPlan {
        var plan = ImportPlan(candidates: [], fileAccess: ImportFileAccess(urls: urls))
        for url in expand(urls: urls) {
            if Task.isCancelled { break }
            do {
                let papers: [Paper]
                if url.isPDF {
                    papers = try await Task.detached(priority: .userInitiated) {
                        guard PDFDocument(url: url) != nil else {
                            throw PaperManagerError.message("无法读取 PDF，文件可能已损坏。")
                        }
                        var paper = PDFMetadataExtractor.extract(from: url)
                        paper.attachments = []
                        return [paper]
                    }.value
                } else if url.isBibTeX {
                    let text = try readText(url)
                    papers = await Task.detached { BibTeXParser.parse(text) }.value
                } else if url.isRIS {
                    let text = try readText(url)
                    papers = await Task.detached { RISParser.parse(text) }.value
                } else {
                    plan.unsupportedFiles += 1
                    continue
                }
                if papers.isEmpty {
                    plan.failures.append("\(url.lastPathComponent)：没有可导入的文献记录。")
                }
                for paper in papers {
                    plan.candidates.append(ImportCandidate(
                        paper: paper, sourceURL: url.isPDF ? url : nil,
                        duplicateID: store.duplicatePaperID(for: paper)
                    ))
                }
            } catch {
                plan.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return plan
    }

    static func prepare(papers: [Paper], store: LibraryStore) -> ImportPlan {
        ImportPlan(candidates: papers.map {
            ImportCandidate(paper: $0, duplicateID: store.duplicatePaperID(for: $0))
        })
    }

    static func commit(_ plan: ImportPlan, into store: LibraryStore, targetFilter: LibraryFilter?) async -> ImportSummary {
        var summary = ImportSummary(skipped: plan.unsupportedFiles, failed: plan.failures.count, messages: plan.failures)
        var refreshIDs: [UUID] = []
        var importedPDFs: [UUID: Paper] = [:]
        // Metadata lookup starts only after committed imports are visible. The
        // shared bounded queue also covers BibTeX/RIS and ISBN/title-only works.
        defer {
            if store.settings.autoExtractMetadataAfterImport {
                store.enqueueMetadataRefresh(paperIDs: refreshIDs, replacingUneditedFieldsFrom: importedPDFs)
            }
        }
        for candidate in plan.candidates {
            if Task.isCancelled { break }
            guard candidate.isSelected else { summary.skipped += 1; continue }
            do {
                let incoming = candidate.paper
                if Task.isCancelled { break }
                let targetMissing: Bool
                switch targetFilter {
                case .collection(let id): targetMissing = !store.collections.contains { $0.id == id }
                case .tag(let id): targetMissing = !store.tags.contains { $0.id == id }
                default: targetMissing = false
                }
                let missingTargetMessage = PMLocalization.text("原先选择的文集或标签已删除；文献将保存在全部文献中。")
                if targetMissing, !summary.messages.contains(missingTargetMessage) { summary.messages.append(missingTargetMessage) }
                // Recheck at commit: another window, or an earlier item in this batch,
                // may have inserted a matching paper since the preview was opened.
                let duplicate = store.paper(with: incoming.id)
                    ?? store.duplicatePaperID(for: incoming).flatMap { store.paper(with: $0) }
                if duplicate != nil, candidate.duplicateAction == .skip {
                    summary.skipped += 1
                    continue
                }
                let id: UUID
                if let existing = duplicate {
                    var importedDraft = incoming
                    importedDraft.id = existing.id
                    var emptyBaseline = Paper()
                    emptyBaseline.id = existing.id
                    var replacement = importedDraft.applyingEdits(to: existing, from: emptyBaseline)
                    replacement.id = existing.id
                    replacement.paperType = incoming.paperType
                    replacement.dateAdded = existing.dateAdded
                    replacement.lastOpenedAt = existing.lastOpenedAt
                    replacement.attachments = existing.attachments
                    replacement.annotations = existing.annotations
                    replacement.rating = existing.rating
                    replacement.notes = existing.notes
                    replacement.collectionIDs = Array(Set(existing.collectionIDs + incoming.collectionIDs))
                    replacement.tagIDs = Array(Set(existing.tagIDs + incoming.tagIDs))
                    try store.updatePaperDurably(replacement, targetFilter: targetFilter)
                    id = existing.id
                } else {
                    id = try store.addPaperDurably(incoming, targetFilter: targetFilter)
                }
                do {
                    if let sourceURL = candidate.sourceURL {
                        try store.attachFile(sourceURL, to: id, kind: .pdf)
                    }
                } catch {
                    // Attachment setup is synchronous. Roll back only this item;
                    // never replace the whole library after an asynchronous task.
                    do {
                        try store.performDurableMutation { snapshot in
                            if let duplicate, let index = snapshot.papers.firstIndex(where: { $0.id == id }) {
                                snapshot.papers[index] = duplicate
                            } else { snapshot.papers.removeAll { $0.id == id } }
                        }
                    } catch {
                        throw PaperManagerError.message("附件导入失败，元数据回滚未能保存；请检查文库：\(error.localizedDescription)")
                    }
                    throw error
                }
                refreshIDs.append(id)
                if candidate.sourceURL != nil { importedPDFs[id] = store.paper(with: id) }
                if duplicate == nil, candidate.sourceURL != nil, store.settings.autoExtractAnnotationsAfterImport,
                   let attachment = store.paper(with: id)?.primaryPDF {
                    let previousAnnotations = store.paper(with: id)?.annotations ?? []
                    do {
                        let annotations = try await extractAnnotations(from: attachment, paperID: id)
                        if let current = store.paper(with: id), current.primaryPDF?.id == attachment.id,
                           current.annotations == previousAnnotations {
                            var refreshed = current
                            refreshed.annotations = annotations
                            try store.updatePaperDurably(refreshed)
                        }
                    } catch {
                        summary.messages.append("文献已导入，但标注未提取：\(error.localizedDescription)")
                    }
                }
                if duplicate == nil { summary.imported += 1 } else { summary.replaced += 1 }
            } catch {
                summary.failed += 1
                summary.messages.append("\(candidate.paper.displayTitle)：\(error.localizedDescription)")
            }
            store.statusMessage = summary.text
        }
        store.statusMessage = summary.messages.isEmpty ? summary.text : "\(summary.text)。\(summary.messages.joined(separator: "；"))"
        return summary
    }

    static func lookupPaper(_ query: String) async throws -> Paper {
        let clean = query.trimmed
        let metadata = try await MetadataLookupClient.lookup(
            doi: clean.looksLikeDOI ? clean : nil,
            arxivID: clean.looksLikeArxivID ? clean : nil,
            isbn: clean.looksLikeISBN ? clean : nil,
            title: clean.looksLikeDOI || clean.looksLikeArxivID || clean.looksLikeISBN ? nil : clean
        )
        return metadata.asPaper
    }

    static func extractAnnotations(from attachment: Attachment, paperID: UUID) async throws -> [ResearchAnnotation] {
        try await Task.detached(priority: .userInitiated) {
            try attachment.withResolvedURL { url in
                guard let document = PDFDocument(url: url) else {
                    throw PaperManagerError.message("PDFKit 无法读取这个 PDF。请确认文件没有损坏，且 PaperManager 仍有访问权限。")
                }
                let imageDirectory = try PDFMetadataExtractor.defaultAnnotationImageDirectory()
                    .appendingPathComponent(paperID.uuidString, isDirectory: true)
                return PDFMetadataExtractor.extractAnnotations(from: document, imageDirectory: imageDirectory, paperID: paperID)
            }
        }.value
    }

    private static func expand(urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = enumerator?.nextObject() as? URL {
                    if file.isPDF || file.isBibTeX || file.isRIS {
                        files.append(file)
                    }
                }
            } else {
                files.append(url)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .macOSRoman) {
            return text
        }
        throw PaperManagerError.message("Could not read text file.")
    }
}
