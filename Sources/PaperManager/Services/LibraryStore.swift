import AppKit
import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot
    @Published var statusMessage: String?
    @Published var isBusy = false

    let persistenceURL: URL

    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.snapshot = .empty
        load()
    }

    var papers: [Paper] {
        snapshot.papers.sorted { lhs, rhs in
            lhs.dateAdded > rhs.dateAdded
        }
    }

    var collections: [PaperCollection] { snapshot.collections }
    var tags: [PaperTag] {
        snapshot.tags.sorted {
            if $0.sortIndex == $1.sortIndex {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sortIndex < $1.sortIndex
        }
    }

    var settings: AppSettings { snapshot.settings }

    static func defaultPersistenceURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("PaperManager", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    func load() {
        do {
            guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
                snapshot = .empty
                return
            }
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        } catch {
            statusMessage = "Failed to load library: \(error.localizedDescription)"
            snapshot = .empty
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            statusMessage = "Failed to save library: \(error.localizedDescription)"
        }
    }

    func replaceSnapshot(_ newSnapshot: LibrarySnapshot) {
        snapshot = newSnapshot
        save()
    }

    func updateSettings(_ settings: AppSettings) {
        snapshot.settings = settings
        save()
    }

    func updateSetting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, value: Value) {
        snapshot.settings[keyPath: keyPath] = value
        save()
    }

    func paper(with id: UUID) -> Paper? {
        snapshot.papers.first { $0.id == id }
    }

    func filteredPapers(
        for filter: LibraryFilter,
        searchText: String,
        includeSubcollections: Bool,
        sortDescriptor: PaperSortDescriptor = .defaultValue
    ) -> [Paper] {
        let query = searchText.trimmed.lowercased()
        let filtered = papers.filter { paper in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .recentlyAdded:
                matchesFilter = Date().timeIntervalSince(paper.dateAdded) <= 60 * 60 * 24 * 30
            case .recentlyOpened:
                matchesFilter = paper.lastOpenedAt != nil
            case .unfiled:
                matchesFilter = paper.collectionIDs.isEmpty
            case .missingPDF:
                matchesFilter = !paper.hasPDF
            case .missingIDs:
                matchesFilter = !paper.hasIdentifier
            case .noTags:
                matchesFilter = paper.tagIDs.isEmpty
            case .rating(let value):
                matchesFilter = paper.rating == value
            case .collection(let id):
                let ids = includeSubcollections ? snapshot.collections.descendantIDs(of: id) : [id]
                matchesFilter = paper.collectionIDs.contains { ids.contains($0) }
            case .tag(let id):
                matchesFilter = paper.tagIDs.contains(id)
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            let collectionText = paper.collectionIDs
                .map { snapshot.collections.path(for: $0) }
                .joined(separator: " ")
            let tagText = paper.tagIDs
                .compactMap { id in snapshot.tags.first(where: { $0.id == id })?.name }
                .joined(separator: " ")
            return [
                paper.title,
                paper.subtitle ?? "",
                paper.authorsDisplay,
                (paper.editors ?? []).joined(separator: " "),
                (paper.translators ?? []).joined(separator: " "),
                paper.sourceDisplay,
                paper.year.map(String.init) ?? "",
                paper.doi,
                paper.isbn,
                paper.eprint,
                paper.citekey,
                paper.abstract,
                paper.notes,
                collectionText,
                tagText,
                paper.customFields.map { "\($0.key) \($0.value)" }.joined(separator: " ")
            ].joined(separator: " ").lowercased().contains(query)
        }
        return sort(filtered, by: sortDescriptor)
    }

    @discardableResult
    func addPaper(_ incoming: Paper, targetFilter: LibraryFilter? = nil) -> UUID {
        var paper = incoming
        paper.id = incoming.id
        paper.dateAdded = incoming.dateAdded
        paper.dateModified = Date()
        apply(targetFilter: targetFilter, to: &paper)
        normalizeCitekey(for: &paper)
        snapshot.papers.append(paper)
        save()
        return paper.id
    }

    @discardableResult
    func addOrReplacePaper(_ incoming: Paper, targetFilter: LibraryFilter? = nil, replaceDuplicate: Bool = false) -> UUID {
        if let duplicateID = duplicatePaperID(for: incoming) {
            if replaceDuplicate {
                var replacement = incoming
                replacement.id = duplicateID
                replacement.dateAdded = paper(with: duplicateID)?.dateAdded ?? Date()
                if replacement.citekey.isEmpty {
                    replacement.citekey = paper(with: duplicateID)?.citekey ?? ""
                }
                apply(targetFilter: targetFilter, to: &replacement)
                updatePaper(replacement)
                return duplicateID
            }
            return duplicateID
        }
        return addPaper(incoming, targetFilter: targetFilter)
    }

    func updatePaper(_ paper: Paper) {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paper.id }) else { return }
        guard !snapshot.papers[index].hasSameEditableContent(as: paper) else { return }
        var updated = paper
        updated.dateModified = Date()
        if updated.citekey.trimmed.isEmpty {
            normalizeCitekey(for: &updated)
        }
        snapshot.papers[index] = updated
        save()
    }

    func markOpened(_ paperID: UUID) {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        snapshot.papers[index].lastOpenedAt = Date()
        snapshot.papers[index].dateModified = Date()
        save()
    }

    func updateAnnotations(_ annotations: [ResearchAnnotation], for paperID: UUID) {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        snapshot.papers[index].annotations = annotations
        snapshot.papers[index].dateModified = Date()
        save()
    }

    func deletePapers(ids: Set<UUID>) {
        let deleting = snapshot.papers.filter { ids.contains($0.id) }
        if snapshot.settings.deleteAttachmentsToTrash {
            for attachment in deleting.flatMap(\.attachments) {
                try? attachment.withResolvedURL { url in
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }
        snapshot.papers.removeAll { ids.contains($0.id) }
        save()
    }

    @discardableResult
    func addCollection(name: String = "New Collection", parentID: UUID? = nil) -> UUID {
        let nextIndex = snapshot.collections.filter { $0.parentID == parentID }.count
        let collection = PaperCollection(name: uniqueCollectionName(base: name, parentID: parentID), parentID: parentID, sortIndex: nextIndex)
        snapshot.collections.append(collection)
        save()
        return collection.id
    }

    func renameCollection(id: UUID, name: String) {
        guard let index = snapshot.collections.firstIndex(where: { $0.id == id }) else { return }
        snapshot.collections[index].name = name.trimmed.isEmpty ? "Untitled Collection" : name.trimmed
        save()
    }

    func deleteCollection(id: UUID) {
        let ids = snapshot.collections.descendantIDs(of: id)
        snapshot.collections.removeAll { ids.contains($0.id) }
        for index in snapshot.papers.indices {
            snapshot.papers[index].collectionIDs.removeAll { ids.contains($0) }
        }
        save()
    }

    func addPapers(ids: Set<UUID>, toCollection collectionID: UUID) {
        guard snapshot.collections.contains(where: { $0.id == collectionID }) else { return }
        var didChange = false
        for index in snapshot.papers.indices where ids.contains(snapshot.papers[index].id) {
            if !snapshot.papers[index].collectionIDs.contains(collectionID) {
                snapshot.papers[index].collectionIDs.append(collectionID)
                snapshot.papers[index].dateModified = Date()
                didChange = true
            }
        }
        if didChange { save() }
    }

    @discardableResult
    func addTag(name: String = "New Tag", colorHex: String = "#5B8DEF") -> UUID {
        let tag = PaperTag(name: uniqueTagName(base: name), colorHex: colorHex, sortIndex: snapshot.tags.count)
        snapshot.tags.append(tag)
        save()
        return tag.id
    }

    func renameTag(id: UUID, name: String) {
        guard let index = snapshot.tags.firstIndex(where: { $0.id == id }) else { return }
        snapshot.tags[index].name = name.trimmed.isEmpty ? "Untitled Tag" : name.trimmed
        save()
    }

    func updateTagColor(id: UUID, colorHex: String) {
        guard let index = snapshot.tags.firstIndex(where: { $0.id == id }) else { return }
        snapshot.tags[index].colorHex = colorHex
        save()
    }

    func deleteTag(id: UUID) {
        snapshot.tags.removeAll { $0.id == id }
        for index in snapshot.papers.indices {
            snapshot.papers[index].tagIDs.removeAll { $0 == id }
        }
        save()
    }

    func addPapers(ids: Set<UUID>, toTag tagID: UUID) {
        guard snapshot.tags.contains(where: { $0.id == tagID }) else { return }
        var didChange = false
        for index in snapshot.papers.indices where ids.contains(snapshot.papers[index].id) {
            if !snapshot.papers[index].tagIDs.contains(tagID) {
                snapshot.papers[index].tagIDs.append(tagID)
                snapshot.papers[index].dateModified = Date()
                didChange = true
            }
        }
        if didChange { save() }
    }

    func attachFile(_ sourceURL: URL, to paperID: UUID, kind: AttachmentKind? = nil) throws {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        var paper = snapshot.papers[index]
        let finalURL = try organizeAttachmentIfNeeded(sourceURL, for: paper)
        let bookmark = try? finalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let fileSize = try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        let attachment = Attachment(
            kind: kind ?? (finalURL.isPDF ? .pdf : .file),
            filePath: finalURL.path,
            displayName: finalURL.lastPathComponent,
            bookmarkData: bookmark,
            fileSize: fileSize,
            missing: !FileManager.default.fileExists(atPath: finalURL.path)
        )
        paper.attachments.removeAll { $0.filePath == finalURL.path }
        paper.attachments.append(attachment)
        snapshot.papers[index] = paper
        save()
    }

    func regenerateCitekeys() {
        var existing = Set<String>()
        for index in snapshot.papers.indices {
            snapshot.papers[index].citekey = CitekeyGenerator.generate(
                for: snapshot.papers[index],
                format: snapshot.settings.citekeyFormat,
                existing: existing
            )
            existing.insert(snapshot.papers[index].citekey)
        }
        save()
    }

    func duplicatePaperID(for paper: Paper) -> UUID? {
        let doi = paper.doi.trimmed.lowercased()
        let isbn = paper.isbn.trimmed.lowercased()
        let eprint = paper.eprint.trimmed.lowercased()
        let title = paper.title.trimmed.lowercased()
        return snapshot.papers.first { existing in
            if existing.id == paper.id { return false }
            if !doi.isEmpty && existing.doi.trimmed.lowercased() == doi { return true }
            if !isbn.isEmpty && existing.isbn.trimmed.lowercased() == isbn { return true }
            if !eprint.isEmpty && existing.eprint.trimmed.lowercased() == eprint { return true }
            if !title.isEmpty && existing.title.trimmed.lowercased() == title {
                return existing.year == paper.year
            }
            return false
        }?.id
    }

    private func apply(targetFilter: LibraryFilter?, to paper: inout Paper) {
        switch targetFilter {
        case .collection(let id):
            if !paper.collectionIDs.contains(id) { paper.collectionIDs.append(id) }
        case .tag(let id):
            if !paper.tagIDs.contains(id) { paper.tagIDs.append(id) }
        default:
            break
        }
    }

    private func normalizeCitekey(for paper: inout Paper) {
        let existing = Set(snapshot.papers.filter { $0.id != paper.id }.map(\.citekey).filter { !$0.isEmpty })
        paper.citekey = CitekeyGenerator.generate(for: paper, format: snapshot.settings.citekeyFormat, existing: existing)
    }

    private func sort(_ papers: [Paper], by descriptor: PaperSortDescriptor) -> [Paper] {
        papers.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch descriptor.field {
            case .title:
                comparison = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            case .authors:
                comparison = lhs.authorsDisplay.localizedStandardCompare(rhs.authorsDisplay)
            case .year:
                comparison = compareOptional(lhs.year, rhs.year)
            case .source:
                comparison = lhs.sourceDisplay.localizedStandardCompare(rhs.sourceDisplay)
            case .rating:
                comparison = compareValues(lhs.rating, rhs.rating)
            case .dateAdded:
                comparison = compareValues(lhs.dateAdded, rhs.dateAdded)
            case .lastOpened:
                comparison = compareOptional(lhs.lastOpenedAt, rhs.lastOpenedAt)
            }

            if comparison == .orderedSame {
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedAscending
        case (.some, .none):
            return .orderedDescending
        case (.some(let lhs), .some(let rhs)):
            return compareValues(lhs, rhs)
        }
    }

    private func uniqueCollectionName(base: String, parentID: UUID?) -> String {
        uniqueName(base: base, existing: Set(snapshot.collections.filter { $0.parentID == parentID }.map(\.name)))
    }

    private func uniqueTagName(base: String) -> String {
        uniqueName(base: base, existing: Set(snapshot.tags.map(\.name)))
    }

    private func uniqueName(base: String, existing: Set<String>) -> String {
        let clean = base.trimmed.isEmpty ? "Untitled" : base.trimmed
        if !existing.contains(clean) { return clean }
        var index = 2
        while existing.contains("\(clean) \(index)") {
            index += 1
        }
        return "\(clean) \(index)"
    }

    private func organizeAttachmentIfNeeded(_ sourceURL: URL, for paper: Paper) throws -> URL {
        guard sourceURL.isPDF else { return sourceURL }
        let settings = snapshot.settings
        guard settings.pdfOrganizationMode != .none else { return sourceURL }
        guard let root = settings.pdfOrganizationFolder.nilIfBlank.map(URL.init(fileURLWithPath:)) else {
            throw PaperManagerError.message("No destination folder configured. Please set one in Settings > General.")
        }

        var destinationFolder = root
        switch settings.pdfSubfolderGrouping {
        case .none:
            break
        case .year:
            destinationFolder.appendPathComponent(paper.year.map(String.init) ?? "Unknown Year", isDirectory: true)
        case .authorInitial:
            destinationFolder.appendPathComponent(CitekeyGenerator.firstAuthorLastName(paper).prefix(1).uppercased(), isDirectory: true)
        case .collection:
            if let firstID = paper.collectionIDs.first {
                destinationFolder.appendPathComponent(snapshot.collections.path(for: firstID), isDirectory: true)
            }
        }
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let baseName: String
        if settings.autoRenamePDFs {
            baseName = CitekeyGenerator.render(format: settings.pdfRenameTemplate, paper: paper)
                .sanitizedFileName(fallback: paper.displayTitle.sanitizedFileName())
        } else {
            baseName = sourceURL.deletingPathExtension().lastPathComponent
        }

        var destination = destinationFolder.appendingPathComponent(baseName).appendingPathExtension("pdf")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) && destination.path != sourceURL.path {
            destination = destinationFolder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension("pdf")
            suffix += 1
        }

        if destination.path == sourceURL.path { return sourceURL }
        if settings.confirmBeforeMovingFiles {
            guard confirmOrganizationOperation(mode: settings.pdfOrganizationMode, source: sourceURL, destination: destination) else {
                throw PaperManagerError.message("已取消文件整理。PDF 仍保留在原位置，文献记录未修改附件路径。")
            }
        }

        switch settings.pdfOrganizationMode {
        case .copy:
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        case .move:
            try FileManager.default.moveItem(at: sourceURL, to: destination)
        case .none:
            break
        }
        return destination
    }

    private func confirmOrganizationOperation(mode: PDFOrganizationMode, source: URL, destination: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch mode {
        case .copy:
            alert.messageText = "复制 PDF 到文库文件夹？"
            alert.informativeText = "\(source.lastPathComponent)\n\n将复制到：\n\(destination.path)"
        case .move:
            alert.messageText = "移动 PDF 到文库文件夹？"
            alert.informativeText = "\(source.lastPathComponent)\n\n将从原位置移动到：\n\(destination.path)"
        case .none:
            return true
        }
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
