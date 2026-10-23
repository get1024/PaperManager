import AppKit
import Combine
import Foundation

struct MetadataRefreshProgress: Equatable {
    var total = 0
    var completed = 0
    var updated = 0
    var unchanged = 0
    var failed = 0
    var skipped = 0
    var cancelled = false
    var isRunning = true
    var errors: [UUID: String] = [:]
}

private struct MetadataRefreshOutcome {
    var paperID: UUID
    var sourceIdentity: [String]
    var importBaseline: Paper? = nil
    var metadata: PaperMetadata? = nil
    var error: String? = nil
    var cancelled = false
}

private struct FileOperationOutcome {
    var attachment: Attachment
    var receipt: FilePlacementReceipt?
}

@MainActor
private final class WeakLibraryStore {
    weak var value: LibraryStore?
    init(_ value: LibraryStore) { self.value = value }
}

@MainActor
final class LibraryStore: ObservableObject {
    private static var liveStores: [WeakLibraryStore] = []
    private static var fileOperationShutdownRequested = false
    @Published private(set) var snapshot: LibrarySnapshot
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published private(set) var loadError: String?
    @Published private(set) var metadataRefreshProgress: MetadataRefreshProgress?
    @Published private(set) var fileOperationProgress: FileOperationProgress?

    let persistenceURL: URL
    private let trashFile: (URL) throws -> Void
    private let metadataLookup: (Paper) async throws -> PaperMetadata
    private let filePlacement: (FilePlacementPlan) throws -> FilePlacementReceipt
    private var fileOperationTask: Task<Void, Never>?
    private var metadataRefreshTask: Task<Void, Never>?
    private var metadataRefreshPending: [UUID] = []
    private var metadataRefreshActiveIDs: Set<UUID> = []
    private var metadataRefreshKnownIDs: Set<UUID> = []
    private var metadataRefreshFailedIDs: [UUID] = []
    private var metadataRefreshImportBaselines: [UUID: Paper] = [:]
    private var metadataRefreshCancellationRequested = false
    private var libraryGeneration = UUID()

