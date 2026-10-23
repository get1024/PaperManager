import Darwin
import Foundation

private actor LookupProbe {
    var active = 0
    var peak = 0
    var calls: [UUID: Int] = [:]
    var failures = Set<UUID>()
    var delay: UInt64 = 50_000_000
    func setFailures(_ ids: Set<UUID>) { failures = ids }
    func fetch(_ paper: Paper) async throws -> PaperMetadata {
        active += 1
        peak = max(peak, active)
        calls[paper.id, default: 0] += 1
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: delay)
        if failures.contains(paper.id) { throw PaperManagerError.message("Synthetic provider failure") }
        var metadata = PaperMetadata()
        metadata.title = "Provider title"
        metadata.abstract = "Provider abstract"
        metadata.journal = "Provider source"
        return metadata
    }
}

/// Deliberately ignores Task cancellation until explicitly released, like an
/// external provider whose response is already in transit during a restore.
private actor RestoreLookupGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter: CheckedContinuation<Void, Never>?

    func fetch(_ paper: Paper) async -> PaperMetadata {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released { await withCheckedContinuation { resultWaiter = $0 } }
        var metadata = PaperMetadata()
        metadata.abstract = "Provider result from an earlier request"
        metadata.journal = "Provider source"
        return metadata
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() {
        released = true
        resultWaiter?.resume()
        resultWaiter = nil
    }
}

