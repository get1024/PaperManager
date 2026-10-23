import AppKit
import Darwin
import Foundation

@main
@MainActor
struct PaperReaderAnnotationTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Gate {
        var continuation: CheckedContinuation<[ResearchAnnotation], Error>?
        func extract(_ attachment: Attachment, _ id: UUID) async throws -> [ResearchAnnotation] {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func waitUntilStarted() async throws {
            for _ in 0..<100 {
                if continuation != nil { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw Failure(description: "The real refresh helper did not reach its suspended extractor")
        }
        func release(_ annotations: [ResearchAnnotation]) {
            continuation?.resume(returning: annotations); continuation = nil
        }
    }
    private struct Fixture {
        let root: URL
        let store: LibraryStore
        let paper: Paper
        let attachment: Attachment
    }
    private static var passed = 0
    private static var failures: [String] = []
    private static let extracted = [ResearchAnnotation(page: 2, selectedText: "New extracted annotation")]

    static func main() async {
        await run("Late extraction cannot follow a replaced primary PDF", testReplacedPDF)
        await run("Late extraction cannot replace a manual annotation edit", testManualEdit)
        await run("Committed snapshot restore invalidates the old extraction generation", testRestore)
        await run("A failed JSON write keeps original annotations in memory and on disk", testWriteFailure)
        await run("A current extraction commits durably while preserving concurrent metadata", testSuccess)
        failures.forEach { print("FAIL: \($0)") }
        print("Paper reader annotations: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ test: () async throws -> Void) async {
        do { try await test(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    private static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperReaderAnnotations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let url = root.appendingPathComponent("original.pdf")
        var media = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let attachment = Attachment(kind: .pdf, filePath: url.path, displayName: "original.pdf")
        var paper = Paper(); paper.title = "Owned annotation fixture"; paper.attachments = [attachment]
        paper.annotations = [ResearchAnnotation(selectedText: "Original annotation")]
        var snapshot = LibrarySnapshot.empty; snapshot.papers = [paper]
        try store.replaceSnapshotDurably(snapshot)
        return Fixture(root: root, store: store, paper: paper, attachment: attachment)
    }
    private static func begin(_ fixture: Fixture, gate: Gate) -> Task<Bool, Never> {
        Task { await PaperReaderActions.refreshAnnotationsAfterOpening(fixture.paper.id, attachment: fixture.attachment,
                                                                      store: fixture.store, extractor: gate.extract) }
    }

    private static func testReplacedPDF() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(); let task = begin(f, gate: gate); try await gate.waitUntilStarted()
        var current = f.store.paper(with: f.paper.id)!
        let replacement = Attachment(kind: .pdf, filePath: f.root.appendingPathComponent("replacement.pdf").path, displayName: "replacement.pdf")
        current.attachments = [replacement]; try f.store.updatePaperDurably(current)
        let committed = try Data(contentsOf: f.store.persistenceURL)
        gate.release(extracted)
        let result = await task.value
        try expect(!result && f.store.paper(with: f.paper.id)?.annotations == f.paper.annotations, "Stale PDF result overwrote annotations")
        try expect(f.store.paper(with: f.paper.id)?.primaryPDF == replacement, "Stale extraction undid PDF replacement")
        try expect((try? Data(contentsOf: f.store.persistenceURL)) == committed, "Stale extraction changed the replaced-PDF JSON")
    }
    private static func testManualEdit() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(); let task = begin(f, gate: gate); try await gate.waitUntilStarted()
        let manual = [ResearchAnnotation(selectedText: "Manually corrected annotation", note: "Keep this edit")]
        var current = f.store.paper(with: f.paper.id)!; current.annotations = manual
        try f.store.updatePaperDurably(current)
        gate.release(extracted)
        let result = await task.value
        try expect(!result && f.store.paper(with: f.paper.id)?.annotations == manual, "Late extraction replaced a manual annotation edit")
        try expect(LibraryStore(persistenceURL: f.store.persistenceURL).paper(with: f.paper.id)?.annotations == manual, "Manual annotation was not preserved durably")
    }
    private static func testRestore() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(); let task = begin(f, gate: gate); try await gate.waitUntilStarted()
        let token = f.store.libraryIdentityToken
        var restored = f.store.snapshot
        restored.papers[0].title = "Restored same-ID paper"
        try f.store.replaceSnapshotDurably(restored)
        try expect(f.store.libraryIdentityToken != token, "Successful restore did not advance library identity")
        let committed = try Data(contentsOf: f.store.persistenceURL)
        gate.release(extracted)
        let result = await task.value
        try expect(!result && f.store.paper(with: f.paper.id)?.annotations == f.paper.annotations, "Old extraction crossed a successful same-ID restore")
        try expect((try? Data(contentsOf: f.store.persistenceURL)) == committed, "Old extraction changed the restored JSON")
    }
    private static func testWriteFailure() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(); let task = begin(f, gate: gate); try await gate.waitUntilStarted()
        let saved = f.store.persistenceURL.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: f.store.persistenceURL, to: saved)
        try FileManager.default.createDirectory(at: f.store.persistenceURL, withIntermediateDirectories: false)
        gate.release(extracted)
        let result = await task.value
        try expect(!result && f.store.paper(with: f.paper.id)?.annotations == f.paper.annotations, "Failed write changed annotations in memory")
        try expect(f.store.statusMessage?.contains("标注提取失败") == true, "Failed write reported annotation success")
        try FileManager.default.removeItem(at: f.store.persistenceURL)
        try FileManager.default.moveItem(at: saved, to: f.store.persistenceURL)
        try expect(LibraryStore(persistenceURL: f.store.persistenceURL).paper(with: f.paper.id)?.annotations == f.paper.annotations, "Failed write corrupted the last committed annotations")
    }
    private static func testSuccess() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = Gate(); let task = begin(f, gate: gate); try await gate.waitUntilStarted()
        var current = f.store.paper(with: f.paper.id)!; current.title = "Concurrent title edit"; current.rating = 4
        try f.store.updatePaperDurably(current)
        gate.release(extracted)
        let result = await task.value
        let reloaded = LibraryStore(persistenceURL: f.store.persistenceURL).paper(with: f.paper.id)
        try expect(result && reloaded?.annotations == extracted, "Current extraction was not durably committed")
        try expect(reloaded?.title == current.title && reloaded?.rating == 4, "Annotation commit lost concurrent metadata")
    }
}
