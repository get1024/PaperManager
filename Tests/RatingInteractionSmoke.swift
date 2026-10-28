import AppKit
import Darwin
import SwiftUI

/// Owns an entirely synthetic library. Events are delivered directly to the
/// production controls; this fixture never moves the system pointer, posts
/// system events, or opens the user's library. Its owned window becomes key so
/// the production hover lifecycle is exercised without weakening its guards.
@MainActor
private struct RatingFixtureRoot: View {
    @ObservedObject var store: LibraryStore
    @State var selection: Set<UUID>
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var includeSubcollections = true
    @State private var sort = PaperSortDescriptor()

    var body: some View {
        NativeLibraryView(store: store, papers: store.snapshot.papers,
            selectedFilter: $filter, selection: $selection, searchText: $search,
            includeSubcollections: $includeSubcollections, sortDescriptor: $sort,
            showSidebar: false, showInspector: true, focusSearchToken: 0,
            onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
            onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {})
            .environment(\.colorScheme, .light)
            .preferredColorScheme(.light)
    }
}

@main
@MainActor
private struct RatingInteractionSmoke: App {
    @NSApplicationDelegateAdaptor(RatingFixtureDelegate.self) private var delegate
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            Text("Preparing owned rating fixture…")
                .frame(width: 320, height: 80)
                .onAppear {
                    guard !started else { return }
                    started = true
                    Task { @MainActor in await RatingInteractionChecks.executeAndFinish() }
                }
        }
    }
}

@MainActor
private final class RatingFixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        setbuf(stdout, nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("FAIL: Rating interaction fixture exceeded its 20-second deadline\n", stderr)
            exit(3)
        }
    }
}

