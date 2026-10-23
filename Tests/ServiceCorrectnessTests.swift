import Combine
import Darwin
import Foundation

private actor DelayedMetadata {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func fetch(_ paper: Paper) async -> PaperMetadata {
        started = true
        await withCheckedContinuation { continuation = $0 }
        var value = PaperMetadata(); value.abstract = "Delayed provider result"; return value
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor BurstMetadata {
    var active = 0, peak = 0, calls = 0
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func fetch(_ paper: Paper) async -> PaperMetadata {
        active += 1; calls += 1; peak = max(peak, active)
        defer { active -= 1 }
        if !opened { await withCheckedContinuation { continuations.append($0) } }
        var value = PaperMetadata(); value.abstract = "Bounded result"; value.title = "Provider title"; return value
    }
    func open() { opened = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
}

/// Blocks only a detached worker, after a real placement. The main actor can
/// cancel, edit or make persistence fail before the placement is committed.
private final class PlacementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false, opened = false
    var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
    func execute(_ plan: FilePlacementPlan) throws -> FilePlacementReceipt {
        let receipt = try FileLibraryService.execute(plan)
        condition.lock(); waiting = true
        while !opened { condition.wait() }
        condition.unlock()
        return receipt
    }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
}

@main
@MainActor
struct ServiceCorrectnessTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static var failures: [String] = []
    static func main() async {
        await run("Failed UI mutations retain committed state without publishing optimistic values", testDurableUIActions)
        await run("File-library settings report failed persistence and permit a durable retry", testSettingsPersistenceResult)
        await run("Single language setting returns persistence failure without publishing a new language", testLanguagePersistenceResult)
        await run("Port submissions reject invalid input and preserve committed settings on save failure", testLocalAPIPortValidation)
        await run("Library queries preserve filters, membership search and edited snapshot contents", testLibraryQueries)
        await run("Library query sorting preserves optional values and identical-title ordering", testLibraryQuerySorting)
        await run("Sidebar counts deduplicate shared ancestors and match direct memberships", testSidebarCounts)
        await run("Deletion never trashes files before record removal reaches disk", testDeletionOrdering)
        await run("Committed Bib/RIS and ISBN/title imports use one bounded refresh queue", testImportQueue)
        await run("Disabled import enrichment performs no lookup", testDisabledImportQueue)
        await run("PDF enrichment replaces inferred fields while preserving edits during lookup", testPDFInferredFields)
        await run("TextBundle includes standard metadata and relative byte-identical image assets", testTextBundle)
        await run("Missing TextBundle images fail without leaving a partial package", testMissingBundleImage)
        await run("API delayed enrichment rejects a restored library with identical work IDs", { try await testAPIEnrichment(restore: true) })
        await run("API delayed enrichment rejects a changed work identifier", { try await testAPIEnrichment(restore: false) })
        await run("API paper and new tags fail atomically without phantom state", testAPITagTransaction)
        await run("API provider work is capped at three in-flight requests", testAPIBoundedEnrichment)
        await run("API configuration reuses pending listeners and switches the bound library safely", testAPILifecycle)
        await run("Cancelling background file work rolls back the uncommitted placement", { try await testFileQueue(mode: "cancel") })
        await run("Failed background file persistence restores bytes and keeps metadata", { try await testFileQueue(mode: "failure") })
        await run("Restoring a library rejects and rolls back stale background file work", { try await testFileQueue(mode: "restore") })
        await run("Background file work commits safely and preserves concurrent paper edits", { try await testFileQueue(mode: "success") })
        await run("Background rollback preserves a destination newly referenced by another paper", { try await testFileQueue(mode: "shared-destination") })
        await run("Quit shutdown waits for real placement rollback, blocks new jobs, and skips metadata network waits", testFileShutdown)
        await run("Chunk-level copy cancellation removes partial output and retains source bytes", testCopyCancellation)
        failures.forEach { print("FAIL: \($0)") }
        print("Service correctness: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
    static func run(_ name: String, _ test: () async throws -> Void) async {
        do { try await test(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerCorrectness-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    static func blockWrites(_ store: LibraryStore) throws -> URL {
        let saved = store.persistenceURL.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: store.persistenceURL, to: saved)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        try Data("Unrelated directory must survive".utf8).write(to: store.persistenceURL.appendingPathComponent("sentinel"))
        return saved
    }
    static func unblockWrites(_ store: LibraryStore, saved: URL) throws {
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.moveItem(at: saved, to: store.persistenceURL)
    }
    static func testLibraryQueries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parent = PaperCollection(name: "Research"), child = PaperCollection(name: "Robotics", parentID: parent.id)
        let tag = PaperTag(name: "Embodied")
        var recent = Paper(title: "Recent", doi: "10.1000/recent"); recent.dateAdded = now; recent.rating = 4
        recent.collectionIDs = [child.id]; recent.tagIDs = [tag.id]; recent.notes = "Private note"; recent.customFields = [CustomField(key: "project", value: "Linz")]
        var old = Paper(title: "Old"); old.dateAdded = now.addingTimeInterval(-31 * 24 * 60 * 60); old.lastOpenedAt = now
        old.attachments = [Attachment(kind: .pdf, filePath: "/unused/fixture.pdf", displayName: "fixture.pdf")]
        var snapshot = LibrarySnapshot(papers: [old, recent], collections: [parent, child], tags: [tag])
        func query(_ filter: LibraryFilter = .all, _ text: String = "", children: Bool = true) -> [UUID] {
            LibraryQuery.papers(in: snapshot, filter: filter, searchText: text, includeSubcollections: children,
                                sortDescriptor: .defaultValue, now: now).map(\.id)
        }
        try expect(query() == [recent.id, old.id], "Default ordering changed")
        try expect(query(.recentlyAdded) == [recent.id] && query(.recentlyOpened) == [old.id], "Recency filters changed")
        try expect(query(.unfiled) == [old.id] && query(.missingPDF) == [recent.id], "Attachment/collection filters changed")
        try expect(query(.missingIDs) == [old.id] && query(.noTags) == [old.id] && query(.rating(4)) == [recent.id], "Identifier, tag or rating filters changed")
        try expect(query(.collection(parent.id)) == [recent.id] && query(.collection(parent.id), children: false).isEmpty,
                   "Nested collection inclusion changed")
        try expect(query(.tag(tag.id)) == [recent.id], "Tag membership filter changed")
        for text in ["research/robotics", " EMBODIED ", "private note", "project linz"] {
            try expect(query(.all, text) == [recent.id], "Search lost a searchable field: \(text)")
        }
        snapshot.tags[0].name = "Renamed"; snapshot.collections[1].name = "Vision"
        try expect(query(.all, "embodied").isEmpty && query(.all, "renamed") == [recent.id]
                   && query(.all, "research/vision") == [recent.id], "A query reused stale tag names or collection paths")
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        try store.replaceSnapshotDurably(snapshot)
        try expect(store.filteredPapers(for: .collection(parent.id), searchText: "vision", includeSubcollections: true).map(\.id) == [recent.id],
                   "Store query delegation lost the current snapshot")
    }
    static func testLibraryQuerySorting() async throws {
        var alpha = Paper(title: "Alpha", authors: ["Zoe"], year: 2024); alpha.rating = 2; alpha.journal = "Zeta"
        alpha.dateAdded = Date(timeIntervalSince1970: 20); alpha.lastOpenedAt = Date(timeIntervalSince1970: 30)
        var beta = Paper(title: "Beta", authors: ["Ada"], year: 2026); beta.rating = 4; beta.journal = "Alpha"
        beta.dateAdded = Date(timeIntervalSince1970: 10)
        let snapshot = LibrarySnapshot(papers: [beta, alpha])
        let ascendingFirst: [PaperSortField: UUID] = [.title: alpha.id, .authors: beta.id, .year: alpha.id,
                                                   .source: beta.id, .rating: alpha.id, .dateAdded: beta.id, .lastOpened: beta.id]
        for field in PaperSortField.allCases {
            let ascending = LibraryQuery.papers(in: snapshot, filter: .all, searchText: "", includeSubcollections: true,
                                                sortDescriptor: PaperSortDescriptor(field: field, ascending: true)).map(\.id)
            let descending = LibraryQuery.papers(in: snapshot, filter: .all, searchText: "", includeSubcollections: true,
                                                 sortDescriptor: PaperSortDescriptor(field: field, ascending: false)).map(\.id)
            try expect(ascending.first == ascendingFirst[field] && descending == Array(ascending.reversed()), "Sort direction changed for \(field)")
        }
        var newer = alpha; newer.id = UUID(); newer.dateAdded = alpha.dateAdded.addingTimeInterval(1)
        let ties = LibrarySnapshot(papers: [alpha, newer])
        let ordered = LibraryQuery.papers(in: ties, filter: .all, searchText: "", includeSubcollections: true,
                                          sortDescriptor: PaperSortDescriptor(field: .year, ascending: true))
        try expect(ordered.map(\.id) == [newer.id, alpha.id], "Identical labels lost their prior newest-first tiebreak")
    }
    static func testSidebarCounts() async throws {
        let parent = PaperCollection(name: "Research"), child = PaperCollection(name: "Robotics", parentID: parent.id)
        let sibling = PaperCollection(name: "Vision", parentID: parent.id), tag = PaperTag(name: "Shared")
        var nested = Paper(title: "Several memberships", doi: "10.1000/nested")
        nested.collectionIDs = [child.id, sibling.id, child.id]; nested.tagIDs = [tag.id, tag.id]
        var parentAndChild = Paper(title: "Parent and child"); parentAndChild.collectionIDs = [parent.id, child.id]
        parentAndChild.attachments = [Attachment(kind: .pdf, filePath: "/unused/file.pdf", displayName: "file.pdf")]
        let unfiled = Paper(title: "Unfiled")
        let snapshot = LibrarySnapshot(papers: [nested, parentAndChild, unfiled], collections: [parent, child, sibling], tags: [tag])
        let nestedCounts = LibraryQuery.sidebarCounts(in: snapshot, includeSubcollections: true)
        let directCounts = LibraryQuery.sidebarCounts(in: snapshot, includeSubcollections: false)
        try expect(nestedCounts.all == 3 && nestedCounts.unfiled == 1 && nestedCounts.missingPDF == 2 && nestedCounts.missingIDs == 2,
                   "Static sidebar totals changed")
        try expect(nestedCounts.collections[parent.id] == 2 && nestedCounts.collections[child.id] == 2 && nestedCounts.collections[sibling.id] == 1,
                   "Shared ancestors or repeated memberships were counted twice")
        try expect(directCounts.collections[parent.id] == 1 && directCounts.collections[child.id] == 2 && directCounts.tags[tag.id] == 1,
                   "Direct collection or tag membership was counted incorrectly")
    }
    static func testDurableUIActions() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        let collection = try store.createCollection(name: "One"), second = try store.createCollection(name: "Two")
        let tag = try store.createTag(name: "One"), nextTag = try store.createTag(name: "Two")
        var paper = Paper(); paper.title = "Committed"; paper.collectionIDs = [collection]; paper.tagIDs = [tag]
        try store.addPaperDurably(paper)
        let revision = try store.snapshotRevisionToken(), diskBaseline = try Data(contentsOf: store.persistenceURL)
        let saved = try blockWrites(store)
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        var changed = store.paper(with: paper.id)!; changed.rating = 5
        try expect(!store.updatePaper(changed), "Rating reported success")
        store.markOpened(paper.id)
        store.updateAnnotations([ResearchAnnotation(page: 1, note: "Unsaved")], for: paper.id)
        try expect(!store.updateSetting(\.citekeyFormat, value: "new{year}"), "A single setting reported success after a failed write")
        var settings = store.settings; settings.annotationTemplate = "Unsaved template"
        try expect(!store.updateSettings(settings), "Settings reported success after a failed write")
        store.regenerateCitekeys()
        store.renameCollection(id: collection, name: "Unsaved")
        store.addPapers(ids: [paper.id], toCollection: second)
        try expect(!store.moveCollection(id: second, toParentID: nil, at: 0), "Move collection reported success")
        store.deleteCollection(id: collection)
        store.renameTag(id: tag, name: "Unsaved")
        store.updateTagColor(id: tag, colorHex: "#123456")
        store.addPapers(ids: [paper.id], toTag: nextTag)
        try expect(!store.moveTag(id: nextTag, at: 0), "Move tag reported success")
        store.deleteTag(id: tag)
        do { _ = try store.createCollection(name: "Unsaved"); throw Failure(description: "Collection creation swallowed save failure") }
        catch is Failure { throw Failure(description: "Collection creation swallowed save failure") } catch { }
        do { _ = try store.createTag(name: "Unsaved"); throw Failure(description: "Tag creation swallowed save failure") }
        catch is Failure { throw Failure(description: "Tag creation swallowed save failure") } catch { }
        try expect(try store.snapshotRevisionToken() == revision, "A failed UI mutation changed committed state")
        try expect(publications == 0, "Failed mutation published a transient snapshot")
        try expect(FileManager.default.fileExists(atPath: store.persistenceURL.appendingPathComponent("sentinel").path), "Save failure damaged unrelated contents")
        try unblockWrites(store, saved: saved)
        try expect(try Data(contentsOf: store.persistenceURL) == diskBaseline, "Disk baseline changed")
        try expect(store.updatePaper(changed), "Retry did not succeed after write access was restored")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).paper(with: paper.id)?.rating == 5, "Retry did not persist")
    }

    static func testSettingsPersistenceResult() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        try store.replaceSnapshotDurably(.empty)
        let original = store.settings
        let baseline = try Data(contentsOf: store.persistenceURL)
        let folder = url.appendingPathComponent("ChosenLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = try FileLibraryService.authorizedPreferences(root: folder, layout: .byPaper)
        var configured = original
        configured.fileLibrary = preferences
        configured.pdfOrganizationFolder = preferences.rootPath
        configured.browserUploadFolder = preferences.rootPath
        configured.pdfOrganizationMode = .copy
        var reset = configured
        reset.fileLibrary = FileLibraryPreferences(decision: .declined, layout: .byPaper)
        reset.pdfOrganizationFolder = ""
        reset.browserUploadFolder = ""
        reset.pdfOrganizationMode = .none

        let saved = try blockWrites(store)
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        try expect(!store.updateSettings(configured), "An unpersisted library authorization reported success")
        try expect(store.settings == original && store.statusMessage?.isEmpty == false,
                   "Failed authorization changed settings or lost its persistence error")
        store.statusMessage = nil
        try expect(!store.updateSettings(reset), "An unpersisted library reset reported success")
        try expect(store.settings == original && store.statusMessage?.isEmpty == false,
                   "Failed reset changed settings or lost its persistence error")
        try expect(publications == 0, "Failed settings decisions published an optimistic snapshot")
        try expect(try Data(contentsOf: saved) == baseline, "Failed settings decisions changed durable bytes")
        try expect(FileManager.default.fileExists(atPath: store.persistenceURL.appendingPathComponent("sentinel").path),
                   "A failed settings decision damaged unrelated directory contents")

        try unblockWrites(store, saved: saved)
        try expect(store.updateSettings(configured), "Authorization retry did not report its successful write")
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.settings.fileLibrary == preferences &&
                   reloaded.settings.pdfOrganizationFolder == preferences.rootPath &&
                   reloaded.settings.browserUploadFolder == preferences.rootPath &&
                   reloaded.settings.pdfOrganizationMode == .copy,
                   "Authorization reported success without persisting its root and operation")
        try expect(store.updateSettings(reset), "Reset retry did not report its successful write")
        let resetReloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(resetReloaded.settings.fileLibrary?.decision == .declined &&
                   resetReloaded.settings.pdfOrganizationFolder.isEmpty &&
                   resetReloaded.settings.browserUploadFolder.isEmpty &&
                   resetReloaded.settings.pdfOrganizationMode == .none,
                   "Reset reported success without persisting the declined decision")
    }

    static func testLanguagePersistenceResult() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        try store.replaceSnapshotDurably(.empty)
        let original = store.settings.languageIdentifier
        let baseline = try Data(contentsOf: store.persistenceURL)
        let saved = try blockWrites(store)
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        try expect(!store.updateSetting(\.languageIdentifier, value: "en"), "Failed language write returned success")
        try expect(store.settings.languageIdentifier == original && publications == 0,
                   "Failed language write published an uncommitted language")
        try expect(store.statusMessage?.isEmpty == false && Data(contentsOf: saved) == baseline,
                   "Failed language write lost its error or changed the durable baseline")
        try unblockWrites(store, saved: saved)
        try expect(store.updateSetting(\.languageIdentifier, value: "en"), "Language retry returned failure")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).settings.languageIdentifier == "en" && publications == 1,
                   "Language retry did not publish and persist exactly once")
    }

    static func testLocalAPIPortValidation() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        try store.replaceSnapshotDurably(.empty)
        let baseline = try Data(contentsOf: store.persistenceURL)
        let original = store.settings
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        for invalid in ["", " ", "0", "-1", "65536", "abc", "29467x", "1.5", "99999999999999999999999999999"] {
            try expect(!store.updateLocalAPIPort(from: invalid), "Invalid port \(invalid.debugDescription) was accepted")
            try expect(store.settings == original && publications == 0 && store.statusMessage?.isEmpty == false,
                       "Invalid port changed committed settings or did not report validation failure")
        }
        try expect(try Data(contentsOf: store.persistenceURL) == baseline, "Invalid port input rewrote the library")
        for valid in [1, 65535, 29468] {
            try expect(store.updateLocalAPIPort(from: " \(valid) "), "Valid port boundary \(valid) was rejected")
            try expect(LibraryStore(persistenceURL: store.persistenceURL).settings.localAPIPort == valid,
                       "Accepted port \(valid) was not persisted")
        }
        try expect(publications == 3, "Valid port submissions did not publish once each")
        try expect(store.updateLocalAPIPort(from: "29468") && publications == 3,
                   "Submitting an unchanged port needlessly republished settings")
        let saved = try blockWrites(store)
        let committed = try Data(contentsOf: saved)
        try expect(!store.updateLocalAPIPort(from: "29469"), "Unpersisted valid port reported success")
        try expect(store.settings.localAPIPort == 29468 && publications == 3 && store.statusMessage?.isEmpty == false,
                   "Failed port save changed visible settings or lost its persistence error")
        try expect(try Data(contentsOf: saved) == committed, "Failed port save changed committed bytes")
        try unblockWrites(store, saved: saved)
        try expect(store.updateLocalAPIPort(from: "29469"), "Port retry could not recover")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).settings.localAPIPort == 29469,
                   "Port retry did not persist")
    }

    static func testDeletionOrdering() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let source = url.appendingPathComponent("source.pdf"); try Data("Synthetic only".utf8).write(to: source)
        let location = url.appendingPathComponent("library.json")
        var trashCalls = 0, deletionWasPersisted = false
        let store = LibraryStore(persistenceURL: location, trashFile: { _ in
            trashCalls += 1
            deletionWasPersisted = LibraryStore(persistenceURL: location).papers.isEmpty
        })
        store.updateSetting(\.deleteAttachmentsToTrash, value: true)
        var paper = Paper(); paper.title = "Delete fixture"; paper.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: "source.pdf")]
        try store.addPaperDurably(paper)
        let saved = try blockWrites(store)
        try expect(!store.deletePapers(ids: [paper.id]), "Deletion reported success despite save failure")
        try expect(trashCalls == 0 && store.paper(with: paper.id) != nil && FileManager.default.fileExists(atPath: source.path), "Failed deletion touched files or visible records")
        try unblockWrites(store, saved: saved)
        try expect(store.deletePapers(ids: [paper.id]) && trashCalls == 1 && deletionWasPersisted, "Trash ran before durable removal")
    }
    static func testImportQueue() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        var lookedUp: [Paper] = []
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"), metadataLookup: { paper in
            await MainActor.run { lookedUp.append(paper) }
            var metadata = PaperMetadata(); metadata.journal = "Enriched source"; return metadata
        })
        var book = Paper(); book.title = "ISBN book"; book.isbn = "9780306406157"
        var article = Paper(); article.title = "Title-only article"
        let summary = await ImportService.commit(ImportService.prepare(papers: [book, article, book], store: store), into: store, targetFilter: nil)
        try expect(summary.imported == 2 && summary.skipped == 1, "Import duplicate semantics changed")
        await store.waitForMetadataRefresh()
        try expect(Set(lookedUp.map(\.id)) == [book.id, article.id] && lookedUp.count == 2, "Import lookup was missing or duplicated")
        try expect(lookedUp.first { $0.id == book.id }?.isbn == book.isbn && lookedUp.first { $0.id == article.id }?.title == article.title, "ISBN/title hints were lost")
        try expect(store.papers.allSatisfy { $0.journal == "Enriched source" }, "Queued metadata did not persist")
    }
    static func testDisabledImportQueue() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"), metadataLookup: { _ in await MainActor.run { calls += 1 }; return PaperMetadata() })
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        var paper = Paper(); paper.title = "No lookup"
        _ = await ImportService.commit(ImportService.prepare(papers: [paper], store: store), into: store, targetFilter: nil)
        await store.waitForMetadataRefresh()
        try expect(calls == 0 && !store.isMetadataRefreshing, "Disabled setting started metadata lookup")
    }
    static func testPDFInferredFields() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = BurstMetadata()
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"), metadataLookup: { await gate.fetch($0) })
        var inferred = Paper(); inferred.title = "document-file-name"; inferred.doi = "10.1000/inferred"
        var edited = Paper(); edited.title = "another-file-name"; edited.doi = "10.1000/edited"
        try store.addPaperDurably(inferred); try store.addPaperDurably(edited)
        store.enqueueMetadataRefresh(paperIDs: [inferred.id, edited.id], replacingUneditedFieldsFrom: [inferred.id: store.paper(with: inferred.id)!, edited.id: store.paper(with: edited.id)!])
        for _ in 0..<100 { if await gate.calls == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        var userEdit = store.paper(with: edited.id)!; userEdit.title = "User title during lookup"; userEdit.notes = "User note"
        try store.updatePaperDurably(userEdit)
        await gate.open(); await store.waitForMetadataRefresh()
        try expect(store.paper(with: inferred.id)?.title == "Provider title", "PDF filename was never replaced by fetched title")
        try expect(store.paper(with: edited.id)?.title == userEdit.title && store.paper(with: edited.id)?.notes == userEdit.notes,
                   "Provider overwrote a field edited during lookup")
        try expect(store.paper(with: edited.id)?.abstract == "Bounded result", "Concurrent edit blocked unrelated metadata enrichment")
    }
    static func imageFixture(in url: URL, missing: Bool = false) throws -> (Paper, LibrarySnapshot, Data) {
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10]), image = url.appendingPathComponent("figure.png")
        if !missing { try bytes.write(to: image) }
        var annotation = ResearchAnnotation(page: 1, note: "Image fixture"); annotation.imageFilePath = image.path
        var paper = Paper(); paper.title = "Bundle"; paper.citekey = "bundle"; paper.annotations = [annotation]
        var snapshot = LibrarySnapshot(); snapshot.papers = [paper]; snapshot.settings.annotationTemplate = "{{#image}}![]({{image}}){{/image}}"
        return (paper, snapshot, bytes)
    }
    static func testTextBundle() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (paper, snapshot, bytes) = try imageFixture(in: url)
        try ExportService.writeDetailedMarkdown([paper], snapshot: snapshot, to: url)
        let bundle = url.appendingPathComponent("bundle.textbundle")
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("info.json"))) as? [String: Any]
        try expect(info?["version"] as? Int == 2 && info?["type"] as? String == "net.daringfireball.markdown", "TextBundle manifest missing required version/type")
        let text = try String(contentsOf: bundle.appendingPathComponent("text.md"), encoding: .utf8)
        try expect(text.contains("assets/annotation-1.png") && !text.contains(url.path), "Bundle contains a nonportable image path")
        try expect(try Data(contentsOf: bundle.appendingPathComponent("assets/annotation-1.png")) == bytes, "Image bytes changed")
    }
    static func testMissingBundleImage() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (paper, snapshot, _) = try imageFixture(in: url, missing: true)
        do { try ExportService.writeDetailedMarkdown([paper], snapshot: snapshot, to: url); throw Failure(description: "Missing asset silently exported") }
        catch is Failure { throw Failure(description: "Missing asset silently exported") } catch { }
        try expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("bundle.textbundle").path), "Failed export left a partial bundle")
    }
    static func startAPI(store: LibraryStore, server: LocalAPIServer) async throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "No test socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        close(fd)
        try expect(bound == 0 && named == 0, "Could not reserve a loopback test port")
        let port = Int(UInt16(bigEndian: address.sin_port))
        store.updateSetting(\.localAPIEnabled, value: true); store.updateSetting(\.localAPIPort, value: port)
        server.reconfigure(with: store)
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(server.isRunning, server.statusText); return port
    }
    static func post(_ payload: [String: Any], port: Int) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/papers")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
    static func testAPIEnrichment(restore: Bool) async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = DelayedMetadata(), store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        let server = LocalAPIServer(metadataLookup: { await gate.fetch($0) }); defer { server.stop() }
        let port = try await startAPI(store: store, server: server)
        let (status, result) = try await post(["title": "API delayed fixture", "doi": "10.1000/before", "enrich": true], port: port)
        try expect(status == 200 && result["enrichmentStatus"] as? String == "pending", "API fixture creation failed")
        let id = UUID(uuidString: result["id"] as! String)!
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await gate.started
        try expect(started, "Injected provider did not begin")
        if restore { try store.replaceSnapshotDurably(store.snapshot) }
        else { var changed = store.paper(with: id)!; changed.doi = "10.1000/after"; try store.updatePaperDurably(changed) }
        let baseline = try store.snapshotRevisionToken()
        await gate.release(); await server.waitForEnrichment()
        try expect(try store.snapshotRevisionToken() == baseline, "Stale API metadata crossed the library/work boundary")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).paper(with: id)?.abstract == "", "Stale API metadata reached disk")
    }
    static func testAPITagTransaction() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json")), server = LocalAPIServer()
        defer { server.stop() }
        let port = try await startAPI(store: store, server: server), before = try store.snapshotRevisionToken()
        let saved = try blockWrites(store)
        let (status, _) = try await post(["title": "Atomic tags", "tags": ["Never published", "Never published"]], port: port)
        try expect(status == 500 && store.tags.isEmpty && store.papers.isEmpty, "API left phantom tags/paper")
        try expect(try store.snapshotRevisionToken() == before, "Failed API transaction changed published state")
        try unblockWrites(store, saved: saved)
        let (retry, _) = try await post(["title": "Atomic tags", "tags": ["One new tag", "One new tag"]], port: port)
        try expect(retry == 200 && store.tags.count == 1 && store.papers.first?.tagIDs == store.tags.map(\.id), "Successful transaction duplicated or lost tag relationships")
    }

    static func testAPIBoundedEnrichment() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = BurstMetadata(), store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"))
        let server = LocalAPIServer(metadataLookup: { await gate.fetch($0) }); defer { server.stop() }
        let port = try await startAPI(store: store, server: server)
        for index in 0..<8 {
            let (status, _) = try await post(["title": "Burst \(index)", "doi": "10.1000/burst\(index)", "enrich": true], port: port)
            try expect(status == 200, "Burst create failed")
        }
        let active = await gate.active, calls = await gate.calls
        try expect(active == 3 && calls == 3, "More than three provider requests started before a slot became free")
        await gate.open(); await server.waitForEnrichment()
        let peak = await gate.peak, total = await gate.calls
        try expect(peak == 3 && total == 8 && store.papers.allSatisfy { $0.abstract == "Bounded result" }, "Bounded work lost requests or exceeded the limit")
    }

    static func testAPILifecycle() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("first.json")), server = LocalAPIServer()
        defer { server.stop() }
        var starts = 0
        let observation = server.$statusText.sink { if $0 == "Starting..." { starts += 1 } }
        defer { observation.cancel() }
        let port = try await startAPI(store: store, server: server)
        server.stop()
        starts = 0
        server.reconfigure(with: store)
        server.reconfigure(with: store)
        server.reconfigure(with: store)
        try expect(starts == 1, "Repeated configuration restarted a listener that was still starting")
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(server.isRunning, server.statusText)
        let other = LibraryStore(persistenceURL: url.appendingPathComponent("second.json"))
        other.updateSetting(\.localAPIEnabled, value: true); other.updateSetting(\.localAPIPort, value: port)
        let paper = Paper(title: "Second library only"); try other.addPaperDurably(paper)
        server.reconfigure(with: other)
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/papers")!)
        let papers = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["papers"] as? [[String: Any]]
        try expect((response as? HTTPURLResponse)?.statusCode == 200 && papers?.first?["id"] as? String == paper.id.uuidString,
                   "An unchanged port kept serving a previous library")
        // A partially received upload must release its socket when the service
        // stops, rather than keeping the disabled listener's resources alive.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try expect(descriptor >= 0, "No partial-request test socket")
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try expect(connected == 0, "Could not connect partial request")
        let partial = Data("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 500\r\n\r\n{\"title\":".utf8)
        let sent = partial.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!, $0.count, 0) }
        try expect(sent == partial.count, "Could not send partial request")
        try await Task.sleep(nanoseconds: 60_000_000)
        server.stop()
        let closed = await Task.detached {
            var byte: UInt8 = 0
            let received = recv(descriptor, &byte, 1, 0)
            return received == 0 || (received == -1 && errno == ECONNRESET)
        }.value
        try expect(closed && other.snapshot.papers.count == 1, "Stopping left an accepted upload socket open or committed partial input")
        try await Task.sleep(nanoseconds: 60_000_000)
        try expect(!server.isRunning, "A cancelled listener published a late ready state")
    }

    static func testFileQueue(mode: String) async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = PlacementGate()
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"), filePlacement: { try gate.execute($0) })
        let owned = url.appendingPathComponent("owned"); try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        var settings = store.settings
        settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: owned.path)
        settings.pdfOrganizationMode = .move; settings.confirmBeforeMovingFiles = false; settings.autoRenamePDFs = false
        store.updateSettings(settings)
        let source = url.appendingPathComponent("source.pdf"), bytes = Data("Synthetic worker bytes".utf8)
        try bytes.write(to: source)
        var paper = Paper(); paper.title = "File worker"; paper.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: "source.pdf")]
        try store.addPaperDurably(paper)
        var baseline = try store.snapshotRevisionToken()
        try expect(store.enqueueFileOperation(paperIDs: [paper.id]), "Could not start file work")
        for _ in 0..<200 { if gate.isWaiting { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(gate.isWaiting && store.isFileOperationRunning, "Background placement did not start, or blocked the main actor")
        let destination = owned.appendingPathComponent("source.pdf")
        try expect(FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: source.path), "Fixture did not perform a real move before the gate")
        var saved: URL?
        switch mode {
        case "cancel": store.cancelFileOperation()
        case "failure": saved = try blockWrites(store)
        case "restore": try store.replaceSnapshotDurably(store.snapshot)
        case "shared-destination":
            var other = Paper(); other.title = "New destination reference"
            other.attachments = [Attachment(kind: .pdf, filePath: destination.path, displayName: destination.lastPathComponent)]
            try store.addPaperDurably(other)
            baseline = try store.snapshotRevisionToken()
        default:
            var edited = store.paper(with: paper.id)!; edited.notes = "Edited during IO"; try store.updatePaperDurably(edited)
        }
        gate.open(); await store.waitForFileOperation()
        try expect(!store.isFileOperationRunning && store.fileOperationProgress?.isRunning == false, "File worker did not settle")
        if mode == "success" {
            let current = store.paper(with: paper.id)!
            try expect(current.notes == "Edited during IO" && current.primaryPDF?.filePath == destination.path, "File commit overwrote a concurrent edit or lost its destination")
            try expect(try Data(contentsOf: destination) == bytes && store.fileOperationProgress?.completed == 1, "Successful file result is not durable")
        } else if mode == "shared-destination" {
            try expect(try Data(contentsOf: source) == bytes && Data(contentsOf: destination) == bytes, "Rollback broke a new reference to its destination")
            try expect(try store.snapshotRevisionToken() == baseline && store.fileOperationProgress?.completed == 0,
                       "Unsafe shared destination was committed or other edits were rolled back")
        } else {
            try expect(try Data(contentsOf: source) == bytes && !FileManager.default.fileExists(atPath: destination.path), "Uncommitted placement was not rolled back")
            try expect(try store.snapshotRevisionToken() == baseline && store.fileOperationProgress?.completed == 0, "Failed/cancelled/stale work published a change")
            if mode == "failure" { try expect(store.fileOperationProgress?.failed == 1, "Persistence failure was hidden") }
            else { try expect(store.fileOperationProgress?.cancelled == true, "Stop/restore was not reported as cancelled") }
        }
        if let saved { try unblockWrites(store, saved: saved) }
    }

    static func testCopyCancellation() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let owned = url.appendingPathComponent("owned"); try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        let source = url.appendingPathComponent("source.pdf"), bytes = Data(repeating: 17, count: 3 * 1024 * 1024)
        try bytes.write(to: source)
        var paper = Paper(); paper.title = "Copy fixture"
        var snapshot = LibrarySnapshot(); snapshot.settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: owned.path)
        snapshot.settings.pdfOrganizationMode = .copy; snapshot.settings.autoRenamePDFs = false
        let plan = try FileLibraryService.plan(source: source, paper: paper, snapshot: snapshot)
        var checks = 0
        do {
            _ = try FileLibraryService.execute(plan, checkCancellation: { checks += 1; if checks >= 3 { throw CancellationError() } })
            throw Failure(description: "Copy ignored cancellation")
        } catch is CancellationError { }
        try expect(try Data(contentsOf: source) == bytes && !FileManager.default.fileExists(atPath: plan.destination.path), "Cancelled copy damaged source or left partial bytes")
    }

    static func testFileShutdown() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = PlacementGate(), network = DelayedMetadata()
        let store = LibraryStore(persistenceURL: url.appendingPathComponent("library.json"),
                                 metadataLookup: { await network.fetch($0) }, filePlacement: { try gate.execute($0) })
        defer {
            gate.open(); store.cancelMetadataRefresh()
            Task { await network.release() }
            LibraryStore.resumeAfterCancelledFileOperationShutdown()
        }
        let owned = url.appendingPathComponent("owned"); try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        var settings = store.settings
        settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: owned.path)
        settings.pdfOrganizationMode = .move; settings.confirmBeforeMovingFiles = false; settings.autoRenamePDFs = false
        store.updateSettings(settings)
        let source = url.appendingPathComponent("source.pdf"), bytes = Data("Quit must preserve these bytes".utf8)
        try bytes.write(to: source)
        var paper = Paper(); paper.title = "Quit fixture"; paper.doi = "10.1000/quit"
        paper.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: "source.pdf")]
        try store.addPaperDurably(paper)
        let baseline = try Data(contentsOf: store.persistenceURL)
        store.enqueueMetadataRefresh(paperIDs: [paper.id])
        store.enqueueFileOperation(paperIDs: [paper.id])
        for _ in 0..<200 { if gate.isWaiting { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(gate.isWaiting && LibraryStore.hasRunningFileOperations, "Real background placement did not reach its uncommitted gate")
        let firstShutdown = LibraryStore.beginFileOperationShutdown()
        let repeatedShutdown = LibraryStore.beginFileOperationShutdown()
        try expect(store.isFileOperationRunning && !store.enqueueFileOperation(paperIDs: [paper.id]), "Quit accepted a new file job or declared IO finished too soon")
        try expect(!FileManager.default.fileExists(atPath: source.path), "Fixture did not really move before termination")
        gate.open(); await firstShutdown.value; await repeatedShutdown.value
        try expect(!LibraryStore.hasRunningFileOperations && store.fileOperationProgress?.cancelled == true, "Quit replied before file work settled")
        try expect(try Data(contentsOf: source) == bytes && Data(contentsOf: store.persistenceURL) == baseline, "Quit did not restore bytes and original committed metadata")
        try expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("source.pdf").path), "Quit left an uncommitted destination")
        try expect(store.isMetadataRefreshing, "Quit unnecessarily waited for or cancelled metadata network work")
        store.cancelMetadataRefresh(); await network.release(); await store.waitForMetadataRefresh()
        LibraryStore.resumeAfterCancelledFileOperationShutdown()
        try expect(store.enqueueFileOperation(paperIDs: [paper.id]), "Aborting quit did not re-enable file operations")
        await store.waitForFileOperation()
    }
}
