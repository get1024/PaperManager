import AppKit
import Darwin
import Foundation
import SwiftUI

@main
@MainActor
struct NativeTableSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class State {
        var selection: Set<UUID> = []
        var filter: LibraryFilter = .all
        var search = ""
        var includeSubcollections = true
        var sort = PaperSortDescriptor()
        var focusSearchToken = 0
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try run()
            print("Native table smoke: 8 passed, 0 failed")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerNativeTable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var snapshot = LibrarySnapshot.empty
        snapshot.papers = (0..<72).map { index in
            var paper = Paper()
            paper.title = "Native table smoke paper \(index)"
            paper.authors = ["Author \(index)", "Second Author"]
            paper.year = 2026
            paper.journal = "Fixture Journal"
            paper.rating = 2
            paper.notes = "Synthetic fixture; no original library is opened."
            return paper
        }
        try store.replaceSnapshotDurably(snapshot)
        let state = State()
        func configuration(showInspector: Bool = false, showSidebar: Bool = true) -> NativeLibraryView {
            NativeLibraryView(store: store, papers: store.snapshot.papers,
                selectedFilter: Binding(get: { state.filter }, set: { state.filter = $0 }),
                selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                searchText: Binding(get: { state.search }, set: { state.search = $0 }),
                includeSubcollections: Binding(get: { state.includeSubcollections }, set: { state.includeSubcollections = $0 }),
                sortDescriptor: Binding(get: { state.sort }, set: { state.sort = $0 }),
                showSidebar: showSidebar, showInspector: showInspector, focusSearchToken: state.focusSearchToken,
                onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
                onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {})
        }
        let controller = NativePaperTableController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        controller.configure(configuration())
        controller.view.layoutSubtreeIfNeeded()
        guard let outline = descendants(controller.view).compactMap({ $0 as? NSOutlineView }).first else {
            throw Failure(description: "The native controller did not create its outline")
        }
        try expect(outline.numberOfRows == 72, "The fixture must render 72 native paper rows")
        let initialReloads = controller.smokeFullReloadCount
        let initialRowReloads = controller.smokeRowReloadCount
        let initialCell = outline.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { controller.configure(configuration()) }
        try expect(controller.smokeFullReloadCount == initialReloads && controller.smokeRowReloadCount == initialRowReloads,
                   "Unchanged configurations repeatedly reloaded the table")
        try expect(initialCell === outline.view(atColumn: 0, row: 0, makeIfNecessary: true), "Unchanged configuration discarded a native cell")
        print(String(format: "PASS: 72 rows and 100 unchanged configurations, zero reloads (%.3fs)", CFAbsoluteTimeGetCurrent() - start))

        var paper = store.snapshot.papers[0]
        paper.notes = "A single changed native row"
        try store.updatePaperDurably(paper)
        controller.configure(configuration())
        try expect(controller.smokeFullReloadCount == initialReloads, "A metadata edit rebuilt the whole table")
        try expect(controller.smokeRowReloadCount == initialRowReloads + 1, "A metadata edit did not update its row")
        state.selection = [store.snapshot.papers[71].id]
        controller.configure(configuration())
        try expect(outline.selectedRowIndexes == IndexSet(integer: 71), "External selection did not select its native row")
        try expect(controller.smokeRowReloadCount == initialRowReloads + 1, "Selection alone reloaded row contents")
        print("PASS: Metadata diff reloads one row; external selection does not reload")

        let axStart = CFAbsoluteTimeGetCurrent()
        var descriptionReads = 0
        for _ in 0..<8 {
            // This intentionally calls the legacy entry point found in the
            // sampled NSTableViewCellMockElement accessibilityDescription stack.
            // Avoid the SDK's typed [NSAccessibilityRow] bridge here: macOS 27
            // returns private NSOutlineRow objects without that ObjC protocol.
            let rows = outline.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXRows")) as? [NSObject] ?? []
            for object in rows {
                guard let cells = object.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXChildren")) as? [NSObject] else { continue }
                for cell in cells {
                    _ = cell.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXDescription"))
                    _ = cell.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXValue"))
                    descriptionReads += 1
                }
            }
        }
        let axElapsed = CFAbsoluteTimeGetCurrent() - axStart
        try expect(descriptionReads >= 72 * 7, "The smoke did not exercise offscreen AX table cell descriptions")
        try expect(axElapsed < 10, "Repeated AX traversal remained too expensive")
        try expect(controller.smokeFullReloadCount == initialReloads, "AX inspection reloaded the table")
        print(String(format: "PASS: %d native AX cell descriptions including offscreen rows (%.3fs)", descriptionReads, axElapsed))

