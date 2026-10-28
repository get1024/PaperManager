import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct AddPaperSheetsSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { _exit(3) }
        Task { @MainActor in await run() }
        app.run()
    }

    private static func run() async {
        var failures: [String] = []
        var sizes: [String: [Double]] = [:]
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"] else { _exit(2) }
        let store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        try! store.replaceSnapshotDurably(.empty)
        let before = try! Data(contentsOf: store.persistenceURL)
        var windows: [NSWindow] = []
        func measure<V: View>(_ view: V, name: String, width: CGFloat = 450, height: CGFloat) {
            let host = NSHostingController(rootView: view.environmentObject(store))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: -1000)
            window.orderBack(nil)
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.view.layoutSubtreeIfNeeded()
            let size = host.view.fittingSize
            sizes[name] = [Double(size.width), Double(size.height)]
            if abs(size.width - width) > 1 || abs(size.height - height) > 1 {
                failures.append("\(name) size \(size) did not match \(width)×\(height)")
            }
            if let report = ProcessInfo.processInfo.environment["PAPERMANAGER_ADD_SHEETS_REPORT"],
               let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("\(name).png"))
            }
            windows.append(window)
        }
        measure(ManualPaperSheet(targetFilter: nil), name: "manual", height: 318)
        let lookup = IdentifierLookupSession { query in
            var paper = Paper(); paper.title = "Lookup \(query)"
            paper.authors = ["Synthetic Author", "Second Author", "Third Author"]
            paper.journal = "Synthetic Journal"; paper.year = 2026
            return paper
        }
        measure(DOISheet(targetFilter: nil, lookupSession: lookup), name: "lookup", height: 148)
        lookup.query = "10.5555/synthetic"
        lookup.lookup()
        try? await Task.sleep(nanoseconds: 100_000_000)
        if lookup.paper?.title != "Lookup 10.5555/synthetic" || lookup.isLoading { failures.append("Lookup did not finish in a result stage") }
        measure(DOISheet(targetFilter: nil, lookupSession: lookup), name: "lookupResult", height: 228)
        if store.papers.count != 0 || (try? Data(contentsOf: store.persistenceURL)) != before { failures.append("Lookup changed the library before explicit Import") }

        let late = IdentifierLookupSession { query in
            // Ignore cancellation like a provider that already received a response.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + (query == "old" ? 0.12 : 0.01)) {
                    var paper = Paper(); paper.title = query
                    continuation.resume(returning: paper)
                }
            }
        }
        late.query = "old"; late.lookup()
        try? await Task.sleep(nanoseconds: 10_000_000)
        late.query = "new"; late.lookup()
        try? await Task.sleep(nanoseconds: 200_000_000)
        if late.paper?.title != "new" { failures.append("A late old query replaced the new preview") }
        late.query = "dismissed"; late.lookup(); late.cancel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        if late.paper != nil || late.isLoading { failures.append("Dismissal accepted a cancelled result") }
        var first = Paper(); first.title = "Attention Is All You Need"; first.authors = ["Vaswani, Ashish", "Shazeer, Noam"]
        var second = Paper(); second.title = "Deep learning"; second.authors = ["LeCun, Yann", "Bengio, Yoshua", "Hinton, Geoffrey"]
        var plan = ImportService.prepare(papers: [first, second], store: store)
        measure(ImportPreviewView(plan: plan, targetFilter: nil, sourceKind: "BibTeX"), name: "importPreview", width: 500, height: 400)
        plan = ImportService.prepare(papers: [first, first], store: store)
        if plan.candidates[1].batchDuplicateID != plan.candidates[0].id {
            failures.append("Same-import duplicate options were missing from the rendered preview plan")
        }
        measure(ImportPreviewView(plan: plan, targetFilter: nil, sourceKind: "BibTeX"), name: "batchDuplicatePreview", width: 500, height: 400)
        _ = try! store.addPaperDurably(first)
        plan = ImportService.prepare(papers: [first, second], store: store)
        measure(ImportPreviewView(plan: plan, targetFilter: nil, sourceKind: "BibTeX"), name: "duplicatePreview", width: 500, height: 400)
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_ADD_SHEETS_REPORT"] {
            let report: [String: Any] = ["ok": failures.isEmpty, "failures": failures, "sizes": sizes]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        failures.forEach { print("FAIL: \($0)") }
        print("Add paper sheets: \(failures.isEmpty ? "6 layouts + lookup lifecycle passed" : "\(failures.count) failures")")
        windows.forEach { $0.close() }
        exit(failures.isEmpty ? 0 : 1)
    }
}
