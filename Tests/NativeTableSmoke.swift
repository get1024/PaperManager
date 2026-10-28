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
        var sidebarToggleCount = 0
        var panelVisibilityChanges: [(Bool, Bool)] = []
        var deleteCalls = 0
    }
    /// A deterministic AppKit reuse boundary: the production delegate receives
    /// either no reusable view or a real cell previously configured as a parent.
    private final class ReuseProbeOutline: NSOutlineView {
        var recycledCell: NSView?
        override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
            recycledCell?.identifier == identifier ? recycledCell : nil
        }
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try run()
            let expansionOnly = ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_EXPANSION_ONLY"] == "1"
            let selectionOnly = ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_SELECTION_ONLY"] == "1"
            print(expansionOnly ? "Native table expansion geometry: 1 passed, 0 failed" :
                  selectionOnly ? "Native row selection coverage: 1 passed, 0 failed" : "Native table smoke: 25 passed, 0 failed")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    /// AppKit can retain a row's backing pixels while its clip view moves. Paint
    /// once through the actual delegate-created row, then sample newly exposed
    /// edges after real scrolling/resizing. Repainting in the test after every
    /// scroll would conceal the missing selection pixels seen in the recording.
    private static func verifySelectionBackingCoverage(outline: NSOutlineView, window: NSWindow) throws {
        guard let scroll = outline.enclosingScrollView else {
            throw Failure(description: "Missing selection coverage scroll view")
        }
        let originalSize = window.contentView?.bounds.size ?? .zero
        let originalOffset = scroll.contentView.bounds.origin
        let originalSelection = outline.selectedRowIndexes
        defer {
            window.setContentSize(originalSize)
            window.contentView?.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: originalOffset)
            scroll.reflectScrolledClipView(scroll.contentView)
            outline.selectRowIndexes(originalSelection, byExtendingSelection: false)
        }
        window.setContentSize(NSSize(width: 700, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        outline.selectRowIndexes([0], byExtendingSelection: false)
        guard let row = outline.rowView(atRow: 0, makeIfNecessary: true) as? NativePaperRowView else {
            throw Failure(description: "Selection coverage fixture did not use the production row delegate")
        }
        let bounds = row.bounds
        let initialViewport = row.visibleRect
        try expect(bounds.width > initialViewport.width + 200 && initialViewport.width > 300,
                   "Selection coverage fixture did not actually clip its overflowing document row")
        let width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure(description: "Could not allocate the retained selection backing fixture")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
        let transform = NSAffineTransform()
        transform.translateX(by: -bounds.minX, yBy: -bounds.minY)
        transform.concat()
        row.drawSelection(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        var stages: [[String: Any]] = []
        var failures: [String] = []
        func sample(_ stage: String) {
            let viewport = row.visibleRect
            let sampleY = min(height - 1, max(0, Int(floor(bounds.midY - bounds.minY))))
            let left = min(width - 1, max(0, Int(floor(viewport.minX - bounds.minX + 1))))
            let right = min(width - 1, max(0, Int(floor(viewport.maxX - bounds.minX - 2))))
            let leftAlpha = bitmap.colorAt(x: left, y: sampleY)?.alphaComponent ?? 0
            let rightAlpha = bitmap.colorAt(x: right, y: sampleY)?.alphaComponent ?? 0
            stages.append(["stage": stage, "rowWidth": Double(bounds.width),
                "viewportX": Double(viewport.minX), "viewportWidth": Double(viewport.width),
                "leftSampleX": left, "rightSampleX": right,
                "leftAlpha": Double(leftAlpha), "rightAlpha": Double(rightAlpha)])
            if leftAlpha < 0.99 || rightAlpha < 0.99 {
                failures.append("\(stage): a newly exposed viewport edge lacks selection pixels (left \(leftAlpha), right \(rightAlpha))")
            }
        }
        sample("initialClippedViewport")
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try expect(row.visibleRect.minX > initialViewport.minX + 100,
                   "Selection coverage fixture did not actually scroll its native clip view")
        sample("scrollRight120")
        window.setContentSize(NSSize(width: 900, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()
        try expect(row.visibleRect.width > initialViewport.width + 150,
                   "Selection coverage fixture did not reveal a wider native viewport")
        sample("widenViewport900")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        sample("returnLeftAfterResize")
        window.setContentSize(NSSize(width: 700, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: bounds.maxX - scroll.contentView.bounds.width, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        sample("rightmostColumns")
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_SELECTION_REPORT"] {
            let report = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["ok": failures.isEmpty, "failures": failures, "stages": stages],
                options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: report.deletingPathExtension().appendingPathExtension("png"), options: .atomic)
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS: Retained native row selection covers both newly exposed viewport edges through scrolling and resizing")
    }

    private static func run() throws {
        // Production uses standard defaults. Keep this test's deliberate
        // column/pane mutations reversible even when run outside its script.
        let preferenceKeys = ["PaperManager.NativePaperColumnLayout", "PaperManager.NativePaperColumnLayout.v2", "PaperManager.NativePaperColumnLayout.v3",
                              "PaperManager.NativePaperColumnLayout.beforeLatticeFidelity", "PaperManager.NativeLibraryPaneWidths",
                              "NSTableView Columns PaperManager.NativePaperColumns",
                              "NSSplitView Subview Frames PaperManager.NativeLibrarySplit"]
        let previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        for key in preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let previous = previousPreferences[key] { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
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
        snapshot.papers[0].authors = ["First Author", "Second Author", "Third Author"]
        snapshot.papers[1].year = nil
        snapshot.papers[1].journal = ""
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
                onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: { state.deleteCalls += 1 }, onImportURLs: { _ in },
                onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {},
                onToggleSidebar: { state.sidebarToggleCount += 1 },
                onPanelVisibilityChanged: { state.panelVisibilityChanges.append(($0, $1)) })
        }
        let expectedColumns: [(String, CGFloat)] = [("title",433),("authors",115),("year",55),("source",95),
                                                     ("rating",81),("dateAdded",95),("notes",139)]
        let legacyWidths: [Double] = [452,123,63,103,89,103,147]
        let legacyLayout: [[String: Any]] = expectedColumns.enumerated().map { index, column in
            ["id": column.0, "width": legacyWidths[index], "hidden": false]
        }
        func migratedOutline(_ layout: [[String: Any]]) throws -> NSOutlineView {
            UserDefaults.standard.removeObject(forKey: "PaperManager.NativePaperColumnLayout.v3")
            UserDefaults.standard.removeObject(forKey: "PaperManager.NativePaperColumnLayout.beforeLatticeFidelity")
            UserDefaults.standard.set(layout, forKey: "PaperManager.NativePaperColumnLayout.v2")
            let migrationController = NativePaperTableController()
            migrationController.configure(configuration())
            guard let table = descendants(migrationController.view).compactMap({ $0 as? NSOutlineView }).first else {
                throw Failure(description: "The migrated table is missing its outline")
            }
            return table
        }
        let migratedDefaults = try migratedOutline(legacyLayout)
        try expect(zip(migratedDefaults.tableColumns, expectedColumns).allSatisfy { abs($0.0.width - $0.1.1) < 0.5 },
                   "An untouched v2 shipped layout failed to migrate to the measured defaults")
        var customLegacy = legacyLayout
        customLegacy[0]["width"] = 480.0
        customLegacy[3]["hidden"] = true
        customLegacy.swapAt(1, 6)
        let migratedCustom = try migratedOutline(customLegacy)
        try expect(zip(migratedCustom.tableColumns, expectedColumns).allSatisfy { abs($0.0.width - $0.1.1) < 0.5 },
                   "The prior v2 layout prevented the requested one-time reference layout migration")
        guard let archivedLayout = UserDefaults.standard.array(forKey: "PaperManager.NativePaperColumnLayout.beforeLatticeFidelity") as? [[String: Any]] else {
            throw Failure(description: "The previous column layout was not archived before migration")
        }
        try expect(archivedLayout.map { $0["id"] as? String } == customLegacy.map { $0["id"] as? String } &&
                   (archivedLayout[0]["width"] as? NSNumber)?.doubleValue == 480 &&
                   archivedLayout[3]["hidden"] as? Bool == true,
                   "The archived column layout lost custom widths, order or hidden columns")
        try expect(UserDefaults.standard.array(forKey: "PaperManager.NativePaperColumnLayout.v3") != nil,
                   "Migrated column preferences were not saved under v3")
        for key in ["PaperManager.NativePaperColumnLayout.v2", "PaperManager.NativePaperColumnLayout.v3", "PaperManager.NativePaperColumnLayout.beforeLatticeFidelity"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        print("PASS: Column layout adopts the reference once and archives the previous custom layout")

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
        try expect(!outline.autosaveTableColumns && outline.style == .inset,
                   "Legacy AppKit column autosave or full-width row styling was re-enabled")
        try expect(outline.tableColumns.map { $0.identifier.rawValue } == expectedColumns.map { $0.0 } &&
                   zip(outline.tableColumns, expectedColumns).allSatisfy { abs($0.0.width - $0.1.1) < 0.5 },
                   "A table without a v3 layout failed to apply the measured reference defaults")
        print("PASS: New table ignores legacy autosave and uses inset rows/reference column widths")
        try verifyAttachmentExpansionGeometry(store: store, root: root, controller: controller,
            outline: outline, window: window, configure: { controller.configure(configuration()) })
        if ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_EXPANSION_ONLY"] == "1" { return }
        try expect(outline.numberOfRows == 72, "The fixture must render 72 native paper rows")
        try expect(outline.rowView(atRow: 0, makeIfNecessary: true) is NativePaperRowView,
                   "The actual table delegate did not install its viewport selection row")
        let highlightRow = NativePaperRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 27))
        highlightRow.isSelected = true
        highlightRow.isEmphasized = true
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 27,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure(description: "Could not create a native selection bitmap")
        }
        func paintHighlight() {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSColor.clear.setFill()
            highlightRow.bounds.fill(using: .copy)
            highlightRow.drawSelection(in: highlightRow.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        paintHighlight()
        try expect((bitmap.colorAt(x: 0, y: 13)?.alphaComponent ?? 0) > 0.99 &&
                   (bitmap.colorAt(x: 299, y: 13)?.alphaComponent ?? 0) > 0.99,
                   "The floating reference selection did not fill both viewport edges")
        try expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) > 0.99 &&
                   (bitmap.colorAt(x: 150, y: 13)?.alphaComponent ?? 0) > 0.99,
                   "The floating reference selection lost its square corner or solid center")
        highlightRow.isEmphasized = false
        paintHighlight()
        guard let inactive = bitmap.colorAt(x: 150, y: 13)?.usingColorSpace(.deviceRGB),
              let expectedInactive = NSColor.unemphasizedSelectedContentBackgroundColor.usingColorSpace(.deviceRGB) else {
            throw Failure(description: "Could not resolve the system's inactive selection color")
        }
        try expect(abs(inactive.redComponent - expectedInactive.redComponent) < 0.01 &&
                   abs(inactive.greenComponent - expectedInactive.greenComponent) < 0.01 &&
                   abs(inactive.blueComponent - expectedInactive.blueComponent) < 0.01 && inactive.alphaComponent > 0.99,
                   "An inactive selected row did not retain the native unemphasized selection color")
        highlightRow.isSelected = false
        paintHighlight()
        try expect((bitmap.colorAt(x: 150, y: 13)?.alphaComponent ?? 1) == 0,
                   "An unselected row still painted selection pixels")
        highlightRow.isSelected = true
        highlightRow.selectionHighlightStyle = .none
        paintHighlight()
        try expect((bitmap.colorAt(x: 150, y: 13)?.alphaComponent ?? 1) == 0,
                   "A row with selection drawing disabled still painted selection pixels")
        print("PASS: Native rows retain square coverage, system inactive colors and selection drawing guards")
        try verifySelectionBackingCoverage(outline: outline, window: window)
        if ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_SELECTION_ONLY"] == "1" { return }
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
        window.setContentSize(NSSize(width: 700, height: 300))
        controller.view.layoutSubtreeIfNeeded()
        guard let scroll = outline.enclosingScrollView else { throw Failure(description: "Missing native table scroll view") }
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let horizontalOffset = scroll.contentView.bounds.origin.x
        try expect(horizontalOffset > 100, "Horizontal-scroll fixture did not actually overflow")
        state.selection = [store.snapshot.papers[71].id]
        controller.configure(configuration())
        try expect(abs(scroll.contentView.bounds.origin.x - horizontalOffset) < 0.5,
                   "Selecting an offscreen paper scrolled away the title column")
        try expect(outline.selectedRowIndexes == IndexSet(integer: 71), "External selection did not select its native row")
        try expect(controller.smokeRowReloadCount == initialRowReloads + 1, "Selection alone reloaded row contents")
        print("PASS: Metadata diff reloads one row; external selection does not reload")
        outline.scrollRowToVisible(0)
        outline.selectRowIndexes(IndexSet(integer: 50), byExtendingSelection: false)
        try expect(abs(scroll.contentView.bounds.origin.x - horizontalOffset) < 0.5,
                   "Native row selection/reveal changed the user's horizontal position")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        state.selection = [store.snapshot.papers[71].id]
        controller.configure(configuration())
        try expect(abs(scroll.contentView.bounds.origin.x) < 0.5,
                   "Selecting from the left edge horizontally cropped the title")
        window.setContentSize(NSSize(width: 1440, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        print("PASS: Native/external offscreen row selection preserves horizontal scroll position")

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

        do {
            let preserved = store.persistenceURL.appendingPathExtension("rating-preserved")
            try FileManager.default.moveItem(at: store.persistenceURL, to: preserved)
            try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: store.persistenceURL)
                try? FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
            }
            rating.setAccessibilityValue(NSNumber(value: 5))
            try expect(store.paper(with: paper.id)?.rating == 1 &&
                       (rating.accessibilityValue() as? NSNumber)?.intValue == 1,
                       "A rejected JSON write left a false rating in the native control or its AX value")
            try expect(LibraryStore(persistenceURL: preserved).paper(with: paper.id)?.rating == 1,
                       "A rejected rating write changed the last committed JSON")
        }
        print("PASS: A real JSON write failure restores the native rating and AX value")

        func textCell(column id: String, row: Int) throws -> NSTableCellView {
            guard let index = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                  let cell = outline.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView else {
                throw Failure(description: "Missing native cell \(id)/\(row)")
            }
            return cell
        }
        try expect(try textCell(column: "authors", row: 0).textField?.stringValue == "First Author et al.",
                   "The table no longer abbreviates three or more authors")
        try expect(try textCell(column: "authors", row: 1).textField?.stringValue == "Author 1 & Second Author",
                   "The table no longer joins two authors with an ampersand")
        try expect(try textCell(column: "year", row: 1).textField?.stringValue == "—" &&
                   textCell(column: "source", row: 1).textField?.stringValue == "—",
                   "Missing year/source values must remain visible as em dashes")
        print("PASS: Table-only author summaries and missing year/source placeholders match the reference")

        let selectedCell = try textCell(column: "authors", row: 0)
        selectedCell.backgroundStyle = .emphasized
        try expect(selectedCell.textField?.textColor == NSColor.white,
                   "Selected metadata must be white")
        selectedCell.backgroundStyle = .normal
        try expect(selectedCell.textField?.textColor == .secondaryLabelColor,
                   "Deselecting metadata failed to restore its secondary text color")
        (ratingCell as? NSTableCellView)?.backgroundStyle = .emphasized
        try expect(rating.usesSelectedColors, "Selected star outlines did not follow native row emphasis")
        (ratingCell as? NSTableCellView)?.backgroundStyle = .normal
        try expect(!rating.usesSelectedColors, "Star outlines retained selected coloring after deselection")
        print("PASS: Native selection/deselection updates metadata and star foregrounds")

        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action,
                  NSApp.sendAction(action, to: item.target, from: item) else {
                throw Failure(description: "Native column menu action did not dispatch")
            }
        }
        guard let sourceToggle = outline.headerView?.menu?.items.first(where: {
            ($0.representedObject as? NSTableColumn)?.identifier.rawValue == "source"
        }), let notesColumn = outline.tableColumns.first(where: { $0.identifier.rawValue == "notes" }) else {
            throw Failure(description: "Native column header menu is missing its source/notes controls")
        }
        notesColumn.width = 247
        let notesIndex = outline.tableColumns.firstIndex(of: notesColumn)!
        outline.moveColumn(notesIndex, toColumn: 1)
        try invoke(sourceToggle)
        let configuredOrder = outline.tableColumns.map { $0.identifier.rawValue }
        let restoredController = NativePaperTableController()
        restoredController.configure(configuration())
        guard let restoredOutline = descendants(restoredController.view).compactMap({ $0 as? NSOutlineView }).first else {
            throw Failure(description: "Restored table controller is missing its outline")
        }
        try expect(restoredOutline.tableColumns.map { $0.identifier.rawValue } == configuredOrder,
                   "Column order did not persist across table-controller reconstruction")
        try expect(restoredOutline.tableColumns.first { $0.identifier.rawValue == "source" }?.isHidden == true,
                   "Hidden column state did not persist across controller reconstruction")
        try expect(abs((restoredOutline.tableColumns.first { $0.identifier.rawValue == "notes" }?.width ?? 0) - 247) < 0.5,
                   "Resized column width did not persist across controller reconstruction")
        print("PASS: Column order, width and hidden state survive table-controller reconstruction")
        guard let reset = restoredOutline.headerView?.menu?.items.last else {
            throw Failure(description: "Missing native reset-column menu action")
        }
        try invoke(reset)

        try expect(restoredOutline.tableColumns.map { $0.identifier.rawValue } == expectedColumns.map { $0.0 },
                   "Reset Columns did not restore the default order")
        for (column, expected) in zip(restoredOutline.tableColumns, expectedColumns) {
            try expect(!column.isHidden && abs(column.width - expected.1) < 0.5,
                       "Reset Columns did not restore visibility and width for \(expected.0)")
        }
        for item in restoredOutline.headerView?.menu?.items ?? [] where item.representedObject is NSTableColumn {
            try expect(item.state == .on, "Reset Columns left a stale hidden-state checkmark")
        }
        print("PASS: Reset Columns restores widths, order, visibility and menu checkmarks")

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
            RunLoop.main.run(until: Date().addingTimeInterval(0.65))
            hosting.view.layoutSubtreeIfNeeded()
            guard let split = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first else {
                throw Failure(description: "The hosted representable did not create its native split view")
            }
            let splitRect = split.convert(split.bounds, to: hosting.view)
            let expectedRect = hosting.view.safeAreaRect
            if size.width == 1420 {
                print("MEASURE: first pane widths=\(split.arrangedSubviews.map { $0.frame.width })")
                try expect(abs((split.delegate as! NativeLibraryController).sidebarSplitView.arrangedSubviews[0].frame.width - 240) < 1 &&
                           abs(split.arrangedSubviews[1].frame.width - 320) < 1,
                           "The first native layout did not use the 240pt sidebar and 320pt inspector")
                print("PASS: First native layout uses the reference sidebar/inspector widths")
            }
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.65))
            let current = descendants(hosting.view).compactMap({ $0 as? NSSplitView }).first!
            try expect(current === hostedSplit, "Toggling a pane discarded the owned native split")
            try expect(1 + ((current.delegate as! NativeLibraryController).isSidebarCollapsed ? 0 : 1) + ((current.delegate as! NativeLibraryController).isInspectorCollapsed ? 0 : 1) == expectedPanes,
                       "Native sidebar/inspector collapsing did not match the bridge state")
            try expect(abs(current.frame.height - hosting.view.safeAreaRect.height) < 1,
                       "Collapsing a pane restored the stale fitting height")
        }
        print("PASS: Pane collapse/reopen preserves the native split and its full content height")

        let coordinator = NativeLibraryView.Coordinator()
        let bridgedController = coordinator.makeController(configuration(showInspector: true))
        let bridgedRoot = bridgedController.view
        try expect(coordinator.controller === bridgedController, "The coordinator lost its native controller")
        let nativeSidebarAction = NSSelectorFromString("toggleSidebar:")
        let previousToggleCount = state.sidebarToggleCount
        try expect(bridgedController.sidebarActionTarget.responds(to: nativeSidebarAction), "Missing standard native sidebar responder action")
        _ = bridgedController.sidebarActionTarget.perform(nativeSidebarAction, with: nil)
        try expect(state.sidebarToggleCount == previousToggleCount + 1 && !bridgedController.isSidebarCollapsed,
                   "The standard sidebar responder action did not delegate exactly once to SwiftUI visibility")
        print("PASS: Native toggleSidebar: responder action delegates once without independently collapsing the pane")
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
        print("PASS: SwiftUI selection bindings and focused-window search routing survive the new bridge")

        func searchHasFocus() -> Bool {
            bridgeWindow.firstResponder === search ||
                (search.currentEditor().map { bridgeWindow.firstResponder === $0 } ?? false)
        }
        state.search = "Preserved search"
        routing.update(configuration(showInspector: true, showSidebar: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        bridgeWindow.makeFirstResponder(routingTable)
        state.focusSearchToken += 1
        routing.update(configuration(showInspector: true, showSidebar: false))
        try expect(routingController.isPanelTransitionActive && !searchHasFocus(),
                   "Hidden-sidebar search focused an invisible field before its reveal completed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        try expect(!routingController.isSidebarCollapsed && !routingController.isInspectorCollapsed && searchHasFocus(),
                   "Search did not reveal its sidebar and focus the field after native motion")
        try expect(state.panelVisibilityChanges.last?.0 == true && state.panelVisibilityChanges.last?.1 == true &&
                   state.search == "Preserved search" && state.selection == [store.snapshot.papers[5].id],
                   "Search reveal lost scene visibility, query, selection or inspector state")

        routing.update(configuration(showInspector: true, showSidebar: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        bridgeWindow.makeFirstResponder(routingTable)
        state.focusSearchToken += 1
        routing.update(configuration(showInspector: true, showSidebar: false))
        // A subsequent user hide must cancel the pending focus, even though
        // AppKit is still finishing the first reveal animation.
        routing.update(configuration(showInspector: true, showSidebar: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        try expect(routingController.isSidebarCollapsed && !routingController.isPanelTransitionActive && !searchHasFocus(),
                   "A cancelled search reveal later reopened or focused the hidden sidebar")
        print("PASS: Search reveals before focusing, preserves context and cancels stale focus after a newer hide")
        routing.dismantle(routingController)

        let clipboard = NSPasteboard.general
        let preservedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            clipboard.clearContents()
            let items = preservedClipboard.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }
        let selected = store.snapshot.papers[0]
        state.selection = [selected.id]
        controller.configure(configuration())
        let copying = PaperDraftSession(autosaveDelayNanoseconds: 10_000_000_000)
        copying.select(selected.id, in: store)
        var draft = copying.draft; draft.title = "Draft copied before debounce"
        copying.edit(draft)
        _ = controller.perform(NSSelectorFromString("copyBibTeX"))
        try expect(clipboard.string(forType: .string)?.contains("Draft copied before debounce") == true &&
                   store.paper(with: selected.id)?.title == draft.title, "Copy BibTeX used a stale configuration snapshot or lost a pending draft")
        draft = copying.draft; draft.title = "Second pending RIS draft"; copying.edit(draft)
        _ = controller.perform(NSSelectorFromString("copyRIS"))
        try expect(clipboard.string(forType: .string)?.contains("Second pending RIS draft") == true,
                   "Copy RIS did not flush and serialize the latest committed paper")
        print("PASS: Native Copy BibTeX/RIS flush pending drafts and read latest store data")

        let savedCopyPath = store.persistenceURL.appendingPathExtension("copy-preserved")
        try FileManager.default.moveItem(at: store.persistenceURL, to: savedCopyPath)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        do {
            defer {
                try? FileManager.default.removeItem(at: store.persistenceURL)
                try? FileManager.default.moveItem(at: savedCopyPath, to: store.persistenceURL)
            }
            draft = copying.draft; draft.title = "Unsaved must not replace clipboard"; copying.edit(draft)
            clipboard.clearContents(); clipboard.setString("Keep clipboard on failed save", forType: .string)
            _ = controller.perform(NSSelectorFromString("copyBibTeX"))
            _ = controller.perform(NSSelectorFromString("copyRIS"))
            try expect(clipboard.string(forType: .string) == "Keep clipboard on failed save" && copying.saveError != nil,
                       "Copy changed the clipboard after a rejected draft write")
        }
        try expect(copying.flush(), "Copy draft did not survive the failed write for retry")
        print("PASS: Failed draft persistence blocks both native Copy actions and retains clipboard/draft")

        let primaryURL = root.appendingPathComponent("menu-primary.pdf"), secondaryURL = root.appendingPathComponent("menu-secondary.txt")
        let primaryBytes = Data("Synthetic primary bytes".utf8), secondaryBytes = Data("Synthetic attachment bytes".utf8)
        try primaryBytes.write(to: primaryURL); try secondaryBytes.write(to: secondaryURL)
        var withFiles = store.paper(with: selected.id)!
        let primary = Attachment(kind: .pdf, filePath: primaryURL.path, displayName: "primary.pdf")
        let secondary = Attachment(kind: .file, filePath: secondaryURL.path, displayName: "secondary.txt")
        withFiles.attachments = [primary, secondary]; try store.updatePaperDurably(withFiles)
        let commands = NativePaperSelectionCommands()
        var attachedConfiguration = configuration(); attachedConfiguration.selectionCommands = commands
        controller.configure(attachedConfiguration)
        outline.expandItem(outline.item(atRow: 0))
        outline.selectRowIndexes([3], byExtendingSelection: false)
        outline.selectRowIndexes([1], byExtendingSelection: true)
        guard let nativeOutline = outline as? LibraryOutlineView,
              let mixedMenu = nativeOutline.menuProvider?() else {
            throw Failure(description: "The selected table did not expose its real context menu")
        }
        try expect(mixedMenu.items.last?.title == PMLocalization.text("删除记录"),
                   "Mixed paper/attachment selection advertised link removal even though its action deletes paper records")
        let beforeMixedDelete = state.deleteCalls
        try expect(commands.perform(.delete) && state.deleteCalls == beforeMixedDelete + 1 &&
                   store.paper(with: selected.id)?.attachments.count == 2,
                   "Mixed selection's advertised paper-delete command did not retain its existing callback")
        print("PASS: Mixed paper/attachment selection labels its destructive context action as Delete Records")
        outline.selectRowIndexes([2], byExtendingSelection: false)
        try expect(nativeOutline.menuProvider?()?.items.last?.title == PMLocalization.text("移除附件链接"),
                   "An attachment-only selection no longer advertised safe link removal")
        let beforeDeleteCalls = state.deleteCalls
        try expect(commands.perform(.delete), "Application menu command did not reach the native selection")
        try expect(store.paper(with: selected.id)?.attachments.map(\.id) == [primary.id] && state.deleteCalls == beforeDeleteCalls,
                   "Deleting an attachment from the application menu deleted its parent record")
        try expect(try Data(contentsOf: primaryURL) == primaryBytes && Data(contentsOf: secondaryURL) == secondaryBytes,
                   "Removing an attachment link changed source bytes")
        controller.configure(attachedConfiguration)
        outline.selectRowIndexes([0], byExtendingSelection: false)
        try expect(commands.perform(.delete) && state.deleteCalls == beforeDeleteCalls + 1,
                   "Parent menu deletion did not keep the existing paper callback")
        try expect(!NativePaperSelectionCommands().perform(.delete), "An unattached window router accepted a command")
        print("PASS: Application menu selection routing removes only selected attachment links and preserves parent commands")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// Exercise actual NSOutlineView layout without activation, real mouse
    /// events, the user's files, or unrelated animated-panel requirements.
    private static func verifyAttachmentExpansionGeometry(store: LibraryStore, root: URL,
        controller: NativePaperTableController, outline: NSOutlineView, window: NSWindow,
        configure: () -> Void) throws {
        let original = store.snapshot.papers[0]
        let oldWidths = outline.tableColumns.map(\.width)
        let oldSize = window.contentView!.bounds.size
        let pdf = root.appendingPathComponent("expansion-fixture.pdf")
        let text = root.appendingPathComponent("expansion-fixture.txt")
        try Data("Owned expansion PDF bytes".utf8).write(to: pdf)
        try Data("Owned expansion attachment bytes".utf8).write(to: text)
        var attached = original
        attached.attachments = [Attachment(kind: .pdf, filePath: pdf.path, displayName: "expansion.pdf"),
                                Attachment(kind: .file, filePath: text.path, displayName: "expansion.txt")]
        try store.updatePaperDurably(attached)
        configure()
        defer {
            outline.collapseItem(nil, collapseChildren: true)
            try? store.updatePaperDurably(original)
            configure()
            for (column, width) in zip(outline.tableColumns, oldWidths) { column.width = width }
            outline.enclosingScrollView?.contentView.scroll(to: .zero)
            window.setContentSize(oldSize)
            controller.view.layoutSubtreeIfNeeded()
        }
        guard let parent = outline.item(atRow: 0), let nextParent = outline.item(atRow: 1),
              let titleIndex = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }),
              let authorIndex = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "authors" }),
              let scroll = outline.enclosingScrollView else { throw Failure(description: "Missing attachment expansion fixture") }
        outline.tableColumns[titleIndex].width = 386
        outline.tableColumns[authorIndex].width = 211
        window.setContentSize(NSSize(width: 700, height: 300))
        controller.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let requestedWidths = outline.tableColumns.map(\.width)
        let offset = scroll.contentView.bounds.minX
        try expect(offset > 100, "Attachment expansion fixture did not establish horizontal overflow")
        var stages: [[String: Any]] = []
        var failures: [String] = []
        var parentHeight: CGFloat?
        var childCellIndent: CGFloat?
        var childTextIndent: CGFloat?
        var attachmentItem: Any?
        for (stage, expanded) in [("before", false), ("expanded1", true), ("collapsed1", false),
                                  ("expanded2", true), ("collapsed2", false)] {
            if expanded { outline.expandItem(parent) } else { outline.collapseItem(parent) }
            controller.view.layoutSubtreeIfNeeded()
            let row = outline.row(forItem: parent)
            let nextRow = outline.row(forItem: nextParent)
            let parentRect = outline.rect(ofRow: row)
            guard let parentCell = outline.view(atColumn: titleIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let parentText = parentCell.textField else { throw Failure(description: "Missing native expansion parent title") }
            parentCell.layoutSubtreeIfNeeded()
            let parentCellX = parentCell.convert(parentCell.bounds, to: outline).minX
            let parentTextX = parentText.convert(parentText.bounds, to: outline).minX
            let widths = outline.tableColumns.map(\.width)
            var measurement: [String: Any] = ["stage": stage, "expanded": expanded, "rows": outline.numberOfRows,
                "widths": Dictionary(uniqueKeysWithValues: zip(outline.tableColumns.map { $0.identifier.rawValue }, widths.map(Double.init))),
                "horizontalOffset": Double(scroll.contentView.bounds.minX), "parentHeight": Double(parentRect.height),
                "nextParentHeight": Double(outline.rect(ofRow: nextRow).height), "nextParentRow": nextRow,
                "parentCellX": Double(parentCellX), "parentTextX": Double(parentTextX),
                "authorColumnX": Double(outline.rect(ofColumn: authorIndex).minX)]
            if let header = outline.headerView {
                measurement["authorHeaderXInWindow"] = Double(header.convert(header.headerRect(ofColumn: authorIndex), to: nil).minX)
            }
            if expanded {
                guard let child = outline.item(atRow: row + 1),
                      let childCell = outline.view(atColumn: titleIndex, row: row + 1, makeIfNecessary: true) as? NSTableCellView,
                      let childText = childCell.textField else { throw Failure(description: "Expanded attachment row was absent") }
                childCell.layoutSubtreeIfNeeded()
                let cellIndent = childCell.convert(childCell.bounds, to: outline).minX - parentCellX
                let textIndent = childText.convert(childText.bounds, to: outline).minX - parentTextX
                measurement["attachmentLevel"] = outline.level(forItem: child)
                measurement["attachmentCellIndent"] = Double(cellIndent)
                measurement["attachmentTextIndent"] = Double(textIndent)
                attachmentItem = child
                if outline.level(forItem: child) != 1 || abs(cellIndent - outline.indentationPerLevel) > 0.5 {
                    failures.append("\(stage): child attachment lost its single native indentation level")
                }
                if let childCellIndent, abs(childCellIndent - cellIndent) > 0.5 { failures.append("Repeated expansion changed attachment cell indentation") }
                if let childTextIndent, abs(childTextIndent - textIndent) > 0.5 { failures.append("Repeated expansion changed attachment text indentation") }
                if abs(textIndent - outline.indentationPerLevel) > 0.5 { failures.append("\(stage): attachment text indentation differs from its native14pt hierarchy depth") }
                childCellIndent = cellIndent; childTextIndent = textIndent
            }
            if !zip(widths, requestedWidths).allSatisfy({ abs($0 - $1) < 0.5 }) { failures.append("\(stage): attachment disclosure changed manually resized column widths") }
            if abs(scroll.contentView.bounds.minX - offset) > 0.5 { failures.append("\(stage): attachment disclosure changed horizontal scroll position") }
            if let parentHeight, abs(parentHeight - parentRect.height) > 0.5 { failures.append("\(stage): attachment disclosure changed parent row height") }
            parentHeight = parentRect.height
            if abs(outline.rect(ofRow: nextRow).height - parentRect.height) > 0.5 { failures.append("\(stage): adjacent parent row height changed") }
            if nextRow != (expanded ? 3 : 1) { failures.append("\(stage): disclosure did not add/remove exactly two child rows") }
            print("EXPANSION: \(measurement)")
            stages.append(measurement)
        }
        guard let attachmentItem else { throw Failure(description: "No child item for the attachment reuse probe") }
        let reuseOutline = ReuseProbeOutline()
        let titleColumn = outline.tableColumns[titleIndex]
        func cellInsets(_ cell: NSTableCellView) -> [String: Double] {
            cell.frame = NSRect(x: 0, y: 0, width: 300, height: 27)
            cell.needsLayout = true
            cell.layoutSubtreeIfNeeded()
            return ["imageX": Double(cell.imageView?.frame.minX ?? -1),
                    "textX": Double(cell.textField?.frame.minX ?? -1)]
        }
        guard let freshChild = controller.outlineView(reuseOutline, viewFor: titleColumn, item: attachmentItem) as? NSTableCellView,
              let recycledParent = controller.outlineView(reuseOutline, viewFor: titleColumn, item: parent) as? NSTableCellView else {
            throw Failure(description: "Production delegate did not supply cells to the owned reuse probe")
        }
        let freshInsets = cellInsets(freshChild)
        let parentInsets = cellInsets(recycledParent)
        reuseOutline.recycledCell = recycledParent
        guard let reusedChild = controller.outlineView(reuseOutline, viewFor: titleColumn, item: attachmentItem) as? NSTableCellView,
              reusedChild === recycledParent else { throw Failure(description: "Attachment probe did not actually reuse the parent title cell") }
        let reusedInsets = cellInsets(reusedChild)
        let reuseMeasurement: [String: Any] = ["stage": "controlledParentToAttachmentReuse", "freshAttachment": freshInsets,
            "parentTitle": parentInsets, "reusedAttachment": reusedInsets, "sameObjectReused": true]
        stages.append(reuseMeasurement)
        print("EXPANSION REUSE: \(reuseMeasurement)")
        if freshInsets != reusedInsets || freshInsets != parentInsets {
            failures.append("Fresh and recycled attachment title cells do not share the parent's symbol/text inset")
        }
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_TABLE_EXPANSION_REPORT"] {
            let payload: [String: Any] = ["ok": failures.isEmpty, "failures": failures,
                "autoresizesOutlineColumn": outline.autoresizesOutlineColumn, "stages": stages]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS: Attachment disclosure preserves manual column widths, horizontal position, parent heights and child indentation")
    }
}
