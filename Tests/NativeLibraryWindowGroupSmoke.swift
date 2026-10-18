import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct NativeLibraryWindowGroupSmoke: App {
    @NSApplicationDelegateAdaptor(WindowGroupSmokeDelegate.self) private var delegate
    @StateObject private var fixture = WindowGroupSmokeState()

    var body: some Scene {
        WindowGroup {
            fixture.libraryView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowChromeConfigurator { window in
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.styleMask.insert(.fullSizeContentView)
                    window.isMovableByWindowBackground = true
                    window.contentMinSize = NSSize(width: 1080, height: 680)
                })
                .navigationTitle("Owned WindowGroup fixture")
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .navigation) { Label("Panels", systemImage: "rectangle.split.3x1") }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Label("Add", systemImage: "plus")
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { fixture.start() }
        }
        .defaultSize(width: 1420, height: 860)
    }
}

@MainActor
final class WindowGroupSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("WindowGroup fixture exceeded 20 seconds\n", stderr)
            _exit(3)
        }
    }
}

@MainActor
final class WindowGroupSmokeState: ObservableObject {
    let store: LibraryStore
    @Published var filter: LibraryFilter = .all
    @Published var selection: Set<UUID> = []
    @Published var search = ""
    @Published var includeSubcollections = true
    @Published var sort = PaperSortDescriptor.defaultValue
    @Published var showSidebar = true
    @Published var showInspector = true
    private var started = false
    private var splitIdentity: ObjectIdentifier?
    private var stages: [[String: Any]] = []
    private var failures: [String] = []

    init() {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"], path.hasPrefix("/") else {
            fatalError("The fixture requires an explicit owned library path")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        var snapshot = LibrarySnapshot.empty
        snapshot.papers = (0..<72).map { index in
            var paper = Paper(); paper.title = "WindowGroup fixture \(index)"
            paper.authors = ["Synthetic Author"]; paper.year = 2026; paper.rating = 2
            return paper
        }
        try! store.replaceSnapshotDurably(snapshot)
    }

    var libraryView: some View {
        NativeLibraryView(store: store, papers: store.snapshot.papers,
            selectedFilter: Binding(get: { self.filter }, set: { self.filter = $0 }),
            selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
            searchText: Binding(get: { self.search }, set: { self.search = $0 }),
            includeSubcollections: Binding(get: { self.includeSubcollections }, set: { self.includeSubcollections = $0 }),
            sortDescriptor: Binding(get: { self.sort }, set: { self.sort = $0 }),
            showSidebar: showSidebar, showInspector: showInspector, focusSearchToken: 0,
            onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
            onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {})
    }

    func start() {
        guard !started else { return }; started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.runStep(0) }
    }

    private func runStep(_ index: Int) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width >= 1000 }) else {
            failures.append("No fixture WindowGroup window"); finish(); return
        }
        window.level = NSWindow.Level(rawValue: -1000)
        window.orderBack(nil)
        switch index {
        case 0: window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1420, height: 860)), display: false)
        case 1: window.setContentSize(NSSize(width: 1080, height: 680))
        case 2: window.setContentSize(NSSize(width: 1760, height: 1000))
        case 3: showSidebar = false
        case 4: showSidebar = true; showInspector = false
        case 5: showSidebar = false
        case 6: showSidebar = true; showInspector = true
        case 7: selection = [store.snapshot.papers[0].id]
        case 8: selection = []
        default: finish(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.capture(window, step: index)
            self.runStep(index + 1)
        }
    }

    private func capture(_ window: NSWindow, step: Int) {
        guard let content = window.contentView,
              let split = descendants(content).compactMap({ $0 as? NSSplitView }).first else {
            failures.append("Step \(step): no native split"); return
        }
        let active = split.arrangedSubviews.filter { !split.isSubviewCollapsed($0) }
        if let splitIdentity, splitIdentity != ObjectIdentifier(split) {
            failures.append("Step \(step): the native split was replaced")
        }
        splitIdentity = ObjectIdentifier(split)
        let expectedCount = 1 + (showSidebar ? 1 : 0) + (showInspector ? 1 : 0)
        let expectedHeight = window.contentLayoutRect.height
        if abs(split.bounds.height - expectedHeight) > 1 {
            failures.append("Step \(step): split \(split.bounds.height) != content \(expectedHeight)")
        }
        if active.count != expectedCount { failures.append("Step \(step): wrong visible pane count \(active.count)") }
        if active.contains(where: { abs($0.frame.height - split.bounds.height) > 1 }) {
            failures.append("Step \(step): pane heights \(active.map { $0.frame.height }) != split \(split.bounds.height)")
        }
        stages.append(["step": step, "window": rect(window.frame), "contentLayout": rect(window.contentLayoutRect),
                       "split": rect(split.frame), "bounds": rect(split.bounds), "paneFrames": active.map { rect($0.frame) },
                       "selectionCount": selection.count, "showSidebar": showSidebar, "showInspector": showInspector])
    }

    private func finish() {
        let payload: [String: Any] = ["ok": failures.isEmpty, "failures": failures, "stages": stages,
                                    "pid": ProcessInfo.processInfo.processIdentifier,
                                    "timestamp": Date().timeIntervalSince1970]
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_WINDOW_GROUP_REPORT"] {
            try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("WindowGroup fixture: \(stages.count) stages, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }

    private func rect(_ value: NSRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
