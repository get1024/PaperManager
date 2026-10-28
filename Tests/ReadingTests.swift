import AppKit
import PDFKit

@main @MainActor
struct ReadingTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }; checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMReading-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var p = Paper(); p.title = "Reading fixture"
        store.addPaper(p)
        let oldData = try JSONEncoder().encode(p)
        check(try JSONDecoder().decode(Paper.self, from: oldData).reading == nil, "Old records must load without reading state")
        let session = store.readingSession
        check(session.start(p.id, now: 100), "Start")
        session.tick(now: 105)
        check(store.paper(with: p.id)?.reading?.seconds == 5, "Five real seconds")
        try store.updateReading(p.id) { $0.setProgress(0.5) }
        session.tick(now: 110)
        check(store.paper(with: p.id)?.reading?.progress == 0.5, "Timer must preserve progress")
        check(session.pause(now: 112), "Pause")
        check(store.paper(with: p.id)?.reading?.seconds == 12, "Pause must flush partial tick")
        session.tick(now: 117)
        check(store.paper(with: p.id)?.reading?.seconds == 12, "Paused time must not accumulate")
        check(session.start(p.id, now: 200), "Resume")
        session.tick(now: 400)
        check(session.activePaperID == nil && store.paper(with: p.id)?.reading?.seconds == 12, "Sleep gap excluded")
        let draft = PaperDraftSession(autosaveDelayNanoseconds: 60_000_000_000)
        draft.select(p.id, in: store)
        var edited = draft.draft; edited.notes = "Pending draft"; draft.edit(edited)
        try store.updateReading(p.id) { $0.add(seconds: 8) }
        check(draft.flush(), "Draft saved")
        check(store.paper(with: p.id)?.reading?.seconds == 20, "Stale draft must preserve timer")
        let reload = LibraryStore(persistenceURL: store.persistenceURL)
        check(reload.paper(with: p.id)?.reading?.seconds == 20 && reload.paper(with: p.id)?.notes == "Pending draft", "Disk round trip")
        var second = Paper(); second.title = "Second"; store.addPaper(second)
        check(session.start(p.id, now: 500), "First session")
        check(session.start(second.id, now: 503), "Switch session")
        check(store.paper(with: p.id)?.reading?.seconds == 23, "Previous paper flushed")
        session.pause(now: 507)
        check(store.paper(with: second.id)?.reading?.seconds == 4, "Time belongs to second paper")
        check(session.start(p.id, now: 600), "Failure fixture start")
        let original = try Data(contentsOf: store.persistenceURL)
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        session.tick(now: 605)
        check(session.errorMessage != nil && session.activePaperID == nil, "Write failure pauses timer")
        check(store.paper(with: p.id)?.reading?.seconds == 23, "Failed write does not publish")
        try FileManager.default.removeItem(at: store.persistenceURL)
        try original.write(to: store.persistenceURL)
        check(session.pause(now: 606), "Retry pending seconds")
        check(store.paper(with: p.id)?.reading?.seconds == 28, "Retry saves delta once")
        session.pause(now: 610)
        check(store.paper(with: p.id)?.reading?.seconds == 28, "Retry must not double count")
        var record = ReadingRecord(); record.setProgress(9)
        check(record.progress == 1, "Progress clamped")
        record.setProgress(-1); record.add(seconds: -5)
        check(record.progress == 0 && record.seconds == 0, "Negative inputs rejected")
        record.add(seconds: 3661)
        check(record.durationText == "01:01:01", "Duration format")
        let document = PDFDocument()
        for i in 0..<3 {
            let image = NSImage(size: NSSize(width: 400, height: 600), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("Page \(i + 1)" as NSString).draw(at: NSPoint(x: 30, y: 500), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
                return true
            }
            document.insert(PDFPage(image: image)!, at: i)
        }
        let url = root.appendingPathComponent("fixture.pdf"); document.write(to: url)
        let attachment = Attachment(kind: .pdf, filePath: url.path, displayName: "fixture.pdf")
        let first = try PDFPreviewService.render(attachment, pageIndex: 0)
        let last = try PDFPreviewService.render(attachment, pageIndex: 99)
        check(first.pageIndex == 0 && first.pageCount == 3, "First page loaded")
        check(last.pageIndex == 2 && last.image.size.width <= 320, "Last page clamped and thumbnail bounded")
        check(try PDFPreviewService.render(attachment, pageIndex: -1).pageIndex == 0, "Negative page clamped")
        check(store.paper(with: p.id)?.reading?.progress == 0.5, "Preview does not change reading progress")
        do {
            _ = try PDFPreviewService.render(Attachment(kind: .pdf, filePath: root.appendingPathComponent("missing.pdf").path, displayName: "missing"), pageIndex: 0)
            fatalError("Missing PDF must fail")
        } catch { checks += 1 }
        check(session.start(second.id, now: 700), "Deleted session start")
        check(store.deletePapers(ids: [second.id]), "Delete timed record")
        session.tick(now: 705)
        check(store.paper(with: second.id) == nil && session.activePaperID == nil, "Timer cannot resurrect deleted paper")
        print("Reading and preview: \(checks) passed, 0 failed")
    }
}
