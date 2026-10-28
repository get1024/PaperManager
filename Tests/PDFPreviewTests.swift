import AppKit
import PDFKit

@main @MainActor
struct PDFPreviewTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }; checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A library saved by 1.1.0 must still load after removing the feature.
        var paper = Paper(); paper.title = "Legacy library fixture"; paper.authors = ["Test Author"]
        var snapshot = LibrarySnapshot.empty; snapshot.papers = [paper]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
        var papers = json["papers"] as! [[String: Any]]
        papers[0]["reading"] = ["seconds": 45, "progress": 0.5, "lastReadAt": "2026-10-28T01:00:00Z"]
        json["papers"] = papers
        let libraryURL = root.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: json).write(to: libraryURL)
        let store = LibraryStore(persistenceURL: libraryURL)
        check(store.loadError == nil && store.snapshot.papers.count == 1, "Legacy library must load")
        var saved = store.paper(with: paper.id)!
        check(saved.title == paper.title && saved.authors == paper.authors, "Metadata must survive")
        saved.notes = "An ordinary metadata edit"
        try store.updatePaperDurably(saved)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: libraryURL)) as! [String: Any]
        let persistedPapers = persisted["papers"] as! [[String: Any]]
        check(persistedPapers[0]["reading"] == nil, "Removed statistics must no longer be written")
        check(LibraryStore(persistenceURL: libraryURL).paper(with: paper.id)?.notes == saved.notes, "Editing and saving still work")
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
        do {
            _ = try PDFPreviewService.render(Attachment(kind: .pdf, filePath: root.appendingPathComponent("missing.pdf").path, displayName: "missing"), pageIndex: 0)
            fatalError("Missing PDF must fail")
        } catch { checks += 1 }
        print("PDF preview: \(checks) passed, 0 failed")
    }
}
