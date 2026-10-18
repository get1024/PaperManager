import AppKit
import Darwin
import Foundation
import SwiftUI

/// Runs in a separate native process. A SwiftUI/AppKit AX recursion therefore
/// fails this regression rather than crashing the user's running library.
@main
@MainActor
struct InspectorAccessibilitySmoke {
    private final class State {
        var selection: Set<UUID> = []
        var filter: LibraryFilter = .all
        var search = ""
        var includeSubcollections = true
        var sort = PaperSortDescriptor()
    }
    static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let mode = CommandLine.arguments.dropFirst().first ?? "nested"
        let root = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerInspectorAX-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var paper = Paper(); paper.title = "Attention Is All You Need — synthetic AX fixture"
        paper.authors = ["Vaswani, Ashish", "Synthetic Coauthor"]
        paper.year = 2017; paper.citekey = "vaswani2017"; paper.paperType = .inProceedings
        paper.bookTitle = "Synthetic Conference"; paper.doi = "10.5555/inspector-ax-fixture"
        paper.abstract = "This text belongs only to the regression fixture."
        paper.notes = "The regression must expose editable text and native accessibility children."
        var snapshot = LibrarySnapshot(); snapshot.papers = [paper]
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_SOURCE_LIBRARY"] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let source = snapshot.papers.first(where: { $0.citekey == "vaswani2017" }) else { fatalError("Fixture source item absent") }
            paper = source
            // Preserve the exact metadata/control structure while keeping every
            // file lookup inside this disposable fixture, with no source PDFs.
            for index in paper.attachments.indices {
                let fixture = root.appendingPathComponent("attachment-\(index).pdf")
                var media = CGRect(x: 0, y: 0, width: 100, height: 100)
                let context = CGContext(fixture as CFURL, mediaBox: &media, nil)!
                context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
                paper.attachments[index].filePath = fixture.path
                paper.attachments[index].bookmarkData = nil
            }
            for index in paper.annotations.indices { paper.annotations[index].imageFilePath = nil }
            snapshot.papers = [paper]
            print("AX SOURCE metadata attachments=\(paper.attachments.count) annotations=\(paper.annotations.count) customFields=\(paper.customFields.count) collections=\(snapshot.collections.count) tags=\(snapshot.tags.count)")
        }
        if let raw = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_ROWS"], let count = Int(raw), count > 1 {
            snapshot.papers = (0..<count).map { index in
                var item = Paper(); item.title = "AX Perf Title \(index)"
                item.authors = ["AX Perf Author \(index)", "Shared Author"]; item.year = 2026
                item.journal = "AX Perf Source \(index)"; item.rating = index % 5 + 1
                item.notes = "AX Perf Note \(index)"; item.citekey = "perf\(index)"
                item.dateAdded = Date(timeIntervalSince1970: 1_000 + Double(index))
                return item
            }
            paper = snapshot.papers[0]
        }
        try store.replaceSnapshotDurably(snapshot)
        let state = State()
        func nativeConfiguration() -> NativeLibraryView {
            NativeLibraryView(store: store, papers: store.papers,
                selectedFilter: Binding(get: { state.filter }, set: { state.filter = $0 }),
                selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                searchText: Binding(get: { state.search }, set: { state.search = $0 }),
                includeSubcollections: Binding(get: { state.includeSubcollections }, set: { state.includeSubcollections = $0 }),
                sortDescriptor: Binding(get: { state.sort }, set: { state.sort = $0 }),
                showSidebar: true, showInspector: true, focusSearchToken: 0,
                onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
                onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {})
        }
        func hostedConfiguration() -> AnyView {
            if let raw = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_TABLE_HEIGHT"], let height = Double(raw) {
                return AnyView(nativeConfiguration().frame(height: height).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
            }
            return AnyView(nativeConfiguration())
        }
        let content: AnyView
        if mode == "simple" {
            content = AnyView(Text("Simple native hosting fixture").accessibilityIdentifier("simple-host-root"))
        } else if mode == "nested" {
            content = AnyView(PaperDetailView(selection: .constant([paper.id])).environmentObject(store)
                .accessibilityIdentifier("inspector-root"))
        } else {
            content = AnyView(PaperDetailView(selection: .constant([paper.id])).environmentObject(store))
        }
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        if mode == "nested" { hosting.view.setAccessibilityIdentifier("inspector-root") }
        hosting.rootView = content
        let native = NativeLibraryController()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: mode.hasPrefix("native") ? 1420 : 380, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PaperManager Inspector AX Regression"
        window.level = NSWindow.Level(rawValue: -1000)
        window.isReleasedWhenClosed = false
        if mode == "native" {
            window.contentViewController = native
            native.configure(nativeConfiguration())
        } else if mode == "nativeHosted" {
            hosting.rootView = hostedConfiguration()
            window.contentViewController = hosting
        } else { window.contentViewController = hosting }
        // Assigning NSHostingController can replace the initial window size
        // with its empty preferred content size. This isolated AppKit host
        // must supply an explicit viewport rather than benchmark a zero root.
        window.setContentSize(NSSize(width: mode.hasPrefix("native") ? 1420 : 380, height: 900))
        window.orderBack(nil)
        defer { window.close() }
        let until = Date().addingTimeInterval(0.5)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        hosting.view.layoutSubtreeIfNeeded()