@main
@MainActor
struct MetadataRefreshTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failures: [String] = []

    static func main() async {
        await run("Exact hints fall back and arXiv DOIs bypass Crossref", testLookupFallback)
        await run("Cancellation stops lookup fallback", testLookupCancellation)
        await run("arXiv parser rejects error entries and mismatched identifiers", testArxivResponse)
        await run("Queue caps concurrency, deduplicates and accepts appended work", testQueue)
        await run("Refresh preserves intervening edits and deleted papers", testConcurrentChanges)
        await run("Changing an identifier rejects metadata from the old work", testChangedIdentity)
        await run("Cancellation prevents late commits", testCancellation)
        await run("Provider failures can be retried", testRetry)
        await run("Failed persistence is reported without a false update", testWriteFailure)
        await run("Snapshot replacement isolates in-flight results even for identical paper IDs", testRestoreGeneration)
        await run("A failed snapshot replacement leaves the original refresh queue valid", testFailedRestoreGeneration)
        await run("Launch library uses explicit environment, then valid preference, then default", testPreferredLibrary)
        for failure in failures { print("FAIL: \(failure)") }
        print("Metadata refresh: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func fixture(count: Int = 5) throws -> (URL, LibraryStore, [Paper], LookupProbe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = LookupProbe()
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"), metadataLookup: { try await probe.fetch($0) })
        var papers: [Paper] = []
        for n in 0..<count {
            var paper = Paper(); paper.title = "Local \(n)"; paper.doi = "10.1000/\(n)"
            try store.addPaperDurably(paper)
            papers.append(store.paper(with: paper.id)!)
        }
        return (root, store, papers, probe)
    }
    private static func testLookupFallback() async throws {
        var attempted: [String] = []
        var expected = PaperMetadata(); expected.title = "Matched exact arXiv ID"
        let sources = MetadataLookupClient.Sources(
            doi: { value in attempted.append("doi:\(value)"); throw PaperManagerError.message("Not indexed") },
            arxiv: { value in attempted.append("arxiv:\(value)"); return expected },
            isbn: { _ in throw Failure(description: "Unexpected ISBN request") },
            title: { _ in throw Failure(description: "Unexpected fuzzy title search") })
        let result = try await MetadataLookupClient.lookup(doi: "https://doi.org/10.1000/missing", arxivID: "2603.28480", isbn: nil, title: "Unrelated", sources: sources)
        try expect(result == expected && attempted == ["doi:10.1000/missing", "arxiv:2603.28480"], "Exact hint fallback did not run")
        attempted = []
        _ = try await MetadataLookupClient.lookup(doi: "https://doi.org/10.48550/arXiv.2603.28480", arxivID: nil, isbn: nil, title: nil, sources: sources)
        try expect(attempted == ["arxiv:2603.28480"], "arXiv DOI was incorrectly sent to Crossref")
        attempted = []
        do {
            _ = try await MetadataLookupClient.lookup(doi: "10.1000/missing", arxivID: nil, isbn: nil, title: "Unrelated", sources: sources)
            throw Failure(description: "Expected DOI failure")
        } catch is Failure { throw Failure(description: "Unsafe fuzzy fallback after exact ID failure") }
        catch { try expect(attempted == ["doi:10.1000/missing"], "Unexpected extra provider") }
    }
    private static func testLookupCancellation() async throws {
        var fallbackCalled = false
        let sources = MetadataLookupClient.Sources(doi: { _ in throw CancellationError() }, arxiv: { _ in fallbackCalled = true; return PaperMetadata() }, isbn: { _ in PaperMetadata() }, title: { _ in PaperMetadata() })
        do {
            _ = try await MetadataLookupClient.lookup(doi: "10.1000/example", arxivID: "2603.28480", isbn: nil, title: nil, sources: sources)
            throw Failure(description: "Cancelled lookup returned success")
        } catch is CancellationError { }
        try expect(!fallbackCalled, "Cancellation started another network provider")
    }
    private static func testArxivResponse() async throws {
        let valid = #"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/2603.28480v2</id><title>Matching paper</title><published>2026-03-28T00:00:00Z</published><author><name>Ada Author</name></author><summary>Abstract</summary></entry></feed>"#
        let metadata = try ArxivClient.parse(data: Data(valid.utf8), requestedID: "2603.28480")
        try expect(metadata.title == "Matching paper" && metadata.authors == ["Ada Author"] && metadata.doi == "10.48550/arXiv.2603.28480", "Valid arXiv Atom entry did not parse")
        let invalid = [
            valid.replacingOccurrences(of: "2603.28480v2", with: "2501.12345v1"),
            valid.replacingOccurrences(of: "http://arxiv.org/abs/2603.28480v2", with: "http://arxiv.org/api/errors#incorrect_id_format")
        ]
        for response in invalid {
            do {
                _ = try ArxivClient.parse(data: Data(response.utf8), requestedID: "2603.28480")
                throw Failure(description: "An unrelated or error entry was accepted as metadata")
            } catch is Failure { throw Failure(description: "An unrelated or error entry was accepted as metadata") }
            catch { }
        }
        try expect(MetadataLookupClient.normalizedArxivID("https://arxiv.org/pdf/2603.28480v2.pdf?download=1") == "2603.28480v2", "PDF URL did not normalize")
    }
    private static func testQueue() async throws {
        let (root, store, papers, probe) = try fixture(count: 7)
        defer { try? FileManager.default.removeItem(at: root) }
        store.isBusy = true
        store.enqueueMetadataRefresh(paperIDs: papers.prefix(4).map(\.id) + [papers[0].id])
        try await Task.sleep(nanoseconds: 10_000_000)
        store.enqueueMetadataRefresh(paperIDs: papers.map(\.id))
        await store.waitForMetadataRefresh()
        let peak = await probe.peak
        let calls = await probe.calls
        try expect(peak == 3, "Queue did not use its bounded concurrency: \(peak)")
        try expect(calls.count == 7 && calls.values.allSatisfy { $0 == 1 }, "Overlapping windows issued duplicate lookups")
        try expect(store.metadataRefreshProgress?.total == 7 && store.metadataRefreshProgress?.completed == 7 && store.metadataRefreshProgress?.updated == 7, "Incorrect queue progress")
        try expect(store.isBusy, "Refresh cleared another operation's busy state")
        try expect(!store.isMetadataRefreshing, "Queue remained running")
        let completed = store.metadataRefreshProgress
        try expect(!store.enqueueMetadataRefresh(paperIDs: [UUID()]) && !store.retryFailedMetadataRefresh(), "An empty or missing-paper request created work")
        try expect(store.metadataRefreshProgress == completed, "No-op enqueue erased completion or left a phantom running state")
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.papers.allSatisfy { $0.abstract == "Provider abstract" }, "Successful completion preceded persistence")
    }
    private static func testConcurrentChanges() async throws {
        let (root, store, papers, _) = try fixture(count: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        store.enqueueMetadataRefresh(paperIDs: papers.map(\.id))
        try await Task.sleep(nanoseconds: 10_000_000)
        var edited = store.paper(with: papers[0].id)!
        edited.abstract = "Typed while waiting"; edited.notes = "Local notes"; edited.rating = 4
        try store.updatePaperDurably(edited)
        store.deletePapers(ids: [papers[1].id])
        await store.waitForMetadataRefresh()
        let result = store.paper(with: edited.id)!
        try expect(result.title == edited.title && result.abstract == edited.abstract && result.notes == edited.notes && result.rating == 4 && result.journal == "Provider source", "Delayed refresh erased local content")
        try expect(store.paper(with: papers[1].id) == nil && store.metadataRefreshProgress?.skipped == 1, "Deleted paper was recreated")
    }
    private static func testCancellation() async throws {
        let (root, store, papers, probe) = try fixture(count: 7)
        defer { try? FileManager.default.removeItem(at: root) }
        store.enqueueMetadataRefresh(paperIDs: papers.map(\.id))
        try await Task.sleep(nanoseconds: 10_000_000)
        store.cancelMetadataRefresh()
        await store.waitForMetadataRefresh()
        let calls = await probe.calls
        try expect(store.metadataRefreshProgress?.cancelled == true && !store.isMetadataRefreshing, "Cancellation did not reach completion")
        try expect(calls.count <= 3 && store.papers.allSatisfy { $0.abstract.isEmpty }, "Cancelled work continued or committed")
        store.enqueueMetadataRefresh(paperIDs: [papers[0].id])
        await store.waitForMetadataRefresh()
        try expect(store.paper(with: papers[0].id)?.abstract == "Provider abstract", "Queue could not be restarted after cancellation")
    }
    private static func testChangedIdentity() async throws {
        let (root, store, papers, _) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        store.enqueueMetadataRefresh(paperIDs: [papers[0].id])
        try await Task.sleep(nanoseconds: 10_000_000)
        var edited = store.paper(with: papers[0].id)!
        edited.doi = "10.1000/a-different-work"
        try store.updatePaperDurably(edited)
        await store.waitForMetadataRefresh()
        try expect(store.paper(with: edited.id)?.abstract == "" && store.metadataRefreshProgress?.skipped == 1, "Metadata for an obsolete identifier was merged")
    }
    private static func testRetry() async throws {
        let (root, store, papers, probe) = try fixture(count: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setFailures([papers[0].id])
        store.enqueueMetadataRefresh(paperIDs: papers.map(\.id))
        await store.waitForMetadataRefresh()
        try expect(store.metadataRefreshProgress?.failed == 1 && store.metadataRefreshProgress?.updated == 1, "Provider failure was swallowed")
        await probe.setFailures([])
        try expect(store.retryFailedMetadataRefresh(), "Failed queue was not retryable")
        await store.waitForMetadataRefresh()
        let calls = await probe.calls
        try expect(store.metadataRefreshProgress?.total == 1 && store.metadataRefreshProgress?.updated == 1 && calls[papers[0].id] == 2 && calls[papers[1].id] == 1, "Retry repeated successful work")
    }
    private static func testWriteFailure() async throws {
        let (root, store, papers, _) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        store.enqueueMetadataRefresh(paperIDs: [papers[0].id])
        await store.waitForMetadataRefresh()
        try expect(store.metadataRefreshProgress?.failed == 1 && store.metadataRefreshProgress?.updated == 0, "Failed write was counted as updated")
        try expect(store.paper(with: papers[0].id)?.abstract == "", "Failed write left a false in-memory result")
    }
    private static func restoreFixture() throws -> (URL, LibraryStore, Paper, RestoreLookupGate) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataRestore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = RestoreLookupGate()
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"), metadataLookup: { await gate.fetch($0) })
        var paper = Paper(); paper.title = "Same identity across restore"; paper.doi = "10.1000/same"
        try store.addPaperDurably(paper)
        return (root, store, store.paper(with: paper.id)!, gate)
    }
    private static func testRestoreGeneration() async throws {
        let (root, store, paper, gate) = try restoreFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.enqueueMetadataRefresh(paperIDs: [paper.id])
        await gate.waitForStart()
        var restored = store.snapshot
        restored.papers[0].notes = "Restored notes"
        try store.replaceSnapshotDurably(restored)
        let restoredRevision = try store.snapshotRevisionToken()
        let restoredBytes = try Data(contentsOf: store.persistenceURL)
        store.statusMessage = "Restore completed"
        await gate.release()
        await store.waitForMetadataRefresh()
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        let finalRevision = try store.snapshotRevisionToken()
        let finalBytes = try Data(contentsOf: store.persistenceURL)
        try expect(finalRevision == restoredRevision && finalBytes == restoredBytes && reloaded.paper(with: paper.id)?.abstract == "", "An old request filled fields in the restored snapshot")
        try expect(store.metadataRefreshProgress?.cancelled == true && store.statusMessage == "Restore completed", "Obsolete queue completion overwrote restoration state")
        try expect(store.enqueueMetadataRefresh(paperIDs: [paper.id]), "The new library could not start its own refresh")
        await store.waitForMetadataRefresh()
        try expect(store.paper(with: paper.id)?.abstract == "Provider result from an earlier request", "A fresh request for the restored library could not commit")
    }
    private static func testFailedRestoreGeneration() async throws {
        let (root, store, paper, gate) = try restoreFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try Data(contentsOf: store.persistenceURL)
        store.enqueueMetadataRefresh(paperIDs: [paper.id])
        await gate.waitForStart()
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        var attempted = store.snapshot
        attempted.papers[0].notes = "Must not become visible"
        var failedAsExpected = false
        do { try store.replaceSnapshotDurably(attempted) }
        catch { failedAsExpected = true }
        try FileManager.default.removeItem(at: store.persistenceURL)
        try saved.write(to: store.persistenceURL)
        await gate.release()
        await store.waitForMetadataRefresh()
        try expect(failedAsExpected && store.metadataRefreshProgress?.cancelled == false && store.metadataRefreshProgress?.updated == 1, "A failed replacement cancelled the valid original queue")
        try expect(store.paper(with: paper.id)?.notes == "" && store.paper(with: paper.id)?.abstract == "Provider result from an earlier request", "A failed replacement changed the active library")
    }
    private static func testPreferredLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreferredLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "PaperManagerPreferredLibraryTests-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let defaultURL = LibraryStore.defaultPersistenceURL(environment: [:], preferences: preferences)
        let preferred = root.appendingPathComponent("preferred-library.json")
        try Data("{}".utf8).write(to: preferred)
        preferences.set(preferred.path, forKey: LibraryStore.preferredLibraryPathKey)
        try expect(LibraryStore.defaultPersistenceURL(environment: [:], preferences: preferences).standardizedFileURL == preferred.standardizedFileURL, "Dock launch ignored the valid preferred library")
        let explicit = root.appendingPathComponent("explicit-library.json")
        try expect(LibraryStore.defaultPersistenceURL(environment: ["PAPERMANAGER_LIBRARY_PATH": explicit.path], preferences: preferences) == explicit, "Preference overrode the explicit environment")
        for invalid in ["relative/library.json", root.appendingPathComponent("missing.json").path, root.path] {
            preferences.set(invalid, forKey: LibraryStore.preferredLibraryPathKey)
            try expect(LibraryStore.defaultPersistenceURL(environment: [:], preferences: preferences) == defaultURL, "Invalid preferred path was accepted: \(invalid)")
        }
        try expect(FileManager.default.fileExists(atPath: preferred.path), "Checking preferences changed library bytes")
        let preserved = try Data(contentsOf: preferred)
        try expect(preserved == Data("{}".utf8), "Checking preferences changed library content")
    }
}