        guard let ratingColumn = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "rating" }),
              let ratingCell = outline.view(atColumn: ratingColumn, row: 0, makeIfNecessary: true),
              let rating = descendants(ratingCell).compactMap({ $0 as? NativeStarRatingControl }).first else {
            throw Failure(description: "The rating cell did not contain its native star control")
        }
        ratingCell.layoutSubtreeIfNeeded()
        try expect(rating.isEnabled && descendants(ratingCell).allSatisfy { !($0 is NSButton) }, "A rating still contains modern NSButton sizing bridges")
        try expect(rating.accessibilityRole() == .slider, "The rating lacks its AX slider role")
        try expect(rating.accessibilityPerformIncrement(), "AX increment did not act")
        try expect(store.paper(with: paper.id)?.rating == 3, "AX increment did not update the requested paper")
        let click = rating.convert(NSPoint(x: 67, y: rating.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: click, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(description: "Could not construct native rating mouse event")
        }
        rating.mouseDown(with: event)
        try expect(store.paper(with: paper.id)?.rating == 5, "Clicking the fifth star did not set five stars")
        rating.mouseDown(with: event)
        try expect(store.paper(with: paper.id)?.rating == 0, "Clicking the current star did not clear the rating")
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "4",
                                      charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21) {
            rating.keyDown(with: key)
        }
        try expect(store.paper(with: paper.id)?.rating == 4, "The keyboard did not set a four-star rating")
        rating.setAccessibilityValue(NSNumber(value: 1))
        try expect(store.paper(with: paper.id)?.rating == 1, "Setting the AX slider value did not persist")
        try expect((rating.accessibilityValue() as? NSNumber)?.intValue == 1 &&
                   rating.accessibilityValueDescription() == PMLocalization.format("%lld 星", 1),
                   "AX did not expose the current numeric rating and localized value description")
        if let image = rating.bitmapImageRepForCachingDisplay(in: rating.bounds) { rating.cacheDisplay(in: rating.bounds, to: image) }
        print("PASS: Native star drawing, mouse/keyboard/AX input and toggle-to-zero persist without NSButtons")

        func hostedRoot(showInspector: Bool = true, showSidebar: Bool = true) -> some View {
            configuration(showInspector: showInspector, showSidebar: showSidebar)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowChromeConfigurator { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
                window.contentMinSize = NSSize(width: 1080, height: 680)
            })
            .navigationTitle("Native library hosting fixture")
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) { Text("Panels") }
                ToolbarItemGroup(placement: .primaryAction) { Text("Add"); Text("Export") }
            }
            .frame(minWidth: 1080, minHeight: 680)
        }
        let hosting = NSHostingController(rootView: hostedRoot())
        // Complete the real window/controller appearance lifecycle without
        // activating the test app or covering the user's normal-level windows.
        NSApp.setActivationPolicy(.accessory)
        let hostedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 860),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        hostedWindow.isReleasedWhenClosed = false
        hostedWindow.isExcludedFromWindowsMenu = true
        hostedWindow.level = NSWindow.Level(rawValue: -1000)
        hostedWindow.contentViewController = hosting
        hostedWindow.orderBack(nil)
        defer { hostedWindow.close() }
        for size in [NSSize(width: 1420, height: 860), NSSize(width: 1080, height: 680), NSSize(width: 1760, height: 1000)] {
            hostedWindow.setContentSize(size)
            hosting.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            hosting.view.layoutSubtreeIfNeeded()
            guard let split = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first else {
                throw Failure(description: "The hosted representable did not create its native split view")
            }
            let splitRect = split.convert(split.bounds, to: hosting.view)
            let expectedRect = hosting.view.safeAreaRect
            print("MEASURE: host=\(hosting.view.bounds) safeArea=\(expectedRect) split=\(splitRect)")
            for child in split.arrangedSubviews where !child.isHidden {
                let childRect = child.convert(child.bounds, to: hosting.view)
                print("MEASURE: pane \(type(of: child))=\(childRect)")
                try expect(abs(childRect.height - splitRect.height) < 1,
                           "A native split pane did not fill the split's vertical content area")
            }
            try expect(abs(splitRect.height - expectedRect.height) < 1 && abs(splitRect.minY - expectedRect.minY) < 1,
                       "The hosted native split chose its fitting height instead of filling the proposed height")
            try expect(abs(splitRect.width - expectedRect.width) < 1,
                       "The hosted native split did not fill the proposed width")
        }
        print("PASS: NSHostingController native split fills 1420×860 and both smaller/larger resized windows")
        let hostedSplit = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first!
        for (showSidebar, showInspector, expectedPanes) in [(false, true, 2), (true, false, 2), (false, false, 1), (true, true, 3)] {
            hosting.rootView = hostedRoot(showInspector: showInspector, showSidebar: showSidebar)
            hosting.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let current = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first!
            try expect(current === hostedSplit, "Toggling a pane discarded the owned native split")
            try expect(current.arrangedSubviews.filter { !current.isSubviewCollapsed($0) }.count == expectedPanes,
                       "Native sidebar/inspector collapsing did not match the bridge state")
            try expect(abs(current.frame.height - hosting.view.safeAreaRect.height) < 1,
                       "Collapsing a pane restored the stale fitting height")
        }
        print("PASS: Pane collapse/reopen preserves the native split and its full content height")

        let coordinator = NativeLibraryView.Coordinator()
        let bridgedController = coordinator.makeController(configuration(showInspector: true))
        let bridgedRoot = bridgedController.view
        try expect(coordinator.controller === bridgedController, "The coordinator lost its native controller")
        let bridgeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 808),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        bridgeWindow.isReleasedWhenClosed = false
        bridgeWindow.contentViewController = bridgedController
        defer { bridgeWindow.close() }
        bridgeWindow.setContentSize(NSSize(width: 1080, height: 680))
        bridgedRoot.layoutSubtreeIfNeeded()
        try expect(bridgedController.view === bridgedRoot && abs(bridgedRoot.frame.height - 680) < 1,
                   "AppKit resizing replaced the controller's original root")
        let draftSession = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        draftSession.select(paper.id, in: store)
        var pendingDraft = draftSession.draft
        pendingDraft.notes = "Pending draft flushed by native bridge dismantle"
        draftSession.edit(pendingDraft)
        NativeLibraryView.dismantleNSViewController(bridgedController, coordinator: coordinator)
        try expect(coordinator.controller == nil, "Dismantle retained its owning native controller")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).paper(with: paper.id)?.notes == pendingDraft.notes,
                   "Dismantling the NSView bridge lost its pending draft")
        print("PASS: Native controller bridge preserves its root, resizes and flushes drafts before release")

        let routing = NativeLibraryView.Coordinator()
        let routingController = routing.makeController(configuration(showInspector: true))
        let routingView = routingController.view
        bridgeWindow.contentViewController = routingController
        guard let routingTable = descendants(routingView).compactMap({ $0 as? NSOutlineView }).first(where: {
            $0.accessibilityIdentifier() == "paper-table"
        }) else { throw Failure(description: "Missing routed paper table") }
        routingTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try expect(state.selection == [store.snapshot.papers[2].id], "Native selection no longer writes through the SwiftUI binding")
        state.selection = [store.snapshot.papers[5].id]
        state.focusSearchToken += 1
        routing.update(configuration(showInspector: true))
        try expect(routingTable.selectedRowIndexes == IndexSet(integer: 5), "External selection no longer reaches the owned native controller")
        guard let search = descendants(routingView).compactMap({ $0 as? NSSearchField }).first else {
            throw Failure(description: "Missing native search field")
        }
        let editorFocused = search.currentEditor().map { bridgeWindow.firstResponder === $0 } ?? false
        try expect(bridgeWindow.firstResponder === search || editorFocused,
                   "The focused-window search token no longer reaches its native control")
        routing.dismantle(routingController)
        print("PASS: SwiftUI selection bindings and focused-window search routing survive the new bridge")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