    init(persistenceURL: URL? = nil, trashFile: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }, metadataLookup: @escaping (Paper) async throws -> PaperMetadata = { paper in
        try await MetadataLookupClient.lookup(doi: paper.doi.nilIfBlank, arxivID: paper.arxivLookupID,
                                              isbn: paper.isbn.nilIfBlank, title: paper.title.nilIfBlank)
    }, filePlacement: @escaping (FilePlacementPlan) throws -> FilePlacementReceipt = {
        try FileLibraryService.execute($0, checkCancellation: { try Task.checkCancellation() })
    }) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.trashFile = trashFile
        self.metadataLookup = metadataLookup
        self.filePlacement = filePlacement
        self.snapshot = .empty
        load()
        Self.liveStores.removeAll { $0.value == nil }
        Self.liveStores.append(WeakLibraryStore(self))
    }

    var isMetadataRefreshing: Bool { metadataRefreshTask != nil }
    var libraryIdentityToken: UUID { libraryGeneration }
    var isFileOperationRunning: Bool { fileOperationTask != nil }

    static var hasRunningFileOperations: Bool { liveStores.contains { $0.value?.isFileOperationRunning == true } }

    /// Mark shutdown synchronously so a second window cannot start a move while
    /// the app delegate is waiting for an earlier placement to roll back. Only
    /// file jobs are awaited; metadata providers may be slow or offline.
    static func beginFileOperationShutdown() -> Task<Void, Never> {
        fileOperationShutdownRequested = true
        let stores = liveStores.compactMap(\.value).filter(\.isFileOperationRunning)
        stores.forEach { $0.cancelFileOperation() }
        return Task { for store in stores { await store.waitForFileOperation() } }
    }

    static func resumeAfterCancelledFileOperationShutdown() { fileOperationShutdownRequested = false }

    func isRefreshingMetadata(paperID: UUID) -> Bool {
        metadataRefreshPending.contains(paperID) || metadataRefreshActiveIDs.contains(paperID)
    }

    /// One queue belongs to the shared library, so overlapping windows cannot
    /// issue duplicate refreshes for the same paper. Import/file-operation busy
    /// state is independent and is never cleared by this background job.
    @discardableResult
    func enqueueMetadataRefresh(paperIDs: [UUID], replacingUneditedFieldsFrom importedPDFs: [UUID: Paper] = [:]) -> Bool {
        guard !metadataRefreshCancellationRequested else { return false }
        let starting = metadataRefreshTask == nil
        var knownIDs = starting ? Set<UUID>() : metadataRefreshKnownIDs
        let added = paperIDs.filter { id in
            paper(with: id) != nil && knownIDs.insert(id).inserted
        }
        guard !added.isEmpty else { return false }
        if starting {
            metadataRefreshFailedIDs.removeAll()
            metadataRefreshImportBaselines.removeAll()
            metadataRefreshProgress = MetadataRefreshProgress()
        }
        metadataRefreshKnownIDs = knownIDs
        metadataRefreshPending.append(contentsOf: added)
        for id in added where importedPDFs[id]?.id == id { metadataRefreshImportBaselines[id] = importedPDFs[id] }
        metadataRefreshProgress?.total += added.count
        guard starting else { return true }
        let generation = libraryGeneration
        metadataRefreshTask = Task { [weak self] in await self?.runMetadataRefreshQueue(generation: generation) }
        return true
    }

    func cancelMetadataRefresh() {
        guard metadataRefreshTask != nil else { return }
        metadataRefreshCancellationRequested = true
        metadataRefreshTask?.cancel()
    }

    @discardableResult
    func retryFailedMetadataRefresh() -> Bool {
        guard !isMetadataRefreshing else { return false }
        return enqueueMetadataRefresh(paperIDs: metadataRefreshFailedIDs, replacingUneditedFieldsFrom: metadataRefreshImportBaselines)
    }

    /// Also useful to callers which must finish a refresh before exporting.
    func waitForMetadataRefresh() async { await metadataRefreshTask?.value }

    private func runMetadataRefreshQueue(generation: UUID) async {
        defer {
            let cancelled = metadataRefreshCancellationRequested || Task.isCancelled
            metadataRefreshProgress?.cancelled = cancelled
            metadataRefreshProgress?.isRunning = false
            if generation == libraryGeneration, let progress = metadataRefreshProgress {
                let prefix = cancelled ? PMLocalization.text("元数据刷新已停止") : PMLocalization.text("元数据刷新完成")
                statusMessage = PMLocalization.format("%@：更新 %d，未变 %d，失败 %d，跳过 %d。", prefix,
                                                       progress.updated, progress.unchanged, progress.failed, progress.skipped)
            }
            metadataRefreshPending.removeAll()
            metadataRefreshActiveIDs.removeAll()
            metadataRefreshTask = nil
            metadataRefreshCancellationRequested = false
        }
        // Three independent provider calls in flight bound network pressure;
        // completion-order processing keeps a slow provider from blocking saves.
        await withTaskGroup(of: MetadataRefreshOutcome.self) { group in
            var activeCount = 0
            while true {
                if Task.isCancelled || metadataRefreshCancellationRequested || generation != libraryGeneration {
                    group.cancelAll(); break
                }
                while activeCount < 3, !metadataRefreshPending.isEmpty {
                    let id = metadataRefreshPending.removeFirst()
                    guard let paper = paper(with: id) else {
                        metadataRefreshProgress?.completed += 1
                        metadataRefreshProgress?.skipped += 1
                        continue
                    }
                    let lookup = metadataLookup
                    let sourceIdentity = Self.metadataRefreshIdentity(paper)
                    let imported = metadataRefreshImportBaselines[id]
                    let importBaseline = imported.flatMap { Self.metadataRefreshIdentity($0) == sourceIdentity ? $0 : nil }
                    activeCount += 1
                    metadataRefreshActiveIDs.insert(id)
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let metadata = try await lookup(paper)
                            try Task.checkCancellation()
                            return MetadataRefreshOutcome(paperID: id, sourceIdentity: sourceIdentity, importBaseline: importBaseline, metadata: metadata)
                        } catch {
                            return MetadataRefreshOutcome(paperID: id, sourceIdentity: sourceIdentity, error: error.localizedDescription,
                                                          cancelled: error is CancellationError || Task.isCancelled)
                        }
                    }
                }
                guard activeCount > 0, let outcome = await group.next() else { break }
                activeCount -= 1
                metadataRefreshActiveIDs.remove(outcome.paperID)
                if Task.isCancelled || metadataRefreshCancellationRequested || generation != libraryGeneration {
                    group.cancelAll(); break
                }
                metadataRefreshProgress?.completed += 1
                guard !outcome.cancelled else {
                    metadataRefreshProgress?.skipped += 1
                    continue
                }
                guard let latest = paper(with: outcome.paperID) else {
                    metadataRefreshProgress?.skipped += 1
                    continue
                }
                guard Self.metadataRefreshIdentity(latest) == outcome.sourceIdentity else {
                    // A DOI/ISBN/lookup-title edit may now identify a different
                    // work. Its old request must not fill the new record.
                    metadataRefreshProgress?.skipped += 1
                    continue
                }
                if let metadata = outcome.metadata {
                    do {
                        // Merge with the latest record only, preserving edits,
                        // local attachments and organization made during await.
                        let merged: Paper
                        if let baseline = outcome.importBaseline {
                            // Provider values may replace PDF-inferred fields.
                            // Every field edited since the request began wins
                            // over that response, including deliberate clearing.
                            let enriched = metadata.merged(into: baseline, replaceExisting: true)
                            merged = latest.applyingEdits(to: enriched, from: baseline)
                        } else { merged = metadata.merged(into: latest) }
                        let changed = !latest.hasSameEditableContent(as: merged)
                        try updatePaperDurably(merged)
                        if changed { metadataRefreshProgress?.updated += 1 }
                        else { metadataRefreshProgress?.unchanged += 1 }
                    } catch { recordMetadataRefreshFailure(outcome.paperID, message: error.localizedDescription) }
                } else { recordMetadataRefreshFailure(outcome.paperID, message: outcome.error ?? "") }
                if let progress = metadataRefreshProgress {
                    statusMessage = PMLocalization.format("正在刷新元数据 %d/%d：%@", progress.completed, progress.total, latest.displayTitle)
                }
            }
        }
    }

    private func recordMetadataRefreshFailure(_ id: UUID, message: String) {
        metadataRefreshFailedIDs.append(id)
        metadataRefreshProgress?.failed += 1
        metadataRefreshProgress?.errors[id] = message
    }

    static func metadataRefreshIdentity(_ paper: Paper) -> [String] {
        let identifiers = [paper.doi.trimmed.lowercased(), paper.arxivLookupID?.lowercased() ?? "",
                           paper.isbn.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression).uppercased()]
        return identifiers.allSatisfy(\.isEmpty) ? identifiers + [paper.title.trimmed] : identifiers
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

    static let preferredLibraryPathKey = "PaperManager.PreferredLibraryPath"

    static func defaultPersistenceURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      preferences: UserDefaults = .standard) -> URL {
        if let path = environment["PAPERMANAGER_LIBRARY_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let path = preferences.string(forKey: preferredLibraryPathKey), path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) {
                return url
            }
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

    /// Legacy UI actions report a recoverable error while retaining the last
    /// committed value. Never publish an optimistic mutation before its write.
    @discardableResult
    private func performReportedMutation(_ mutation: (inout LibrarySnapshot) throws -> Void) -> Bool {
        do { try performDurableMutation(mutation); return true }
        catch { statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription); return false }
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
        // Restored/merged snapshots may deliberately reuse paper IDs and their
        // identifiers. Requests issued against the previous library must never
        // fill their fields, even when the provider ignores cancellation. Only
        // invalidate after the replacement has reached disk successfully.
        libraryGeneration = UUID()
        cancelMetadataRefresh()
        cancelFileOperation()
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

    @discardableResult
    func updateSettings(_ settings: AppSettings) -> Bool {
        performReportedMutation { updated in
            let previousFormat = updated.settings.citekeyFormat
            updated.settings = settings
            if settings.citekeyFormat != previousFormat { Self.regenerateCitekeys(in: &updated) }
        }
    }

    @discardableResult
    func updateSetting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, value: Value) -> Bool {
        performReportedMutation { updated in
            let previousFormat = updated.settings.citekeyFormat
            updated.settings[keyPath: keyPath] = value
            if updated.settings.citekeyFormat != previousFormat { Self.regenerateCitekeys(in: &updated) }
        }
    }

    @discardableResult
    func updateLocalAPIPort(from input: String) -> Bool {
        guard let port = Int(input.trimmed), (1...65535).contains(port) else {
            statusMessage = PMLocalization.text("端口必须是 1–65535 之间的整数。")
            return false
        }
        guard port != settings.localAPIPort else { return true }
        return updateSetting(\.localAPIPort, value: port)
    }

    func paper(with id: UUID) -> Paper? {
        snapshot.papers.first { $0.id == id }
    }

    func sidebarCounts(includeSubcollections: Bool) -> LibrarySidebarCounts {
        LibraryQuery.sidebarCounts(in: snapshot, includeSubcollections: includeSubcollections)
    }

    func filteredPapers(
        for filter: LibraryFilter,
        searchText: String,
        includeSubcollections: Bool,
        sortDescriptor: PaperSortDescriptor = .defaultValue
    ) -> [Paper] {
        LibraryQuery.papers(in: snapshot, filter: filter, searchText: searchText,
                            includeSubcollections: includeSubcollections, sortDescriptor: sortDescriptor)
    }

    @discardableResult
    func addPaper(_ incoming: Paper, targetFilter: LibraryFilter? = nil) -> UUID {
        do { return try addPaperDurably(incoming, targetFilter: targetFilter) }
        catch { statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription); return incoming.id }
    }

    @discardableResult
    func addPaperDurably(_ incoming: Paper, targetFilter: LibraryFilter? = nil, additionalTags: [PaperTag] = []) throws -> UUID {
        guard paper(with: incoming.id) == nil else { throw PaperManagerError.message("这篇文献已存在。") }
        var paper = incoming
        paper.dateModified = Date()
        apply(targetFilter: targetFilter, to: &paper)
        normalizeCitekey(for: &paper)
        return try performDurableMutation { updated in
            updated.tags.append(contentsOf: additionalTags)
            updated.papers.append(paper)
            return paper.id
        }
    }

    func updatePaperDurably(_ paper: Paper, targetFilter: LibraryFilter? = nil, additionalTags: [PaperTag] = []) throws {
        guard let previous = self.paper(with: paper.id) else { throw PaperManagerError.message("文献已被其他窗口移除。") }
        var updated = paper
        apply(targetFilter: targetFilter, to: &updated)
        guard !previous.hasSameEditableContent(as: updated) || !additionalTags.isEmpty else { return }
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
            snapshot.tags.append(contentsOf: additionalTags)
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

    @discardableResult
    func updatePaper(_ paper: Paper) -> Bool {
        do { try updatePaperDurably(paper); return true }
        catch { statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription); return false }
    }

    func markOpened(_ paperID: UUID) {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        performReportedMutation { updated in
            updated.papers[index].lastOpenedAt = Date()
            updated.papers[index].dateModified = Date()
        }
    }

    func updateAnnotations(_ annotations: [ResearchAnnotation], for paperID: UUID) {
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else { return }
        performReportedMutation { updated in
            updated.papers[index].annotations = annotations
            updated.papers[index].dateModified = Date()
        }
    }

    @discardableResult
    func deletePapers(ids: Set<UUID>) -> Bool {
        let deleting = snapshot.papers.filter { ids.contains($0.id) }
        let before = snapshot
        // Persist record removal first. If the library cannot be written, no
        // source file is touched; failed Trash operations leave recoverable bytes.
        guard performReportedMutation({ $0.papers.removeAll { ids.contains($0.id) } }) else { return false }
        if before.settings.deleteAttachmentsToTrash {
            func canonicalPath(_ attachment: Attachment) -> String {
                ((try? attachment.resolvedURL()) ?? attachment.url).resolvingSymlinksInPath().standardizedFileURL.path
            }
            let retained = Set(before.papers.filter { !ids.contains($0.id) }.flatMap(\.attachments).map(canonicalPath))
            let protected = Set(before.papers.flatMap(\.attachments).filter(\.isReadOnlyReference).map(canonicalPath))
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
        return true
    }

    @discardableResult
    func addCollection(name: String = "New Collection", parentID: UUID? = nil) -> UUID {
        // Compatibility for legacy callers. User input must use the throwing
        // createCollection API; a failed disk write must never crash the app.
        do { return try createCollection(name: name, parentID: parentID) }
        catch { statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription); return UUID() }
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
        try performDurableMutation { $0.collections.append(collection) }
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
        return performReportedMutation { updated in
            updated.collections[sourceIndex].parentID = parentID
            Self.setCollectionOrder(updated.collections.children(of: previousParent).map(\.id), in: &updated)
            Self.setCollectionOrder(destination, in: &updated)
        }
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

    private static func setCollectionOrder(_ ids: [UUID], in snapshot: inout LibrarySnapshot) {
        for (order, id) in ids.enumerated() {
            if let index = snapshot.collections.firstIndex(where: { $0.id == id }) {
                snapshot.collections[index].sortIndex = order
            }
        }
    }

    func renameCollection(id: UUID, name: String) {
        guard let index = snapshot.collections.firstIndex(where: { $0.id == id }) else { return }
        performReportedMutation { $0.collections[index].name = name.trimmed.isEmpty ? "Untitled Collection" : name.trimmed }
    }

    func deleteCollection(id: UUID) {
        let parentID = snapshot.collections.first { $0.id == id }?.parentID
        let ids = snapshot.collections.descendantIDs(of: id)
        performReportedMutation { updated in
            updated.collections.removeAll { ids.contains($0.id) }
            Self.setCollectionOrder(updated.collections.children(of: parentID).map(\.id), in: &updated)
            for index in updated.papers.indices {
                updated.papers[index].collectionIDs.removeAll { ids.contains($0) }
            }
        }
    }

    func addPapers(ids: Set<UUID>, toCollection collectionID: UUID) {
        guard snapshot.collections.contains(where: { $0.id == collectionID }) else { return }
        guard snapshot.papers.contains(where: { ids.contains($0.id) && !$0.collectionIDs.contains(collectionID) }) else { return }
        performReportedMutation { updated in
            for index in updated.papers.indices where ids.contains(updated.papers[index].id) {
                if !updated.papers[index].collectionIDs.contains(collectionID) {
                    updated.papers[index].collectionIDs.append(collectionID)
                    updated.papers[index].dateModified = Date()
                }
            }
        }
    }

    @discardableResult
    func addTag(name: String = "New Tag", colorHex: String = "#5B8DEF") -> UUID {
        do { return try createTag(name: name, colorHex: colorHex) }
        catch { statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription); return UUID() }
    }

    @discardableResult
    func createTag(name: String = "New Tag", colorHex: String = "#5B8DEF") throws -> UUID {
        let nextIndex = (snapshot.tags.map(\.sortIndex).max() ?? -1) + 1
        let tag = PaperTag(name: uniqueTagName(base: name), colorHex: Self.normalizedTagColor(colorHex) ?? "#5B8DEF", sortIndex: nextIndex)
        try performDurableMutation { $0.tags.append(tag) }
        return tag.id
    }

    func renameTag(id: UUID, name: String) {
        guard let index = snapshot.tags.firstIndex(where: { $0.id == id }) else { return }
        performReportedMutation { $0.tags[index].name = name.trimmed.isEmpty ? "Untitled Tag" : name.trimmed }
    }

    func updateTagColor(id: UUID, colorHex: String) {
        guard let index = snapshot.tags.firstIndex(where: { $0.id == id }) else { return }
        guard let normalized = Self.normalizedTagColor(colorHex) else {
            statusMessage = "请输入有效的十六进制颜色，例如 #5B8DEF。"
            return
        }
        performReportedMutation { $0.tags[index].colorHex = normalized }
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
        return performReportedMutation { Self.setTagOrder(ordered, in: &$0) }
    }

    private static func setTagOrder(_ ids: [UUID], in snapshot: inout LibrarySnapshot) {
        for (order, id) in ids.enumerated() {
            if let index = snapshot.tags.firstIndex(where: { $0.id == id }) { snapshot.tags[index].sortIndex = order }
        }
    }

    func deleteTag(id: UUID) {
        let remaining = tags.map(\.id).filter { $0 != id }
        performReportedMutation { updated in
            updated.tags.removeAll { $0.id == id }
            Self.setTagOrder(remaining, in: &updated)
            for index in updated.papers.indices { updated.papers[index].tagIDs.removeAll { $0 == id } }
        }
    }

    func addPapers(ids: Set<UUID>, toTag tagID: UUID) {
        guard snapshot.tags.contains(where: { $0.id == tagID }) else { return }
        guard snapshot.papers.contains(where: { ids.contains($0.id) && !$0.tagIDs.contains(tagID) }) else { return }
        performReportedMutation { updated in
            for index in updated.papers.indices where ids.contains(updated.papers[index].id) {
                if !updated.papers[index].tagIDs.contains(tagID) {
                    updated.papers[index].tagIDs.append(tagID)
                    updated.papers[index].dateModified = Date()
                }
            }
        }
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
        performReportedMutation { Self.regenerateCitekeys(in: &$0) }
    }

    private static func regenerateCitekeys(in snapshot: inout LibrarySnapshot) {
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

    /// A single library-owned queue keeps file IO off the main actor. Each
    /// attachment is committed independently, so stopping preserves completed
    /// work and rolls back only a placement whose metadata was not committed.
    @discardableResult
    func enqueueFileOperation(paperIDs: Set<UUID>, renameOnly: Bool = false) -> Bool {
        guard !Self.fileOperationShutdownRequested else { return false }
        guard !isFileOperationRunning else { return false }
        guard loadError == nil else { statusMessage = "当前文库无法读取，已停止文件操作。"; return false }
        if !renameOnly, !FileLibraryService.status(for: settings).isAvailable {
            statusMessage = "请先在设置中配置或修复文件库，再整理现有文件。"; return false
        }
        let jobs = snapshot.papers.filter { paperIDs.contains($0.id) }.flatMap { paper in
            paper.attachments.map { (paper.id, $0.id) }
        }
        guard !jobs.isEmpty else { return false }
        fileOperationProgress = FileOperationProgress(total: jobs.count)
        let generation = libraryGeneration
        fileOperationTask = Task { [weak self] in
            await self?.runFileOperation(jobs: jobs, renameOnly: renameOnly, generation: generation)
        }
        return true
    }

    func cancelFileOperation() { fileOperationTask?.cancel() }
    func waitForFileOperation() async { await fileOperationTask?.value }

    private func fileWorker<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private func runFileOperation(jobs: [(UUID, UUID)], renameOnly: Bool, generation: UUID) async {
        var confirmed = !settings.confirmBeforeMovingFiles
        defer {
            fileOperationProgress?.cancelled = Task.isCancelled || generation != libraryGeneration
            fileOperationProgress?.isRunning = false
            fileOperationTask = nil
            if generation == libraryGeneration, let progress = fileOperationProgress {
                let summary = FileOperationSummary(completed: progress.completed, unchanged: progress.unchanged + progress.failed,
                                                   messages: progress.messages)
                statusMessage = progress.cancelled ? "文件操作已停止。\(summary.text)" : summary.text
            }
        }
        for (paperID, attachmentID) in jobs {
            if Task.isCancelled || generation != libraryGeneration { break }
            guard let original = paper(with: paperID), let attachment = original.attachments.first(where: { $0.id == attachmentID }) else {
                fileOperationProgress?.unchanged += 1; continue
            }
            let baseline = snapshot
            do {
                let plan = try await fileWorker {
                    try attachment.withResolvedURL { source in
                        try renameOnly ? FileLibraryService.renamePlan(attachment: attachment, paper: original, snapshot: baseline)
                            : FileLibraryService.plan(source: source, paper: original, snapshot: baseline, attachmentID: attachment.id,
                                                      explicitOrganization: true, kind: attachment.kind)
                    }
                }
                try Task.checkCancellation()
                guard generation == libraryGeneration else { break }
                guard paper(with: paperID)?.attachments.first(where: { $0.id == attachmentID }) == attachment else {
                    fileOperationProgress?.unchanged += 1; continue
                }
                guard plan.changesLocation else { fileOperationProgress?.unchanged += 1; continue }
                if !confirmed {
                    guard confirmOrganizationOperation(mode: plan.action, source: plan.source, destination: plan.destination) else {
                        fileOperationTask?.cancel(); break
                    }
                    confirmed = true
                }
                try Task.checkCancellation()
                guard generation == libraryGeneration else { break }
                let placement = filePlacement
                let outcome = try await fileWorker {
                    try attachment.withResolvedURL { _ in
                        let receipt = try placement(plan)
                        var updated = attachment
                        updated.filePath = plan.destination.path
                        updated.displayName = plan.destination.lastPathComponent
                        let access = plan.authorizedRoot?.startAccessingSecurityScopedResource() ?? false
                        defer { if access { plan.authorizedRoot?.stopAccessingSecurityScopedResource() } }
                        updated.bookmarkData = try? plan.destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        updated.isReadOnlyReference = false; updated.missing = false
                        return FileOperationOutcome(attachment: updated, receipt: receipt)
                    }
                }
                do {
                    try Task.checkCancellation()
                    guard generation == libraryGeneration,
                          let current = paper(with: paperID),
                          current.attachments.first(where: { $0.id == attachmentID }) == attachment else {
                        throw PaperManagerError.message("文件操作期间文库或附件已更改，已撤销当前文件操作。")
                    }
                    if plan.action == .move {
                        let paths = Set([plan.source.path, plan.destination.path])
                        let newlyShared = snapshot.papers.contains { item in
                            item.attachments.contains { candidate in
                                !(item.id == paperID && candidate.id == attachmentID)
                                    && paths.contains(FileLibraryService.resolvedCanonicalURL(for: candidate).path)
                            }
                        }
                        guard !newlyShared else { throw PaperManagerError.message("文件现在被其他附件引用，已撤销移动。") }
                    }
                    try performDurableMutation { updated in
                        guard let index = updated.papers.firstIndex(where: { $0.id == paperID }),
                              let fileIndex = updated.papers[index].attachments.firstIndex(where: { $0.id == attachmentID }) else {
                            throw PaperManagerError.message("文献或附件已移除。")
                        }
                        updated.papers[index].attachments[fileIndex] = outcome.attachment
                        updated.papers[index].dateModified = Date()
                    }
                    fileOperationProgress?.completed += 1
                } catch {
                    if let receipt = outcome.receipt {
                        // A new record may have adopted the destination while
                        // IO was in flight. Restore our old source, but retain
                        // that now-referenced destination rather than breaking
                        // a concurrently committed relationship.
                        let preserveDestination = snapshot.papers.contains { item in
                            item.attachments.contains { candidate in
                                !(item.id == paperID && candidate == attachment)
                                    && FileLibraryService.resolvedCanonicalURL(for: candidate).path == plan.destination.path
                            }
                        }
                        do { try await Task.detached(priority: .utility) {
                            try attachment.withResolvedURL { _ in try receipt.rollback(preservingDestination: preserveDestination) }
                        }.value }
                        catch { fileOperationProgress?.messages.append("撤销当前文件操作失败，已保留文件以避免覆盖：\(error.localizedDescription)") }
                    }
                    throw error
                }
            } catch {
                if error is CancellationError || Task.isCancelled || generation != libraryGeneration { break }
                fileOperationProgress?.failed += 1
                fileOperationProgress?.messages.append("\(attachment.displayName)：\(error.localizedDescription)")
            }
            if let progress = fileOperationProgress, generation == libraryGeneration {
                statusMessage = "正在处理文件 \(progress.processed)/\(progress.total)：\(original.displayTitle)"
            }
        }
    }

    private func performFileOperation(paperIDs: Set<UUID>, renameOnly: Bool) throws -> FileOperationSummary {
        guard !isFileOperationRunning else { throw PaperManagerError.message("文件操作正在进行，请先停止或等待完成。") }
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
