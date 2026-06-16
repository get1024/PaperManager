import Foundation
import PDFKit

struct ImportSummary {
    var imported = 0
    var skipped = 0
    var failed = 0
    var messages: [String] = []

    var text: String {
        var parts = ["Imported \(imported)"]
        if skipped > 0 { parts.append("Skipped \(skipped)") }
        if failed > 0 { parts.append("Failed \(failed)") }
        return parts.joined(separator: " / ")
    }
}

@MainActor
enum ImportService {
    static func importURLs(_ urls: [URL], into store: LibraryStore, targetFilter: LibraryFilter?) async -> ImportSummary {
        var summary = ImportSummary()
        let files = expand(urls: urls)

        for url in files {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                if url.isPDF {
                    try await importPDF(url, into: store, targetFilter: targetFilter)
                    summary.imported += 1
                } else if url.isBibTeX {
                    let papers = BibTeXParser.parse(try readText(url))
                    for paper in papers {
                        store.addOrReplacePaper(paper, targetFilter: targetFilter)
                    }
                    summary.imported += papers.count
                } else if url.isRIS {
                    let papers = RISParser.parse(try readText(url))
                    for paper in papers {
                        store.addOrReplacePaper(paper, targetFilter: targetFilter)
                    }
                    summary.imported += papers.count
                } else {
                    summary.skipped += 1
                }
            } catch {
                summary.failed += 1
                summary.messages.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            store.statusMessage = summary.text
        }

        store.statusMessage = summary.messages.isEmpty ? summary.text : "\(summary.text). \(summary.messages.joined(separator: "; "))"
        return summary
    }

    static func addViaDOI(_ doi: String, into store: LibraryStore, targetFilter: LibraryFilter?) async throws -> UUID {
        let metadata = try await MetadataLookupClient.lookup(doi: doi, arxivID: nil, isbn: nil, title: nil)
        return store.addOrReplacePaper(metadata.asPaper, targetFilter: targetFilter)
    }

    static func addViaLookup(_ query: String, into store: LibraryStore, targetFilter: LibraryFilter?) async throws -> UUID {
        let clean = query.trimmed
        let metadata = try await MetadataLookupClient.lookup(
            doi: clean.looksLikeDOI ? clean : nil,
            arxivID: clean.looksLikeArxivID ? clean : nil,
            isbn: clean.looksLikeISBN ? clean : nil,
            title: clean.looksLikeDOI || clean.looksLikeArxivID || clean.looksLikeISBN ? nil : clean
        )
        return store.addOrReplacePaper(metadata.asPaper, targetFilter: targetFilter)
    }

    private static func importPDF(_ url: URL, into store: LibraryStore, targetFilter: LibraryFilter?) async throws {
        var paper = await Task.detached(priority: .userInitiated) {
            PDFMetadataExtractor.extract(from: url)
        }.value
        if store.settings.autoExtractMetadataAfterImport, let metadata = try? await enrichIfPossible(paper: paper) {
            paper = metadata
        }
        paper.attachments = []
        let id = store.addOrReplacePaper(paper, targetFilter: targetFilter)
        try store.attachFile(url, to: id, kind: .pdf)
        if store.settings.autoExtractAnnotationsAfterImport,
           let attachment = store.paper(with: id)?.primaryPDF {
            let annotations = try await extractAnnotations(from: attachment, paperID: id)
            store.updateAnnotations(annotations, for: id)
        }
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

    private static func enrichIfPossible(paper: Paper) async throws -> Paper {
        let metadata = try await MetadataLookupClient.lookup(
            doi: paper.doi.nilIfBlank,
            arxivID: paper.arxivLookupID,
            isbn: nil,
            title: nil
        )
        return metadata.merged(into: paper, replaceExisting: true)
    }

    private static func expand(urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
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
        return files
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
