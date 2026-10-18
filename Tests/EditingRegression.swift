import Darwin
import Foundation

@main
@MainActor
struct EditingRegression {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var failures: [String] = []
    private static var passed = 0

    static func main() async {
        await run("Quit flush persists an edit before its debounce expires", testTerminationFlush)
        await run("Selection changes commit the previous paper and reject stale editor writes", testSelectionChanges)
        await run("Autosave commits the latest draft without a Save action", testAutosave)
        await run("Concurrent native edits and read-only attachments survive draft commits", testConcurrentEdits)
        await run("Deleting a paper while editing cannot recreate it", testDeletedPaper)
        await run("Type-specific fields remain editable and identifiers stay independent", testFieldCoverage)
        await run("BibTeX recognizes and exports all added paper types", testPaperTypes)
        await run("A failed save preserves drafts across selection changes and retries", testFailedSaveRetry)
        await run("A failed window draft survives until a later successful global flush", testFailedWindowRetention)
        for failure in failures { print("FAIL: \(failure)") }
        print("Editing regression: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS: \(name)")
        } catch { failures.append("\(name): \(error)") }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    private static func fixture() throws -> (URL, LibraryStore, Paper, Paper) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerEditing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var first = Paper(); first.title = "First paper"
        var second = Paper(); second.title = "Second paper"
        store.addPaper(first); store.addPaper(second)
        return (root, store, first, second)
    }

    private static func testTerminationFlush() async throws {
        let (root, store, first, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        editing.select(first.id, in: store)
        var draft = editing.draft
        draft.notes = "The last keystroke before quitting"
        editing.edit(draft)
        try expect(store.paper(with: first.id)?.notes == "", "Fixture must still have a pending draft")
        PaperDraftSession.flushAll()
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.paper(with: first.id)?.notes == draft.notes, "Synchronous termination flush lost the final text")
    }

    private static func testSelectionChanges() async throws {
        let (root, store, first, second) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 30_000_000)
        editing.select(first.id, in: store)
        let oldBinding = editing.binding(for: first.id)
        var oldDraft = editing.draft
        oldDraft.title = "First edited"
        editing.edit(oldDraft)
        editing.select(second.id, in: store)
        try expect(store.paper(with: first.id)?.title == "First edited", "Selecting another paper did not flush the previous draft")
        oldDraft.title = "Late write from a disappearing editor"
        editing.edit(oldDraft)
        oldBinding.wrappedValue.title = "Late field binding write"
        try expect(editing.draft.id == second.id && editing.draft.title == "Second paper", "A stale binding overwrote the current paper")
        var next = editing.draft; next.notes = "Second edited"
        editing.edit(next)
        editing.select(nil, in: store)
        try await Task.sleep(nanoseconds: 80_000_000)
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.paper(with: first.id)?.title == "First edited", "Cancelled autosave replaced the committed previous draft")
        try expect(reloaded.paper(with: second.id)?.notes == "Second edited", "Clearing selection lost the current draft")
    }

    private static func testAutosave() async throws {
        let (root, store, first, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 20_000_000)
        editing.select(first.id, in: store)
        var draft = editing.draft; draft.notes = "Partial"
        editing.edit(draft)
        draft.notes = "Final typed text"
        editing.edit(draft)
        try await Task.sleep(nanoseconds: 80_000_000)
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.paper(with: first.id)?.notes == "Final typed text", "Debounced autosave did not persist the newest edit")
    }

    private static func testConcurrentEdits() async throws {
        let (root, store, first, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        editing.select(first.id, in: store)
        var draft = editing.draft; draft.notes = "Inspector notes"
        editing.edit(draft)
        var external = store.paper(with: first.id)!
        external.rating = 4
        external.doi = "10.5555/external"
        external.attachments = [Attachment(kind: .pdf, filePath: root.appendingPathComponent("source.pdf").path, displayName: "source.pdf")]
        external.attachments[0].isReadOnlyReference = true
        store.updatePaper(external)
        editing.receive(store.paper(with: first.id))
        draft = editing.draft; draft.abstract = "Inspector abstract"
        editing.edit(draft)
        editing.flush()
        let saved = LibraryStore(persistenceURL: store.persistenceURL).paper(with: first.id)!
        try expect(saved.notes == "Inspector notes" && saved.abstract == "Inspector abstract", "A store refresh erased pending inspector text")
        try expect(saved.rating == 4 && saved.doi == "10.5555/external", "Draft commit overwrote concurrent table/API metadata")
        try expect(saved.attachments.count == 1 && saved.attachments[0].isReadOnlyReference, "Draft commit lost source-file protection")
    }

    private static func testDeletedPaper() async throws {
        let (root, store, first, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        editing.select(first.id, in: store)
        var draft = editing.draft; draft.notes = "Pending"
        editing.edit(draft)
        store.deletePapers(ids: [first.id])
        editing.flush()
        try expect(LibraryStore(persistenceURL: store.persistenceURL).paper(with: first.id) == nil, "Flushing a deleted paper recreated its record")
    }

    private static func blockPersistence(_ store: LibraryStore) throws -> URL {
        let preserved = store.persistenceURL.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: store.persistenceURL, to: preserved)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        return preserved
    }

    private static func unblockPersistence(_ store: LibraryStore, preserved: URL) throws {
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
    }

    private static func testFailedSaveRetry() async throws {
        let (root, store, first, second) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        editing.select(first.id, in: store)
        var draft = editing.draft; draft.notes = "First unsaved draft"
        editing.edit(draft)
        let preserved = try blockPersistence(store)
        try expect(!editing.flush(), "An unwritable library was reported as saved")
        try expect(store.paper(with: first.id)?.notes == "", "A failed durable write published unsaved metadata")
        editing.select(second.id, in: store)
        draft = editing.draft; draft.notes = "Second unsaved draft"
        editing.edit(draft)
        editing.select(first.id, in: store)
        try expect(editing.draft.notes == "First unsaved draft", "Selecting another paper discarded the failed draft")
        try expect(!PaperDraftSession.flushAll(), "Global flush allowed quit or restore with unsaved drafts")
        try unblockPersistence(store, preserved: preserved)
        try expect(PaperDraftSession.flushAll(), "A recovered library could not retry its retained drafts")
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.paper(with: first.id)?.notes == "First unsaved draft", "The first pending draft did not reach disk after retry")
        try expect(reloaded.paper(with: second.id)?.notes == "Second unsaved draft", "The deferred second draft did not reach disk after retry")
    }

    private static func testFailedWindowRetention() async throws {
        let (root, store, first, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var editing: PaperDraftSession? = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        weak var retained = editing
        editing!.select(first.id, in: store)
        var draft = editing!.draft; draft.title = "Last edit in a closing window"
        editing!.edit(draft)
        let preserved = try blockPersistence(store)
        try expect(!editing!.flush(), "Closing a window ignored its save failure")
        editing = nil
        try expect(retained != nil, "Closing the owning window released its unsaved draft")
        try unblockPersistence(store, preserved: preserved)
        let flushed = autoreleasepool { PaperDraftSession.flushAll() }
        try expect(flushed, "A retained closed-window draft could not be retried")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).paper(with: first.id)?.title == draft.title,
                   "A retained closed-window draft never reached disk")
        try expect(retained == nil, "A successfully saved closed-window session was retained indefinitely")
        retained = nil
    }

    private static func testFieldCoverage() async throws {
        for type in PaperType.allCases {
            var paper = Paper(); paper.paperType = type
            for field in InspectorMetadataField.all { field.setValue("Existing \(field.id)", in: &paper) }
            let fields = InspectorMetadataField.primary(for: paper) + InspectorMetadataField.additional(for: paper)
            try expect(fields.count == Set(fields.map(\.id)).count, "Duplicate editor controls for \(type)")
            try expect(Set(fields.map(\.id)) == Set(InspectorMetadataField.all.map(\.id)), "An existing field is inaccessible for \(type)")
            let doi = fields.first { $0.id == "doi" }!
            doi.setValue("", in: &paper)
            try expect(paper.eprint == "Existing eprint" && paper.isbn == "Existing isbn", "Clearing DOI changed independent arXiv/ISBN identifiers")
            fields.first { $0.id == "isbn" }!.setValue("978-0-306-40615-7", in: &paper)
            try expect(paper.doi.isEmpty && paper.eprint == "Existing eprint", "Changing ISBN changed another identifier")
        }
        var article = Paper(); article.paperType = .article
        let articleFields = Set((InspectorMetadataField.primary(for: article) + InspectorMetadataField.additional(for: article)).map(\.id))
        try expect(articleFields.isSuperset(of: ["journal", "volume", "issue", "pages", "doi"]), "An empty journal article is missing its citation fields")
        var book = Paper(); book.paperType = .book
        let bookFields = Set((InspectorMetadataField.primary(for: book) + InspectorMetadataField.additional(for: book)).map(\.id))
        try expect(bookFields.isSuperset(of: ["publisher", "edition", "series", "isbn"]), "An empty book is missing its publication fields")
        var conference = Paper(); conference.paperType = .inProceedings
        let conferenceFields = Set((InspectorMetadataField.primary(for: conference) + InspectorMetadataField.additional(for: conference)).map(\.id))
        try expect(conferenceFields.isSuperset(of: ["bookTitle", "event", "eventDate", "venue", "publisher"]), "Conference metadata has no edit entry point")
        var preprint = Paper(); preprint.paperType = .preprint
        let advancedIDs = Set(InspectorMetadataField.additional(for: preprint).map(\.id))
        try expect(advancedIDs.isSuperset(of: ["subtitle", "eprintType", "howpublished", "urlDate", "month", "language", "pubState"]), "Reference preprint advanced fields are missing")
        let pinnedIDs = Set(InspectorMetadataField.additional(for: preprint, including: ["volume", "school"]).map(\.id))
        try expect(pinnedIDs.isSuperset(of: ["volume", "school"]), "Pinned fields disappeared after changing the paper type")
    }

    private static func testPaperTypes() async throws {
        try expect(PaperType.allCases.count == 15, "The reference application's 15 paper types are incomplete")
        for (source, expected) in [("thesis", PaperType.thesis), ("preprint", .preprint), ("incollection", .inCollection)] {
            let records = BibTeXParser.parse("@\(source){entry, title={Typed record}}")
            try expect(records.first?.paperType == expected, "BibTeX \(source) fell back to another type")
        }
        var chapter = Paper(); chapter.paperType = .inCollection; chapter.title = "Collected chapter"
        let exported = ExportService.bibTeX(for: [chapter])
        try expect(exported.hasPrefix("@incollection{"), "Collected chapters export with the wrong BibTeX type")
        try expect(BibTeXParser.parse(exported).first?.paperType == .inCollection, "Collected chapters lose their type on round trip")
    }
}
