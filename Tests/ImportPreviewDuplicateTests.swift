import Foundation

@main
@MainActor
struct ImportPreviewDuplicateTests {
    struct Failure: Error { let message: String }

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }

    static func fixture() throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-Preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        return (root, store)
    }

    static func paper(_ title: String, doi: String) -> Paper {
        var paper = Paper()
        paper.title = title; paper.doi = doi; paper.year = 2026
        return paper
    }

    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Preview exposes same-import duplicates without changing library bytes", testPrepare),
            ("Deselecting a predecessor clears its duplicate relationship", testDeselection),
            ("Same-import Skip and Replace agree with the preview", testPolicies),
            ("Different reliable DOIs remain separate in the preview and commit", testDistinctDOIs),
            ("Existing-library matches have saved IDs and refresh after deletion", testExisting),
            ("Repeated UUIDs are shown before commit", testIdentity),
            ("Skipped predecessors do not create phantom duplicates for later candidates", testSkippedPredecessor),
            ("Replacing a batch predecessor updates later title-based duplicate matches", testReplacedBatchPredecessor),
            ("Replacing a saved record removes its old title from later preview matches", testReplacedSavedPredecessor)
        ]
        var passed = 0
        for (name, test) in tests {
            do { try await test(); passed += 1; print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)") }
        }
        print("\(passed) passed, \(tests.count - passed) failed")
        exit(passed == tests.count ? 0 : 1)
    }

    static func testPrepare() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: store.persistenceURL)
        let first = paper("First bibliography", doi: "10.5555/preview")
        let second = paper("Updated bibliography", doi: "https://doi.org/10.5555/preview")
        let plan = ImportService.prepare(papers: [first, second], store: store)
        try expect(!plan.candidates[0].hasDuplicate, "The first item was incorrectly a duplicate")
        try expect(plan.candidates[1].batchDuplicateID == plan.candidates[0].id,
                   "The second item did not identify its preceding preview candidate")
        try expect(plan.candidates[1].duplicateID == nil, "An unsaved preview item was exposed as a saved library record")
        try expect(store.papers.isEmpty && (try Data(contentsOf: store.persistenceURL)) == before,
                   "Read-only duplicate preparation changed the library")
        let ris = root.appendingPathComponent("batch.ris")
        try "TY  - JOUR\nTI  - First bibliography\nDO  - 10.5555/preview\nER  -\nTY  - JOUR\nTI  - Updated bibliography\nDO  - 10.5555/preview\nER  -\n".write(to: ris, atomically: true, encoding: .utf8)
        let filePlan = await ImportService.prepare([ris], store: store)
        try expect(filePlan.candidates.count == 2 && filePlan.candidates[1].hasDuplicate,
                   "File preparation did not use the same batch duplicate checks")
    }

    static func testDeselection() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = paper("First bibliography", doi: "10.5555/selection")
        let second = paper("Selected bibliography", doi: "10.5555/selection")
        var plan = ImportService.prepare(papers: [first, second], store: store)
        plan.candidates[1].duplicateAction = .replace
        plan.candidates[0].isSelected = false
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        try expect(!plan.candidates[1].hasDuplicate, "A deselected predecessor still made the selected item a duplicate")
        try expect(plan.candidates[1].duplicateAction == .replace, "Refreshing duplicate identity reset the user's policy")
        plan.candidates[0].isSelected = true
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        try expect(plan.candidates[1].batchDuplicateID == plan.candidates[0].id,
                   "Reselecting the predecessor did not restore the visible duplicate")
        plan.candidates[0].isSelected = false
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let result = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(result.imported == 1 && result.replaced == 0 && store.papers.first?.id == second.id,
                   "The selected item was skipped/replaced despite having no selected predecessor")
    }

    static func testPolicies() async throws {
        for action in ImportDuplicateAction.allCases {
            let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var first = paper("Original bibliography", doi: "10.5555/policy")
            first.notes = "Owned notes"; first.rating = 4
            let second = paper("Replacement bibliography", doi: "10.5555/policy")
            var plan = ImportService.prepare(papers: [first, second], store: store)
            plan.candidates[1].duplicateAction = action
            let result = await ImportService.commit(plan, into: store, targetFilter: nil)
            try expect(result.imported == 1 && result.failed == 0 && store.papers.count == 1,
                       "Same-import policy produced an unexpected insertion result")
            let saved = store.papers[0]
            try expect(saved.id == first.id && saved.notes == "Owned notes" && saved.rating == 4,
                       "Same-import duplicate handling lost the first item's identity/local fields")
            try expect(saved.title == (action == .skip ? first.title : second.title), "The chosen duplicate policy was ignored")
            try expect(action == .skip ? result.skipped == 1 : result.replaced == 1,
                       "The summary disagreed with the selected duplicate policy")
        }
    }

    static func testDistinctDOIs() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = paper("Matching title", doi: "10.5555/distinct-a")
        let second = paper("Matching title", doi: "10.5555/distinct-b")
        let plan = ImportService.prepare(papers: [first, second], store: store)
        try expect(!plan.candidates.contains(where: \.hasDuplicate), "Different reliable DOIs were collapsed by title")
        let result = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(result.imported == 2 && store.papers.count == 2, "Distinct preview items did not both import")
    }

    static func testExisting() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = paper("Saved bibliography", doi: "10.5555/existing")
        _ = try store.addPaperDurably(existing)
        var plan = ImportService.prepare(papers: [paper("Incoming bibliography", doi: existing.doi)], store: store)
        try expect(plan.candidates[0].duplicateID == existing.id && plan.candidates[0].batchDuplicateID == nil,
                   "A saved library duplicate did not expose the correct open-existing identity")
        try store.performDurableMutation { $0.papers = [] }
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        try expect(!plan.candidates[0].hasDuplicate, "A removed library record remained openable from the preview")
    }

    static func testIdentity() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = paper("Repeated identity", doi: "")
        let plan = ImportService.prepare(papers: [first, first], store: store)
        try expect(plan.candidates[1].batchDuplicateID == plan.candidates[0].id,
                   "Commit's repeated UUID identity was missing from the preview")
    }

    static func testSkippedPredecessor() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = paper("Title One", doi: "10.5555/skip-chain")
        let skipped = paper("Title Two", doi: first.doi)
        let last = paper("Title Two", doi: "")
        let plan = ImportService.prepare(papers: [first, skipped, last], store: store)
        let previewSaysDuplicate = plan.candidates[2].hasDuplicate
        let result = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(result.imported == 2 && result.skipped == 1 && result.replaced == 0 && result.failed == 0 &&
                   store.paper(with: first.id) != nil && store.paper(with: last.id) != nil,
                   "The skipped-predecessor fixture did not actually insert the final distinct paper")
        try expect(!previewSaysDuplicate,
                   "Preview marked C as a duplicate of skipped B, but commit inserted C (imported=2, skipped=1)")
    }

    static func testReplacedBatchPredecessor() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = paper("Title One", doi: "10.5555/replace-batch-chain")
        let replacement = paper("Title Two", doi: first.doi)
        let last = paper("Title One", doi: "")
        var plan = ImportService.prepare(papers: [first, replacement, last], store: store)
        try expect(plan.candidates[2].hasDuplicate,
                   "With the default Skip policy, the first paper's title should still match the final candidate")
        plan.candidates[1].duplicateAction = .replace
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let firstReplaceSaysDuplicate = plan.candidates[2].hasDuplicate
        plan.candidates[1].duplicateAction = .skip
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let revertedSkipSaysDuplicate = plan.candidates[2].hasDuplicate
        plan.candidates[1].duplicateAction = .replace
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let previewSaysDuplicate = plan.candidates[2].hasDuplicate
        let result = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(result.imported == 2 && result.replaced == 1 && result.skipped == 0 && result.failed == 0 &&
                   store.paper(with: first.id)?.title == replacement.title && store.paper(with: last.id) != nil,
                   "The batch replacement fixture did not replace A and insert the final distinct paper")
        try expect(!firstReplaceSaysDuplicate && revertedSkipSaysDuplicate && !previewSaysDuplicate,
                   "Preview retained A's old title or failed to recompute Replace/Skip/Replace, while commit inserted C (imported=2, replaced=1)")
    }

    static func testReplacedSavedPredecessor() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = paper("Title One", doi: "10.5555/replace-saved-chain")
        try store.addPaperDurably(existing)
        let replacement = paper("Title Two", doi: existing.doi)
        let last = paper("Title One", doi: "")
        var plan = ImportService.prepare(papers: [replacement, last], store: store)
        try expect(plan.candidates[0].duplicateID == existing.id && plan.candidates[1].hasDuplicate,
                   "The saved-record fixture should initially match both candidates under Skip")
        plan.candidates[0].duplicateAction = .replace
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let firstReplaceSaysDuplicate = plan.candidates[1].hasDuplicate
        plan.candidates[0].duplicateAction = .skip
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let revertedSkipSaysDuplicate = plan.candidates[1].hasDuplicate
        plan.candidates[0].duplicateAction = .replace
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
        let previewSaysDuplicate = plan.candidates[1].hasDuplicate
        let result = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(result.imported == 1 && result.replaced == 1 && result.skipped == 0 && result.failed == 0 &&
                   store.paper(with: existing.id)?.title == replacement.title && store.paper(with: last.id) != nil,
                   "The saved replacement fixture did not replace E and insert the final distinct paper")
        try expect(!firstReplaceSaysDuplicate && revertedSkipSaysDuplicate && !previewSaysDuplicate,
                   "Preview used saved E's old title or failed to recompute Replace/Skip/Replace, while commit inserted B (imported=1, replaced=1)")
    }
}