@MainActor
private enum RatingInteractionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var results: [[String: Any]] = []
    private static let output = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["PAPERMANAGER_RATING_REPORT"] ??
        ".build/test-results/rating-interactions/report.json")

    static func executeAndFinish() async {
        do {
            try await run()
        } catch {
            record("Fixture completed", false, details: ["error": String(describing: error)])
        }
        do { try finish() }
        catch { fputs("Cannot write rating interaction report: \(error)\n", stderr); exit(2) }
        exit(results.contains { $0["passed"] as? Bool != true } ? 1 : 0)
    }

    private static func expect(_ name: String, _ condition: @autoclosure () throws -> Bool,
                               details: [String: Any] = [:]) throws {
        let passed = try condition()
        record(name, passed, details: details)
        if !passed { throw Failure(description: name) }
    }

    private static func record(_ name: String, _ passed: Bool, details: [String: Any] = [:]) {
        var row = details
        row["name"] = name
        row["passed"] = passed
        results.append(row)
        print("\(passed ? "PASS" : "FAIL"): \(name)")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func settle(_ duration: TimeInterval = 0.03) async {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    private static func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 0.25) async -> TimeInterval {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout { await settle(0.005) }
        return Date().timeIntervalSince(start)
    }

    private static func event(_ type: NSEvent.EventType, in control: NativeStarRatingControl,
                              star: Int) -> NSEvent {
        let point = control.convert(NSPoint(x: control.bounds.width * (CGFloat(star) - 0.5) / 5,
                                            y: control.bounds.midY), to: nil)
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: control.window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: control.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: type == .leftMouseDown ? 1 : 0, pressure: 0)!
    }

    private static func move(_ control: NativeStarRatingControl, to star: Int) {
        control.mouseMoved(with: event(.mouseMoved, in: control, star: star))
    }

    private static func leave(_ control: NativeStarRatingControl) {
        control.mouseExited(with: event(.mouseExited, in: control, star: 1))
    }

    private static func click(_ control: NativeStarRatingControl, star: Int) {
        control.mouseDown(with: event(.leftMouseDown, in: control, star: star))
    }

    private static func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(description: "Could not allocate \(name) screenshot")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Could not encode \(name) screenshot")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output.deletingLastPathComponent().appendingPathComponent("\(name).png"), options: .atomic)
    }

    private static func run() async throws {
        let preferenceKeys = ["PaperManager.NativePaperColumnLayout", "PaperManager.NativePaperColumnLayout.v2",
            "PaperManager.NativeLibraryPaneWidths", "NSTableView Columns PaperManager.NativePaperColumns",
            "NSSplitView Subview Frames PaperManager.NativeLibrarySplit"]
        let previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        preferenceKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer {
            for key in preferenceKeys {
                if let previous = previousPreferences[key] { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerRating-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = LibraryStore(persistenceURL: temporary.appendingPathComponent("library.json"))
        var paper = Paper()
        paper.title = "Rating interaction fixture"
        paper.authors = ["Synthetic Author"]
        paper.year = 2026
        paper.journal = "Owned test library"
        paper.rating = 2
        paper.notes = "No user library, global pointer movement or posted system events."
        var library = LibrarySnapshot.empty
        library.papers = [paper]
        try store.replaceSnapshotDurably(library)
        let host = NSHostingView(rootView: RatingFixtureRoot(store: store, selection: [paper.id]))
        host.frame = NSRect(x: 0, y: 0, width: 1540, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "PaperManager Rating Interaction Fixture"
        window.contentView = host
        defer { window.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = await waitFor({ window.isKeyWindow && NSApp.isActive }, timeout: 1)
        try expect("Owned fixture is active and key for production hover guards", window.isKeyWindow && NSApp.isActive,
            details: ["isKey": window.isKeyWindow, "canBecomeKey": window.canBecomeKey,
                      "appActive": NSApp.isActive, "processPID": ProcessInfo.processInfo.processIdentifier,
                      "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0])
        host.layoutSubtreeIfNeeded()
        await settle(0.2)

        guard let outline = descendants(host).compactMap({ $0 as? NSOutlineView }).first,
              let ratingColumn = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "rating" }),
              let cell = outline.view(atColumn: ratingColumn, row: 0, makeIfNecessary: true) as? NativeRatingCell else {
            throw Failure(description: "Combined fixture did not create its production rating cell")
        }
        cell.layoutSubtreeIfNeeded()
        func controls() -> (NativeStarRatingControl, NativeStarRatingControl)? {
            guard let currentCell = outline.view(atColumn: ratingColumn, row: 0, makeIfNecessary: true) as? NativeRatingCell,
                  let inspector = descendants(host).compactMap({ $0 as? NativeStarRatingControl }).first(where: {
                      $0.enclosingScrollView?.documentView !== outline && $0 !== currentCell.ratingControl
                  }) else { return nil }
            return (currentCell.ratingControl, inspector)
        }
        _ = await waitFor { controls() != nil }
        guard let (list, inspector) = controls() else {
            throw Failure(description: "Combined fixture did not create its inspector's native rating control")
        }
        try expect("Real table and inspector mount separate controls for one rating",
            list !== inspector && list.rating == 2 && inspector.rating == 2)
        try snapshot(host, name: "01-initial")

        let initialBytes = try Data(contentsOf: store.persistenceURL)
        for (name, control) in [("Table", list), ("Inspector", inspector)] {
            control.mouseEntered(with: event(.mouseEntered, in: control, star: 1))
            for value in 1...5 {
                move(control, to: value)
                try expect("\(name) previews star \(value) without changing its saved or accessible value",
                    control.hoveredRating == value && control.displayedRating == value && control.rating == 2 &&
                    (control.accessibilityValue() as? NSNumber)?.intValue == 2 && store.paper(with: paper.id)?.rating == 2)
            }
            leave(control)
            try expect("\(name) exit restores the persisted stars", control.hoveredRating == nil && control.displayedRating == 2)
        }
        try expect("Hover never writes library bytes", try Data(contentsOf: store.persistenceURL) == initialBytes)
        move(list, to: 5)
        move(inspector, to: 1)
        try expect("List and inspector hover previews remain independent",
            list.displayedRating == 5 && inspector.displayedRating == 1 && list.rating == inspector.rating)
        await settle(0.12)
        try snapshot(host, name: "02-independent-hover")
        leave(list); leave(inspector)

        func diskRating() throws -> Int? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: store.persistenceURL))
                .papers.first(where: { $0.id == paper.id })?.rating
        }
        func surfacesMatch(_ value: Int) -> Bool {
            controls().map { $0.0.rating == value && $0.1.rating == value } ?? false
        }
        click(list, star: 4)
        try expect("Table click synchronously publishes and persists its rating",
            store.paper(with: paper.id)?.rating == 4 && diskRating() == 4)
        let tableToInspector = await waitFor { surfacesMatch(4) }
        try expect("Table click updates inspector before the 450ms metadata debounce", surfacesMatch(4),
                   details: ["renderLatencyMilliseconds": tableToInspector * 1000])
        guard let (_, updatedInspector) = controls() else { throw Failure(description: "Lost inspector after table click") }
        click(updatedInspector, star: 1)
        try expect("Inspector click synchronously publishes and persists its rating",
            store.paper(with: paper.id)?.rating == 1 && diskRating() == 1)
        let inspectorToTable = await waitFor { surfacesMatch(1) }
        try expect("Inspector click updates table before the 450ms metadata debounce", surfacesMatch(1),
                   details: ["renderLatencyMilliseconds": inspectorToTable * 1000])
        guard let (_, sameStarInspector) = controls() else { throw Failure(description: "Lost inspector after inspector click") }
        click(sameStarInspector, star: 1)
        try expect("Clicking the persisted inspector star clears the rating immediately",
            store.paper(with: paper.id)?.rating == 0 && diskRating() == 0)
        _ = await waitFor { surfacesMatch(0) }
        try expect("Cleared rating propagates to both surfaces", surfacesMatch(0))
        try expect("External store rating update succeeds", store.updateRating(3, for: paper.id))
        _ = await waitFor { surfacesMatch(3) }
        try expect("External rating publication updates both surfaces", surfacesMatch(3))
        try snapshot(host, name: "03-synchronized")

        guard let keyboardControls = controls() else { throw Failure(description: "Lost controls before keyboard test") }
        try expect("Table rating accepts native first responder", window.makeFirstResponder(keyboardControls.0))
        move(keyboardControls.0, to: 2)
        try expect("Keyboard fixture begins with a different pointer preview", keyboardControls.0.hoveredRating == 2 && keyboardControls.0.rating == 3)
        for (keyCode, characters, expected) in [(UInt16(124), "\u{F703}", 4), (UInt16(124), "\u{F703}", 5),
                                                (UInt16(123), "\u{F702}", 4), (UInt16(51), "\u{7F}", 0)] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            window.sendEvent(key)
            _ = await waitFor { surfacesMatch(expected) }
            try expect("Window-routed rating key \(keyCode) commits \(expected) and retains rating focus",
                surfacesMatch(expected) && diskRating() == expected && window.firstResponder is NativeStarRatingControl,
                details: ["storeRating": store.paper(with: paper.id)?.rating ?? -1,
                    "tableRating": controls()?.0.rating ?? -1, "inspectorRating": controls()?.1.rating ?? -1,
                    "firstResponder": String(describing: window.firstResponder),
                    "firstResponderAttached": (window.firstResponder as? NSView)?.window === window])
            try expect("Keyboard rating command reveals its committed value instead of stale hover",
                (window.firstResponder as? NativeStarRatingControl).map { $0.hoveredRating == nil && $0.displayedRating == expected } == true)
        }
        try expect("Reset rating after keyboard test", store.updateRating(3, for: paper.id))
        _ = await waitFor { surfacesMatch(3) }

        let preserved = store.persistenceURL.appendingPathExtension("preserved")
        let baseline = try Data(contentsOf: store.persistenceURL)
        try FileManager.default.moveItem(at: store.persistenceURL, to: preserved)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        var blocked = true
        defer {
            if blocked {
                try? FileManager.default.removeItem(at: store.persistenceURL)
                try? FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
            }
        }
        for surface in 0...1 {
            guard let pair = controls() else { throw Failure(description: "Lost controls before failed save") }
            click(surface == 0 ? pair.0 : pair.1, star: 5)
            _ = await waitFor { surfacesMatch(3) }
            try expect("\(surface == 0 ? "Table" : "Inspector") failed save restores both committed rating values",
                surfacesMatch(3) && store.paper(with: paper.id)?.rating == 3 && store.statusMessage?.isEmpty == false)
            try expect("Failed save preserves last durable library bytes", try Data(contentsOf: preserved) == baseline)
        }
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
        blocked = false
        guard let recovered = controls() else { throw Failure(description: "Lost controls after disk recovery") }
        click(recovered.1, star: 4)
        _ = await waitFor { surfacesMatch(4) }
        try expect("Rating clicks recover after persistence is writable again", surfacesMatch(4) && diskRating() == 4)

        try await testLifecycleAndClipping()
    }

    private static func testLifecycleAndClipping() async throws {
        let probe = NativeStarRatingControl()
        probe.frame = NSRect(x: 0, y: 0, width: 76, height: 25)
        let window = NSWindow(contentRect: probe.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        _ = await waitFor { window.isKeyWindow && NSApp.isActive }
        try expect("Lifecycle fixture is active and key", window.isKeyWindow && NSApp.isActive)
        var changes: [Int] = []
        let identity = UUID()
        probe.configure(rating: 2, identity: identity, onChange: { changes.append($0) })
        move(probe, to: 4)
        probe.configure(rating: 3, identity: identity, onChange: { changes.append($0) })
        try expect("Reconfiguring the same record retains its valid local hover", probe.hoveredRating == 4 && probe.rating == 3)
        probe.configure(rating: 1, identity: UUID(), onChange: { changes.append($0) })
        try expect("Reusing a rating control for a different record clears hover", probe.hoveredRating == nil && probe.displayedRating == 1)
        move(probe, to: 5)
        probe.isEnabled = false
        move(probe, to: 2)
        click(probe, star: 3)
        try expect("Disabling clears preview and rejects pointer changes", probe.hoveredRating == nil && probe.rating == 1 && changes.isEmpty)
        probe.isEnabled = true
        move(probe, to: 3)
        probe.viewWillMove(toWindow: nil)
        try expect("Detaching a rating control clears hover", probe.hoveredRating == nil)
        click(probe, star: 1)
        try expect("Clicking the persisted table star clears the rating", probe.rating == 0 && changes == [0])

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 31, height: 25))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 25))
        scroll.documentView = document
        window.contentView = scroll
        window.setContentSize(NSSize(width: 31, height: 25))
        probe.frame = document.bounds
        probe.autoresizingMask = []
        document.addSubview(probe)
        scroll.layoutSubtreeIfNeeded()
        probe.updateTrackingAreas()
        let clipped = probe.bounds.intersection(probe.visibleRect)
        try expect("Tracking rectangles are bounded by the clipped star control",
            !clipped.isEmpty && clipped.width < probe.bounds.width && probe.trackingAreas.count == 1 &&
            probe.trackingAreas[0].rect == clipped && !probe.trackingAreas[0].options.contains(.inVisibleRect),
            details: ["bounds": NSStringFromRect(probe.bounds), "visibleRect": NSStringFromRect(probe.visibleRect),
                "scrollFrame": NSStringFromRect(scroll.frame), "clipBounds": NSStringFromRect(scroll.contentView.bounds),
                "trackingRects": probe.trackingAreas.map { NSStringFromRect($0.rect) }])
        move(probe, to: 2)
        try expect("A visible clipped star still previews", probe.hoveredRating == 2)
        move(probe, to: 5)
        try expect("Clipped-away stars cannot retain a hover preview", probe.hoveredRating == nil)
        probe.removeFromSuperview()
        try expect("Removing a clipped rating control clears all preview state", probe.hoveredRating == nil)

        let accessible = NativeStarRatingControl()
        var accessibleChanges: [Int] = []
        accessible.configure(rating: 2, onChange: { accessibleChanges.append($0) })
        move(accessible, to: 1)
        try expect("AX increment clears a conflicting pointer preview",
            accessible.accessibilityPerformIncrement() && accessible.rating == 3 && accessible.hoveredRating == nil)
        move(accessible, to: 5)
        try expect("AX decrement clears a conflicting pointer preview",
            accessible.accessibilityPerformDecrement() && accessible.rating == 2 && accessible.hoveredRating == nil)
        move(accessible, to: 1)
        accessible.setAccessibilityValue(NSNumber(value: 4))
        try expect("AX set value reveals committed stars and calls the shared change path",
            accessible.displayedRating == 4 && accessible.hoveredRating == nil && accessibleChanges == [3, 2, 4])
    }

    private static func finish() throws {
        let failed = results.filter { $0["passed"] as? Bool != true }.count
        let report: [String: Any] = ["passed": results.count - failed, "failed": failed, "results": results,
            "scope": "Active owned NSWindow hosting the production combined native table and SwiftUI inspector with a synthetic temporary library. Locally constructed events call production handlers directly without moving the system pointer or posting system events. Screenshots are view-cache renders; this does not establish physical-pointer or system event delivery."]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("Rating interactions: \(results.count - failed) passed, \(failed) failed")
    }
}
