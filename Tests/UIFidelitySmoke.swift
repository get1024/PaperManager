import AppKit
import CryptoKit
import Darwin
import SwiftUI

/// Controlled rendering of the shipping native library and inspector views.
/// These PNGs are cacheDisplay renders, not captures of the installed app.
@main
@MainActor
struct UIFidelitySmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class SceneState: ObservableObject {
        @Published var selection: Set<UUID>
        @Published var filter: LibraryFilter = .all
        @Published var search = ""
        @Published var includeSubcollections = true
        @Published var sort = PaperSortDescriptor(field: .year, ascending: true)
        @Published var sidebar = true
        @Published var inspector = true
        init(selected: UUID) { selection = [selected] }
    }

    private struct FixtureRoot: View {
        @ObservedObject var store: LibraryStore
        @ObservedObject var state: SceneState

        var body: some View {
            NativeLibraryView(store: store,
                papers: store.filteredPapers(for: state.filter, searchText: state.search,
                    includeSubcollections: state.includeSubcollections, sortDescriptor: state.sort),
                selectedFilter: $state.filter, selection: $state.selection, searchText: $state.search,
                includeSubcollections: $state.includeSubcollections, sortDescriptor: $state.sort,
                showSidebar: state.sidebar, showInspector: state.inspector, focusSearchToken: 0,
                onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
                onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {},
                onToggleSidebar: { state.sidebar.toggle() },
                onPanelVisibilityChanged: { state.sidebar = $0; state.inspector = $1 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .font(PMTypography.bodyRegular)
                .background(WindowChromeConfigurator { window in
                    window.titleVisibility = .visible
                    window.titlebarAppearsTransparent = true
                    window.toolbarStyle = .unified
                    window.styleMask.insert(.fullSizeContentView)
                    window.isMovableByWindowBackground = false
                    window.contentMinSize = NSSize(width: 1080, height: 680)
                })
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, PMLocalization.locale(for: "zh-Hans"))
                .navigationTitle("全部文献")
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // The host recreates only the three outer toolbar actions.
                    // Library/sidebar/table/inspector implementations are shipping views.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {} label: { Label("添加", systemImage: "plus") }.labelStyle(.iconOnly)
                        Button {} label: { Label("导出", systemImage: "square.and.arrow.up") }.labelStyle(.iconOnly)
                        Button { state.inspector.toggle() } label: {
                            Label("切换检查器", systemImage: "sidebar.right")
                        }.labelStyle(.iconOnly)
                    }
                }
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func rect(_ value: NSRect) -> [String: Double] {
        ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func settle(_ view: NSView, seconds: TimeInterval = 0.65) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        view.layoutSubtreeIfNeeded()
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        do { try run(); exit(0) }
        catch { print("FAIL: UI fidelity fixture: \(error)"); exit(1) }
    }

    private static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["PAPERMANAGER_UI_FIDELITY_SOURCE"], sourcePath.hasPrefix("/"),
              let outputPath = environment["PAPERMANAGER_UI_FIDELITY_OUTPUT"], outputPath.hasPrefix("/") else {
            throw Failure(description: "Set absolute PAPERMANAGER_UI_FIDELITY_SOURCE and PAPERMANAGER_UI_FIDELITY_OUTPUT paths")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let sourceHash = sha256(sourceBytes)
        let libraryCopy = outputURL.appendingPathComponent("isolated-library.json")
        guard libraryCopy != sourceURL else { throw Failure(description: "The source and fixture library must differ") }
        try sourceBytes.write(to: libraryCopy, options: .atomic)

        let preferenceKeys = ["PaperManager.NativePaperColumnLayout.v2", "PaperManager.NativePaperColumnLayout.v3",
            "PaperManager.NativePaperColumnLayout.beforeLatticeFidelity", "PaperManager.NativeLibraryPaneWidths"]
        let previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        for key in preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(["sidebar": 240, "inspector": 320], forKey: "PaperManager.NativeLibraryPaneWidths")
        defer {
            for key in preferenceKeys {
                if let old = previousPreferences[key] { UserDefaults.standard.set(old, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        let store = LibraryStore(persistenceURL: libraryCopy)
        guard store.loadError == nil else { throw Failure(description: "The isolated real-library copy failed to load") }
        var settings = store.settings
        settings.appearance = .dark
        settings.languageIdentifier = "zh-Hans"
        settings.tableDensity = .compact
        guard store.updateSettings(settings) else { throw Failure(description: "Fixture settings could not be written to the copy") }
        guard let attention = store.papers.first(where: { $0.title.caseInsensitiveCompare("Attention Is All You Need") == .orderedSame }) else {
            throw Failure(description: "The source library does not contain Attention Is All You Need")
        }
        let state = SceneState(selected: attention.id)
        let hosting = NSHostingController(rootView: FixtureRoot(store: store, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1539, height: 918),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: -1000)
        window.contentViewController = hosting
        // Complete appearance without activation or covering normal windows.
        window.orderBack(nil)
        defer { window.close() }
        settle(hosting.view)
        guard let split = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first,
              let controller = split.delegate as? NativeLibraryController,
              let outline = descendants(hosting.view).compactMap({ $0 as? NSOutlineView }).first(where: {
                  $0.accessibilityIdentifier() == "paper-table"
              }), let tableScroll = outline.enclosingScrollView else {
            throw Failure(description: "The shipping native library did not attach to the controlled host")
        }
        var failures: [String] = []
        var samples: [[String: Any]] = []
        let expectedWidths: [CGFloat] = [433,115,55,95,81,95,139]
        let originalRows = outline.numberOfRows
        let originalSelection = state.selection

        func check(_ condition: Bool, _ message: String, stage: String) {
            if !condition { failures.append("\(stage): \(message)") }
        }

        @discardableResult
        func capture(_ stage: String) throws -> [String: Any] {
            settle(hosting.view, seconds: 0.12)
            // Selection was supplied before the first zero-sized table layout.
            // Normalize that initial reveal scroll for comparable list anchors.
            let tableClip = tableScroll.contentView
            tableClip.scroll(to: NSPoint(x: tableClip.bounds.minX, y: 0))
            tableScroll.reflectScrolledClipView(tableClip)
            let root = hosting.view
            let rootBounds = root.bounds
            let inner = controller.sidebarSplitView
            let sidebarView = inner.arrangedSubviews[0]
            let tableView = inner.arrangedSubviews[1]
            let inspectorView = controller.splitView.arrangedSubviews[1]
            // This inspector is a separate NSHostingController, so an outer
            // SwiftUI preferredColorScheme does not cross the AppKit bridge in
            // a nonactivated host. Give that host the same explicit environment.
            if let inspectorHost = controller.children.compactMap({ $0 as? NSHostingController<AnyView> }).first {
                inspectorHost.rootView = AnyView(inspectorHost.rootView.environment(\.colorScheme, .dark))
                settle(root, seconds: 0.08)
            }
            let sidebarRect = sidebarView.convert(sidebarView.bounds, to: root)
            let tableRect = tableView.convert(tableView.bounds, to: root)
            let inspectorRect = inspectorView.convert(inspectorView.bounds, to: root)
            let splitRect = controller.splitView.convert(controller.splitView.bounds, to: root)
            let visiblePanes = [(!controller.isSidebarCollapsed, "sidebar", sidebarRect),
                                (true, "table", tableRect),
                                (!controller.isInspectorCollapsed, "inspector", inspectorRect)]
            let tolerance: CGFloat = 1.1
            for (visible, name, pane) in visiblePanes where visible {
                check(pane.width > 0 && pane.height > 0, "\(name) has an empty viewport", stage: stage)
                check(pane.minX >= rootBounds.minX - tolerance && pane.maxX <= rootBounds.maxX + tolerance &&
                      pane.minY >= rootBounds.minY - tolerance && pane.maxY <= rootBounds.maxY + tolerance,
                      "\(name) extends outside the host", stage: stage)
                check(abs(pane.height - splitRect.height) <= tolerance && abs(pane.minY - splitRect.minY) <= tolerance,
                      "\(name) lost the shared vertical pane anchors", stage: stage)
            }
            let ordered = visiblePanes.filter { $0.0 }.map { ($0.1, $0.2) }.sorted { $0.1.minX < $1.1.minX }
            for pair in zip(ordered, ordered.dropFirst()) {
                check(pair.0.1.maxX <= pair.1.1.minX + tolerance,
                      "\(pair.0.0) overlaps \(pair.1.0)", stage: stage)
            }
            check(abs(splitRect.width - rootBounds.width) <= tolerance,
                  "The native split does not fill the host width", stage: stage)
            check(controller.isSidebarCollapsed == !state.sidebar && controller.isInspectorCollapsed == !state.inspector,
                  "Settled pane visibility differs from the latest requested state", stage: stage)
            check(!controller.isPanelTransitionActive, "A pane animation did not settle", stage: stage)
            if !controller.isSidebarCollapsed {
                check(abs(sidebarRect.width - 240) <= tolerance && abs(sidebarRect.minX - rootBounds.minX) <= tolerance,
                      "The sidebar width or leading anchor drifted", stage: stage)
            }
            if !controller.isInspectorCollapsed {
                check(abs(inspectorRect.width - 320) <= tolerance && abs(inspectorRect.maxX - rootBounds.maxX) <= tolerance,
                      "The inspector width or trailing anchor drifted", stage: stage)
            }
            check(state.selection == originalSelection, "Layout changes replaced the selected Attention record", stage: stage)
            check(outline.tableColumns.count == expectedWidths.count &&
                  zip(outline.tableColumns, expectedWidths).allSatisfy { abs($0.0.width - $0.1) < 0.5 },
                  "Layout or attachment disclosure changed the reference column widths", stage: stage)
            let viewport = tableScroll.contentView.convert(tableScroll.contentView.bounds, to: root)
            check(viewport.minX >= tableRect.minX - tolerance && viewport.maxX <= tableRect.maxX + tolerance,
                  "The table clipping viewport crossed a pane divider", stage: stage)
            let columns: [[String: Any]] = outline.tableColumns.enumerated().map { index, column in
                var value: [String: Any] = ["id": column.identifier.rawValue, "width": Double(column.width)]
                if let header = outline.headerView { value["header"] = rect(header.convert(header.headerRect(ofColumn: index), to: root)) }
                return value
            }
            let inspectorRatings = descendants(inspectorView).compactMap { $0 as? NativeStarRatingControl }
            let inspectorRatingRects = inspectorRatings.map { rect($0.convert($0.bounds, to: root)) }
            if !controller.isInspectorCollapsed {
                check(inspectorRatings.count == 1, "The inspector did not materialize its single native rating control", stage: stage)
                if let rating = inspectorRatings.first {
                    let ratingRect = rating.convert(rating.bounds, to: root)
                    check(ratingRect.minX >= inspectorRect.minX - tolerance && ratingRect.maxX <= inspectorRect.maxX + tolerance,
                          "The inspector rating extends across a pane divider", stage: stage)
                }
            }
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: rootBounds) else {
                throw Failure(description: "\(stage): cacheDisplay could not allocate a bitmap")
            }
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                root.cacheDisplay(in: rootBounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(description: "\(stage): cacheDisplay could not encode a PNG")
            }
            let pngURL = outputURL.appendingPathComponent("native-host-\(stage).png")
            try png.write(to: pngURL, options: .atomic)
            let sample: [String: Any] = ["stage": stage, "scope": "controlled-native-host-cacheDisplay",
                "host": rect(rootBounds), "safeArea": rect(root.safeAreaRect), "split": rect(splitRect),
                "sidebar": rect(sidebarRect), "table": rect(tableRect), "inspector": rect(inspectorRect),
                "sidebarVisible": !controller.isSidebarCollapsed, "inspectorVisible": !controller.isInspectorCollapsed,
                "tableViewport": rect(viewport), "horizontalOffset": Double(tableScroll.contentView.bounds.minX),
                "verticalOffset": Double(tableScroll.contentView.bounds.minY),
                "rowHeight": Double(outline.rowHeight), "rowCount": outline.numberOfRows,
                "selectedRows": Array(outline.selectedRowIndexes), "columns": columns,
                "inspectorRatings": inspectorRatingRects, "png": pngURL.path,
                "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "rootIsFlipped": root.isFlipped]
            samples.append(sample)
            print("RENDER: \(stage) \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), panes \(Int(sidebarRect.width))/\(Int(tableRect.width))/\(Int(inspectorRect.width))")
            return sample
        }

        for size in [NSSize(width: 1539, height: 918), NSSize(width: 1280, height: 800), NSSize(width: 1080, height: 680)] {
            window.setContentSize(size)
            settle(hosting.view)
            try capture("\(Int(size.width))x\(Int(size.height))-all-panes")
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        for (sidebar, inspector, name) in [(false,true,"sidebar-hidden"), (true,false,"inspector-hidden"),
                                          (false,false,"both-hidden"), (true,true,"panes-restored")] {
            state.sidebar = sidebar; state.inspector = inspector
            settle(hosting.view)
            try capture("1280x800-\(name)")
        }
        // Allow each request to reach the native bridge while prior native
        // animations are still in flight; the final intent must win.
        for (sidebar, inspector) in [(false,true),(true,false),(false,false),(true,true),(false,true),(true,true)] {
            state.sidebar = sidebar; state.inspector = inspector
            settle(hosting.view, seconds: 0.035)
        }
        settle(hosting.view, seconds: 1)
        try capture("1280x800-rapid-toggle-settled")

        window.setContentSize(NSSize(width: 1080, height: 680))
        settle(hosting.view)
        guard let selectedRow = outline.selectedRowIndexes.first, let attentionNode = outline.item(atRow: selectedRow) else {
            throw Failure(description: "The Attention row is not selected for attachment verification")
        }
        let childCount = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: attentionNode) ?? 0
        check(childCount > 0, "Attention has no source attachments for expansion verification", stage: "attachments")
        if childCount > 0 {
            outline.expandItem(attentionNode)
            settle(hosting.view)
            check(outline.numberOfRows == originalRows + childCount, "Attachment expansion inserted the wrong row count", stage: "attachments")
            check(abs(outline.rect(ofRow: selectedRow).height - 27) < 0.5,
                  "Attachment expansion changed the parent height", stage: "attachments")
            check(outline.level(forRow: selectedRow + 1) == 1,
                  "Attachment rows lost their native hierarchy depth", stage: "attachments")
            try capture("1080x680-attachments-expanded")
            let clip = tableScroll.contentView
            let maxOffset = max(0, outline.bounds.width - clip.bounds.width)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: min(120, maxOffset), y: clip.bounds.minY), size: clip.bounds.size)).origin)
            tableScroll.reflectScrolledClipView(clip)
            check(clip.bounds.minX > 0, "Narrow table did not expose horizontal scrolling", stage: "horizontal")
            try capture("1080x680-expanded-horizontal")
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: maxOffset, y: clip.bounds.minY), size: clip.bounds.size)).origin)
            tableScroll.reflectScrolledClipView(clip)
            try capture("1080x680-expanded-right-edge")
            outline.collapseItem(attentionNode)
            clip.scroll(to: NSPoint(x: 0, y: 0)); tableScroll.reflectScrolledClipView(clip)
        }
        window.setContentSize(NSSize(width: 1539, height: 918))
        settle(hosting.view)
        try capture("1539x918-restored-after-stress")
        check(outline.numberOfRows == originalRows, "Attachment collapse did not restore the parent rows", stage: "restored")
        let finalSourceHash = sha256(try Data(contentsOf: sourceURL))
        check(sourceHash == finalSourceHash, "The production JSON changed during the isolated fixture run", stage: "source-integrity")
        let report: [String: Any] = ["passed": failures.isEmpty, "failures": failures, "samples": samples,
            "scope": "controlled-native-host-cacheDisplay; not an installed-app screenshot",
            "shippingViews": ["NativeLibraryView", "NativeSidebarController", "NativePaperTableController", "PaperDetailView"],
            "hostOnly": "NSHostingController wrapper, inactive behind-normal-windows NSWindow, three recreated outer toolbar buttons",
            "renderLimits": "Inactive system selection; cacheDisplay does not reproduce compositor-backed toolbar or vibrancy materials. Use installed-app window captures for color and pixel fidelity.",
            "appearance": "Dark Aqua forced on NSApplication, NSWindow and SwiftUI; effective appearance used for cacheDisplay",
            "activationRequested": false, "sourceLibrary": sourceURL.path, "isolatedLibrary": libraryCopy.path,
            "sourceSHA256Before": sourceHash, "sourceSHA256After": finalSourceHash,
            "sourceUnchanged": sourceHash == finalSourceHash, "selectedPaper": attention.title,
            "selectedPaperID": attention.id.uuidString, "paperCount": store.papers.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL.appendingPathComponent("native-host-geometry.json"), options: .atomic)
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
        print("UI fidelity smoke: \(samples.count) controlled native-host scenarios passed; production JSON unchanged")
    }
}
