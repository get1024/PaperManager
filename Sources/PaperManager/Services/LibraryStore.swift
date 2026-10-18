import AppKit
import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published private(set) var loadError: String?

    let persistenceURL: URL
    private let trashFile: (URL) throws -> Void

    init(persistenceURL: URL? = nil, trashFile: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.trashFile = trashFile
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
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("PaperManager", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    func load() {
        loadError = nil
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
            loadError = statusMessage
            snapshot = .empty
        }
    }

    func save() {
        guard loadError == nil else {
            statusMessage = "文库无法读取，已停止保存以保护原文件。请从备份恢复或选择另一个文库。"
            return
        }
        do {
            try writeSnapshot(snapshot)
        } catch {
            statusMessage = "Failed to save library: \(error.localizedDescription)"
        }
    }

    func replaceSnapshot(_ newSnapshot: LibrarySnapshot) {
        do { try replaceSnapshotDurably(newSnapshot) }
        catch { statusMessage = "保存文库失败：\(error.localizedDescription)" }
    }

    /// Mutations are prepared on a value copy. Neither published state nor a
    /// success result changes until the atomic persistence operation succeeds.
    @discardableResult
    func performDurableMutation<Value>(_ mutation: (inout LibrarySnapshot) throws -> Value) throws -> Value {
        guard loadError == nil else {
            throw PaperManagerError.message("当前文库无法读取，已停止保存以保护原文件。")
        }
        var updated = snapshot
        let result = try mutation(&updated)
        try writeSnapshot(updated)
        snapshot = updated
        return result
    }

    /// Uses lossless dates so edits within the same second also invalidate a
    /// restore prepared in another window. The token never leaves this process.
    func snapshotRevisionToken() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(snapshot)
    }

    func requireUnchangedSnapshot(since revision: Data) throws {
        guard try snapshotRevisionToken() == revision else {
            throw PaperManagerError.message("准备恢复期间文库已在其他窗口更改；已停止恢复，请重新检查并确认。")
        }
    }

    func replaceSnapshotDurably(_ newSnapshot: LibrarySnapshot, expectedRevision: Data? = nil) throws {
        if let expectedRevision { try requireUnchangedSnapshot(since: expectedRevision) }
        // Never overwrite an unreadable existing library during restore.
        if loadError != nil, FileManager.default.fileExists(atPath: persistenceURL.path) {
            let preserved = persistenceURL.deletingLastPathComponent()
                .appendingPathComponent("library-unreadable-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: persistenceURL, to: preserved)
        }
        try writeSnapshot(newSnapshot)
        snapshot = newSnapshot
        loadError = nil
    }

    private func writeSnapshot(_ value: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: persistenceURL, options: [.atomic])
    }

    func updateSettings(_ settings: AppSettings) {
        let previousFormat = snapshot.settings.citekeyFormat
        snapshot.settings = settings
        if settings.citekeyFormat != previousFormat {
            regenerateCitekeysWithoutSaving()
        }
        save()
    }

    func updateSetting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, value: Value) {
        let previousFormat = snapshot.settings.citekeyFormat
        snapshot.settings[keyPath: keyPath] = value
        if snapshot.settings.citekeyFormat != previousFormat {
            regenerateCitekeysWithoutSaving()
        }
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
    func addPaperDurably(_ incoming: Paper, targetFilter: LibraryFilter? = nil) throws -> UUID {
        guard paper(with: incoming.id) == nil else { throw PaperManagerError.message("这篇文献已存在。") }
        var paper = incoming
        paper.dateModified = Date()
        apply(targetFilter: targetFilter, to: &paper)
        normalizeCitekey(for: &paper)
        return try performDurableMutation { updated in
            updated.papers.append(paper)
            return paper.id
        }
    }

    func updatePaperDurably(_ paper: Paper, targetFilter: LibraryFilter? = nil) throws {
        guard let previous = self.paper(with: paper.id) else { throw PaperManagerError.message("文献已被其他窗口移除。") }
        var updated = paper
        apply(targetFilter: targetFilter, to: &updated)
        guard !previous.hasSameEditableContent(as: updated) else { return }
        updated.dateModified = Date()
        let format = snapshot.settings.citekeyFormat
        if updated.citekey.trimmed.isEmpty || updated.citekey != previous.citekey ||
            CitekeyGenerator.render(format: format, paper: previous) != CitekeyGenerator.render(format: format, paper: updated) {
            normalizeCitekey(for: &updated)
        }
        try performDurableMutation { snapshot in
            guard let index = snapshot.papers.firstIndex(where: { $0.id == updated.id }) else {
                throw PaperManagerError.message("文献已被其他窗口移除。")
            }
            snapshot.papers[index] = updated
        }
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
        let previous = snapshot.papers[index]
        let format = snapshot.settings.citekeyFormat
        if updated.citekey.trimmed.isEmpty || updated.citekey != previous.citekey ||
            CitekeyGenerator.render(format: format, paper: previous) != CitekeyGenerator.render(format: format, paper: updated) {
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
            func canonicalPath(_ attachment: Attachment) -> String {
                ((try? attachment.resolvedURL()) ?? attachment.url).resolvingSymlinksInPath().standardizedFileURL.path
            }
            let retained = Set(snapshot.papers.filter { !ids.contains($0.id) }.flatMap(\.attachments).map(canonicalPath))
            let protected = Set(snapshot.papers.flatMap(\.attachments).filter(\.isReadOnlyReference).map(canonicalPath))
            var handled = Set<String>()
            var failed = 0
            for attachment in deleting.flatMap(\.attachments) where !attachment.isReadOnlyReference {
                let path = canonicalPath(attachment)
                guard !retained.contains(path), !protected.contains(path), handled.insert(path).inserted else { continue }
                do {
                    try attachment.withResolvedURL { try trashFile($0) }
                } catch {
                    failed += 1
                }
            }
            if failed > 0 { statusMessage = "已移除记录；\(failed) 个文件未能移到废纸篓。" }
        }
        snapshot.papers.removeAll { ids.contains($0.id) }
        save()
    }

    @discardableResult
    func addCollection(name: String = "New Collection", parentID: UUID? = nil) -> UUID {
        // Compatibility for callers with already-validated fixture data. User
        // input must use createCollection and present its recoverable error.
        do { return try createCollection(name: name, parentID: parentID) }
        catch { preconditionFailure("Invalid collection request: \(error.localizedDescription)") }
    }

    @discardableResult
    func createCollection(name: String = "新建文集", parentID: UUID? = nil) throws -> UUID {
        if let parentID {
            guard let depth = collectionDepth(id: parentID) else {
                throw PaperManagerError.message("父文集不存在，或文集层级无效。")
            }
            guard depth < 3 else { throw PaperManagerError.message("文集最多支持三级，无法在此处新建子文集。") }
        }
        let nextIndex = (snapshot.collections.filter { $0.parentID == parentID }.map(\.sortIndex).max() ?? -1) + 1
        let collection = PaperCollection(name: uniqueCollectionName(base: name, parentID: parentID), parentID: parentID, sortIndex: nextIndex)
        snapshot.collections.append(collection)
        save()
        return collection.id
    }

    func collectionDepth(id: UUID) -> Int? {
        var current: UUID? = id
        var visited: Set<UUID> = []
        var depth = 0
        while let nodeID = current {
            guard visited.insert(nodeID).inserted,
                  let node = snapshot.collections.first(where: { $0.id == nodeID }) else { return nil }
            depth += 1
            current = node.parentID
        }
        return depth
    }

    func canCreateCollection(parentID: UUID?) -> Bool {
        guard let parentID else { return true }
        guard let depth = collectionDepth(id: parentID) else { return false }
        return depth < 3
    }

    func canMoveCollection(id: UUID, toParentID parentID: UUID?) -> Bool {
        guard snapshot.collections.contains(where: { $0.id == id }),
              let height = collectionSubtreeHeight(id: id) else { return false }
        let parentDepth: Int
        if let parentID {
            guard !snapshot.collections.descendantIDs(of: id).contains(parentID),
                  let depth = collectionDepth(id: parentID) else { return false }
            parentDepth = depth
        } else { parentDepth = 0 }
        return parentDepth + height <= 3
    }

    /// The insertion index describes the destination's current sibling list,
    /// matching NSOutlineView's drop index, before removing the dragged item.
    @discardableResult
    func moveCollection(id: UUID, toParentID parentID: UUID?, at insertionIndex: Int) -> Bool {
        guard canMoveCollection(id: id, toParentID: parentID),
              let sourceIndex = snapshot.collections.firstIndex(where: { $0.id == id }) else {
            statusMessage = "无法移动文集：父文集无效、形成循环，或移动后超过三级。"
            return false
        }
        let previousParent = snapshot.collections[sourceIndex].parentID
        let previousOrder = orderedCollectionIDs(parentID: parentID)
        guard (0...previousOrder.count).contains(insertionIndex) else { return false }
        var targetIndex = insertionIndex
        if previousParent == parentID, let oldIndex = previousOrder.firstIndex(of: id), oldIndex < targetIndex {
            targetIndex -= 1
        }
        var destination = previousOrder.filter { $0 != id }
        destination.insert(id, at: min(targetIndex, destination.count))
        guard previousParent != parentID || destination != previousOrder else { return true }
        snapshot.collections[sourceIndex].parentID = parentID
        setCollectionOrder(orderedCollectionIDs(parentID: previousParent))
        setCollectionOrder(destination)
        save()
        return true
    }

    private func collectionSubtreeHeight(id: UUID, visiting: Set<UUID> = []) -> Int? {
        guard !visiting.contains(id) else { return nil }
        let visited = visiting.union([id])
        var height = 1
        for child in snapshot.collections where child.parentID == id {
            guard let childHeight = collectionSubtreeHeight(id: child.id, visiting: visited) else { return nil }
            height = max(height, childHeight + 1)
        }
        return height
    }

    private func orderedCollectionIDs(parentID: UUID?) -> [UUID] {
        snapshot.collections.children(of: parentID).map(\.id)
    }

    private func setCollectionOrder(_ ids: [UUID]) {
        for (order, id) in ids.enumerated() {
            if let index = snapshot.collections.firstIndex(where: { $0.id == id }) {
                snapshot.collections[index].sortIndex = order
            }
        }
    }

    func renameCollection(id: UUID, name: String) {
        guard let index = snapshot.collections.firstIndex(where: { $0.id == id }) else { return }
        snapshot.collections[index].name = name.trimmed.isEmpty ? "Untitled Collection" : name.trimmed
        save()
    }

    func deleteCollection(id: UUID) {
        let parentID = snapshot.collections.first { $0.id == id }?.parentID
        let ids = snapshot.collections.descendantIDs(of: id)
        snapshot.collections.removeAll { ids.contains($0.id) }
        setCollectionOrder(orderedCollectionIDs(parentID: parentID))
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
        let nextIndex = (snapshot.tags.map(\.sortIndex).max() ?? -1) + 1
        let tag = PaperTag(name: uniqueTagName(base: name), colorHex: Self.normalizedTagColor(colorHex) ?? "#5B8DEF", sortIndex: nextIndex)
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
        guard let normalized = Self.normalizedTagColor(colorHex) else {
            statusMessage = "请输入有效的十六进制颜色，例如 #5B8DEF。"
            return
        }
        snapshot.tags[index].colorHex = normalized
        save()
    }

    static func normalizedTagColor(_ colorHex: String) -> String? {
        var value = colorHex.trimmed
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.range(of: "^[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$", options: .regularExpression) != nil else { return nil }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        return "#" + value.uppercased()
    }

    @discardableResult
    func moveTag(id: UUID, at insertionIndex: Int) -> Bool {
        let previous = tags.map(\.id)
        guard let oldIndex = previous.firstIndex(of: id), (0...previous.count).contains(insertionIndex) else { return false }
        let targetIndex = insertionIndex > oldIndex ? insertionIndex - 1 : insertionIndex
        var ordered = previous.filter { $0 != id }
        ordered.insert(id, at: min(targetIndex, ordered.count))
        guard ordered != previous else { return true }
        setTagOrder(ordered)
        save()
        return true
    }

    private func setTagOrder(_ ids: [UUID]) {
        for (order, id) in ids.enumerated() {
            if let index = snapshot.tags.firstIndex(where: { $0.id == id }) { snapshot.tags[index].sortIndex = order }
        }
    }

    func deleteTag(id: UUID) {
        snapshot.tags.removeAll { $0.id == id }
        setTagOrder(tags.map(\.id))
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

    func attachManagedFile(_ sourceURL: URL, to paperID: UUID, kind: AttachmentKind? = nil, replacePrimary: Bool = false) throws {
        try attachFile(sourceURL, to: paperID, kind: kind, managedImport: true, replacePrimary: replacePrimary)
    }

    func attachFile(_ sourceURL: URL, to paperID: UUID, kind: AttachmentKind? = nil, managedImport: Bool = false, replacePrimary: Bool = false) throws {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        let normalizedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let protectedSource = snapshot.papers.flatMap(\.attachments).contains {
            $0.isReadOnlyReference && FileLibraryService.resolvedCanonicalURL(for: $0).path == normalizedSource
        }
        if protectedSource && !managedImport && snapshot.settings.pdfOrganizationMode == .move {
            throw PaperManagerError.message("这是 Lattice 原文件的只读引用。请将本地文件操作改为复制后再导入。")
        }
        var paper = snapshot.papers[index]
        let plan = try FileLibraryService.plan(source: sourceURL, paper: paper, snapshot: snapshot, kind: kind, managedImport: managedImport)
        if !managedImport, plan.changesLocation, snapshot.settings.confirmBeforeMovingFiles,
           !confirmOrganizationOperation(mode: plan.action, source: plan.source, destination: plan.destination) {
            throw PaperManagerError.message("已取消文件整理，原文件和文献均保持不变。")
        }
        let receipt = try FileLibraryService.execute(plan)
        let finalURL = plan.destination
        let rootAccess = plan.authorizedRoot?.startAccessingSecurityScopedResource() ?? false
        defer { if rootAccess { plan.authorizedRoot?.stopAccessingSecurityScopedResource() } }
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
            missing: !FileManager.default.fileExists(atPath: finalURL.path),
            isReadOnlyReference: protectedSource && finalURL.resolvingSymlinksInPath().standardizedFileURL.path == normalizedSource
        )
        paper.attachments.removeAll {
            FileLibraryService.resolvedCanonicalURL(for: $0).path == finalURL.path ||
                (plan.action == .move && FileLibraryService.resolvedCanonicalURL(for: $0).path == normalizedSource)
        }
        if replacePrimary && attachment.kind == .pdf { paper.attachments.insert(attachment, at: 0) }
        else { paper.attachments.append(attachment) }
        do { try persistFilePapers([paper]) }
        catch {
            do { try receipt.rollback() }
            catch { throw PaperManagerError.message("保存失败，回滚未能完成：\(error.localizedDescription)") }
            throw error
        }
    }

    func regenerateCitekeys() {
        regenerateCitekeysWithoutSaving()
        save()
    }

    private func regenerateCitekeysWithoutSaving() {
        var existing = Set<String>()
        let orderedIndices = snapshot.papers.indices.sorted { left, right in
            let lhs = snapshot.papers[left]
            let rhs = snapshot.papers[right]
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for index in orderedIndices {
            let key = CitekeyGenerator.generate(
                for: snapshot.papers[index],
                format: snapshot.settings.citekeyFormat,
                existing: existing
            )
            if key != snapshot.papers[index].citekey {
                snapshot.papers[index].citekey = key
                snapshot.papers[index].dateModified = Date()
            }
            existing.insert(key)
        }
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
            if snapshot.collections.contains(where: { $0.id == id }), !paper.collectionIDs.contains(id) { paper.collectionIDs.append(id) }
        case .tag(let id):
            if snapshot.tags.contains(where: { $0.id == id }), !paper.tagIDs.contains(id) { paper.tagIDs.append(id) }
        default:
            break
        }
    }

    private func normalizeCitekey(for paper: inout Paper) {
        let existing = Set(snapshot.papers.filter { $0.id != paper.id }.map { $0.citekey.lowercased() }.filter { !$0.isEmpty })
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

    func organizeFiles(paperIDs: Set<UUID>) throws -> FileOperationSummary {
        try performFileOperation(paperIDs: paperIDs, renameOnly: false)
    }

    func renameFiles(paperIDs: Set<UUID>) throws -> FileOperationSummary {
        try performFileOperation(paperIDs: paperIDs, renameOnly: true)
    }

    private func performFileOperation(paperIDs: Set<UUID>, renameOnly: Bool) throws -> FileOperationSummary {
        if !renameOnly, !FileLibraryService.status(for: settings).isAvailable {
            throw PaperManagerError.message("请先在设置中配置或修复文件库，再整理现有文件。")
        }
        var summary = FileOperationSummary(), receipts: [FilePlacementReceipt] = [], changed: [Paper] = []
        var confirmed = !settings.confirmBeforeMovingFiles
        var cancelled = false
        for original in snapshot.papers where paperIDs.contains(original.id) {
            var paper = original
            for index in paper.attachments.indices {
                let attachment = paper.attachments[index]
                do {
                    try attachment.withResolvedURL { source in
                        let plan = try renameOnly
                            ? FileLibraryService.renamePlan(attachment: attachment, paper: paper, snapshot: snapshot)
                            : FileLibraryService.plan(source: source, paper: paper, snapshot: snapshot, attachmentID: attachment.id,
                                                      explicitOrganization: true, kind: attachment.kind)
                        guard plan.changesLocation else { summary.unchanged += 1; return }
                        if !confirmed {
                            guard confirmOrganizationOperation(mode: plan.action, source: plan.source, destination: plan.destination) else {
                                cancelled = true
                                return
                            }
                            confirmed = true
                        }
                        let receipt = try FileLibraryService.execute(plan)
                        receipts.append(receipt)
                        let rootAccess = plan.authorizedRoot?.startAccessingSecurityScopedResource() ?? false
                        defer { if rootAccess { plan.authorizedRoot?.stopAccessingSecurityScopedResource() } }
                        var updated = attachment
                        updated.filePath = plan.destination.path
                        updated.displayName = plan.destination.lastPathComponent
                        updated.bookmarkData = try? plan.destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        updated.isReadOnlyReference = false
                        updated.missing = false
                        paper.attachments[index] = updated
                        summary.completed += 1
                    }
                    if cancelled { statusMessage = "已取消文件操作，文件保持原位。"; return summary }
                } catch {
                    summary.unchanged += 1
                    summary.messages.append("\(attachment.displayName)：\(error.localizedDescription)")
                }
            }
            if paper.attachments != original.attachments { changed.append(paper) }
        }
        do {
            if !changed.isEmpty { try persistFilePapers(changed) }
        } catch {
            var rollbackErrors: [String] = []
            for receipt in receipts.reversed() {
                do { try receipt.rollback() }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty { throw PaperManagerError.message("保存失败，部分文件已保留以防覆盖：\(rollbackErrors.joined(separator: "；"))") }
            throw error
        }
        statusMessage = summary.text
        return summary
    }

    /// Commit metadata only after placement succeeds, with a throwing atomic
    /// write so callers can restore files on a persistence failure.
    private func persistFilePapers(_ papers: [Paper]) throws {
        try performDurableMutation { updated in
            for var paper in papers {
                guard let index = updated.papers.firstIndex(where: { $0.id == paper.id }) else {
                    throw PaperManagerError.message("文献在文件操作期间已被移除。")
                }
                paper.dateModified = Date()
                updated.papers[index] = paper
            }
        }
    }

    private func confirmOrganizationOperation(mode: PDFOrganizationMode, source: URL, destination: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch mode {
        case .copy:
            alert.messageText = "复制所选文献的文件到文件库？"
            alert.informativeText = "\(source.lastPathComponent)\n\n将复制到：\n\(destination.path)"
        case .move:
            alert.messageText = "移动所选文献的文件？"
            alert.informativeText = "\(source.lastPathComponent)\n\n将从原位置移动到：\n\(destination.path)"
        case .none:
            return true
        }
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