#if NATIVE_AX_PERF
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for table in descendants(hosting.view).compactMap({ $0 as? NSOutlineView }) where table.accessibilityIdentifier() == "paper-table" {
            print("AX PERF GEOMETRY window=\(window.contentLayoutRect) host=\(hosting.view.bounds) rows=\(table.numberOfRows) table=\(table.frame) scroll=\(table.enclosingScrollView?.frame ?? .zero) clip=\(table.enclosingScrollView?.contentView.bounds ?? .zero) visibleHeight=\(table.visibleRect.height) visibleRows=\(table.rows(in: table.visibleRect).length) rowHeight=\(table.rowHeight)")
        }
        let telemetry = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PERF_FINISH"], FileManager.default.fileExists(atPath: path) {
                print("AX PERF CELLS initializations=\(nativeAXPerfTextCellInitializations) configurations=\(nativeAXPerfTextCellConfigurations) changes=\(nativeAXPerfTextCellChanges)")
                for table in descendants(hosting.view).compactMap({ $0 as? NSOutlineView }) where table.accessibilityIdentifier() == "paper-table" {
                    print("AX PERF END GEOMETRY table=\(table.frame) scroll=\(table.enclosingScrollView?.frame ?? .zero) clip=\(table.enclosingScrollView?.contentView.bounds ?? .zero) visible=\(table.visibleRect)")
                }
                timer.invalidate()
            }
        }
#endif
        func selectPaper() {
            state.selection = [paper.id]
            if mode == "native" { native.configure(nativeConfiguration()); native.view.layoutSubtreeIfNeeded() }
            else { hosting.rootView = hostedConfiguration(); hosting.view.layoutSubtreeIfNeeded() }
            print("AX SERVER SELECTED")
        }
        if mode.hasPrefix("native"), ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] == nil,
           ProcessInfo.processInfo.environment["PAPERMANAGER_AX_NO_SELECTION"] != "1" {
            selectPaper()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        if ProcessInfo.processInfo.environment["PAPERMANAGER_AX_SERVE"] == "1" {
            var phaseTimer: Timer?
            if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] {
                phaseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                    if FileManager.default.fileExists(atPath: path) {
                        MainActor.assumeIsolated { selectPaper() }
                        timer.invalidate()
                    }
                }
            }
            print("AX SERVER READY \(ProcessInfo.processInfo.processIdentifier)")
            let timeout = Double(ProcessInfo.processInfo.environment["PAPERMANAGER_AX_SERVER_TIMEOUT"] ?? "30") ?? 30
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { exit(0) }
            NSApplication.shared.run()
            phaseTimer?.invalidate()
#if NATIVE_AX_PERF
            telemetry.invalidate()
#endif
            return
        }
        var queue: [NSObject] = [hosting.view]
        var seen: Set<ObjectIdentifier> = []
        var reads = 0
        let attributes = ["accessibilityRole", "accessibilityRoleDescription", "accessibilityIdentifier", "accessibilityTitle",
                          "accessibilityLabel", "accessibilityValue", "accessibilityHelp"]
        while !queue.isEmpty && seen.count < 4_000 {
            let object = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            print("AX NODE \(seen.count): \(String(describing: type(of: object)))")
            for name in attributes {
                print("AX READ \(name)")
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector) {
                    _ = object.perform(selector)?.takeUnretainedValue()
                    reads += 1
                }
            }
            for name in ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                    queue.append(contentsOf: children)
                }
            }
        }
        print("Inspector local AX diagnostic only: mode=\(mode), nodes=\(seen.count), attributeReads=\(reads). Use the external two-phase runner for regression coverage.")
    }
}
