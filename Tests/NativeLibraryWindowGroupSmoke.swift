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
                .ignoresSafeArea(.container, edges: .top)
                .background(WindowChromeConfigurator { window in
                    window.titleVisibility = .visible
                    window.titlebarAppearsTransparent = true
                    window.toolbarStyle = .unified
                    window.styleMask.insert(.fullSizeContentView)
                    window.isMovableByWindowBackground = false
                    window.contentMinSize = NSSize(width: 1080, height: 680)
                })
                .navigationTitle("Owned WindowGroup fixture")
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Label("Add \(fixture.toolbarRevision)", systemImage: "plus")
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
        // The settled mode permits at most two seconds per stage plus setup.
        let deadline: Double = ProcessInfo.processInfo.environment["PAPERMANAGER_WINDOW_GROUP_SETTLED"] == "1" ? 75 : 30
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            fputs("WindowGroup fixture exceeded its process deadline\n", stderr)
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
    @Published var toolbarRevision = 0
    private var started = false
    private var splitIdentity: ObjectIdentifier?
    private var stages: [[String: Any]] = []
    private var failures: [String] = []
    private var motionSamples: [[String: Any]] = []
    private var currentStep = -1
    private var stepStartedAt: [Int: TimeInterval] = [:]
    private var step20OriginalUnsettled = false
    private var step20Diagnostics: [[String: Any]] = []
    private let frontmostMode = ProcessInfo.processInfo.environment["PAPERMANAGER_WINDOW_GROUP_FRONTMOST"] == "1"
    private let settledMode = ProcessInfo.processInfo.environment["PAPERMANAGER_WINDOW_GROUP_SETTLED"] == "1"
    private weak var ownedMainWindow: NSWindow?
    private var foregroundReady = false
    private var completedMotionSteps: Set<Int> = []
    private var timingSnapshots: [[String: Any]] = []
    private var closedTransitionController: NativeLibraryController?
    private var selectedPaneBaseline: [CGFloat]?
    private var previousPanePreferences: [String: Any] = [:]

    init() {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"], path.hasPrefix("/") else {
            fatalError("The fixture requires an explicit owned library path")
        }
        for key in ["PaperManager.NativeLibraryPaneWidths", "NSSplitView Subview Frames PaperManager.NativeLibrarySplit"] {
            if let value = UserDefaults.standard.object(forKey: key) { previousPanePreferences[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        if ProcessInfo.processInfo.environment["PAPERMANAGER_STALE_SPLIT_AUTOSAVE"] == "1" {
            UserDefaults.standard.set(["sidebar": 240, "inspector": 320], forKey: "PaperManager.NativeLibraryPaneWidths")
            UserDefaults.standard.set([
                "0.000000, 0.000000, 200.000000, 948.000000, NO, NO",
                "200.000000, 0.000000, 1099.000000, 948.000000, NO, NO",
                "1300.000000, 0.000000, 460.000000, 948.000000, NO, NO"
            ], forKey: "NSSplitView Subview Frames PaperManager.NativeLibrarySplit")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path), metadataLookup: { paper in
            if paper.title.hasPrefix("Footer completion fixture") {
                return PaperMetadata(title: paper.title)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return PaperMetadata(title: paper.title)
        })
        var snapshot = LibrarySnapshot.empty
        snapshot.papers = (0..<72).map { index in
            var paper = Paper(); paper.title = "WindowGroup fixture \(index)"
            paper.authors = ["Synthetic Author"]; paper.year = 2026; paper.rating = 2
            return paper
        }
        let collection = PaperCollection(name: "多模态基础模型与 LLM")
        let segment = PaperTag(name: "Segment", colorHex: "#FF9500")
        let architecture = PaperTag(name: "预训练/基础架构", colorHex: "#8E8E93")
        snapshot.collections = [collection]
        snapshot.tags = [segment, architecture] + (0..<48).map {
            PaperTag(name: "Footer overflow tag \($0)", colorHex: "#8E8E93")
        }
        snapshot.papers[47].title = "INSID3: Training-Free In-Context Segmentation with DINOv3"
        snapshot.papers[47].authors = ["Claudia Cuttano", "Gabriele Trivigno", "Christoph Reich", "Daniel Cremers", "Carlo Masone", "Stefan Roth"]
        snapshot.papers[47].paperType = .preprint
        snapshot.papers[47].journal = "arXiv"
        snapshot.papers[47].doi = "10.48550/arXiv.2603.28480"
        snapshot.papers[47].url = "https://arxiv.org/abs/2603.28480"
        snapshot.papers[47].eprint = "2603.28480"
        snapshot.papers[47].eprintClass = "cs.CV"
        snapshot.papers[47].eprintType = "arxiv"
        snapshot.papers[47].collectionIDs = [collection.id]
        snapshot.papers[47].tagIDs = [segment.id, architecture.id]
        snapshot.papers[47].abstract = "In-context segmentation (ICS) aims to segment arbitrary concepts, e.g., objects, parts, or personalized instances, given one annotated visual example. Existing work relies on fine-tuning vision foundation models, which improves in-domain results but harms generalization, or combines multiple frozen models. We revisit ICS from a minimalist perspective and ask whether a single self-supervised backbone can support semantic matching and segmentation without supervision or auxiliary models. Dense self-supervised features exhibit strong spatial structure and semantic correspondence, and the approach segments concepts at varying granularities from an in-context example."
        try! store.replaceSnapshotDurably(snapshot)
    }

    var libraryView: some View { configuration() }

    private func configuration(sidebar: Bool? = nil, inspector: Bool? = nil) -> NativeLibraryView {
        NativeLibraryView(store: store, papers: store.snapshot.papers,
            selectedFilter: Binding(get: { self.filter }, set: { self.filter = $0 }),
            selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
            searchText: Binding(get: { self.search }, set: { self.search = $0 }),
            includeSubcollections: Binding(get: { self.includeSubcollections }, set: { self.includeSubcollections = $0 }),
            sortDescriptor: Binding(get: { self.sort }, set: { self.sort = $0 }),
            showSidebar: sidebar ?? showSidebar, showInspector: inspector ?? showInspector, focusSearchToken: 0,
            onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
            onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {},
            onToggleSidebar: { self.showSidebar.toggle() },
            onPanelVisibilityChanged: { self.showSidebar = $0; self.showInspector = $1 })
    }

    func start() {
        guard !started else { return }; started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.runStep(0) }
    }

    private func runStep(_ index: Int) {
        guard let window = ownedMainWindow ?? NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width >= 1000 }) else {
            failures.append("No fixture WindowGroup window"); finish(); return
        }
        ownedMainWindow = window
        if frontmostMode, !foregroundReady {
            window.level = .normal
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            awaitForegroundReadiness(window, deadline: Date().timeIntervalSince1970 + 2)
            return
        }
        currentStep = index
        stepStartedAt[index] = Date().timeIntervalSince1970
        if frontmostMode {
            window.level = .normal
        } else {
            window.level = NSWindow.Level(rawValue: -1000)
            window.orderBack(nil)
        }
        switch index {
        case 0: window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1420, height: 860)), display: false)
        case 1: window.setContentSize(NSSize(width: 1080, height: 680))
        case 2: window.setContentSize(NSSize(width: 1760, height: 1000))
        case 3: showSidebar = false
        case 4: showSidebar = true; showInspector = false
        case 5: showSidebar = false
        case 6: showSidebar = true; showInspector = true
        case 7: selection = [store.snapshot.papers[47].id]
        case 8: selection = []
        case 9: toolbarRevision += 1
        case 10: toolbarRevision += 1
        case 11:
            if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == NativeSidebarToolbarBridge.toggleID }), let action = item.action {
                if !NSApp.sendAction(action, to: item.target, from: item) { failures.append("Native sidebar action did not dispatch") }
            } else { failures.append("Native sidebar action is absent") }
        case 12: showSidebar = true
        case 13:
            if let split = window.contentView.flatMap({ descendants($0).compactMap { $0 as? NSSplitView }.first }),
               let controller = split.delegate as? NativeLibraryController {
                controller.detachSidebarToolbar()
            } else { failures.append("Could not detach native toolbar bridge") }
        case 14:
            if let outline = window.contentView.flatMap({ descendants($0).compactMap { $0 as? NSOutlineView }.first { $0.accessibilityIdentifier() == "paper-table" } }) {
                outline.selectRowIndexes(IndexSet(integer: 47), byExtendingSelection: false)
                outline.scrollRowToVisible(47)
            } else { failures.append("Could not select the offscreen native paper row") }
        case 15: window.setContentSize(NSSize(width: 1420, height: 860))
        case 16: window.setContentSize(NSSize(width: 1080, height: 680))
        case 17: window.setContentSize(NSSize(width: 1760, height: 1000))
        case 18: break // Let asynchronous hosting layout settle while the long paper remains selected.
        case 19: selection = []
        case 20:
            showSidebar = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.showSidebar = true; self.toolbarRevision += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.showSidebar = true }
        case 21:
            showSidebar = true; showInspector = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.showInspector = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.showInspector = false }
        case 22:
            showInspector = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.showSidebar = false; self.showInspector = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.showSidebar = true; self.showInspector = true }
        case 23:
            let controller = NativeLibraryController()
            controller.configure(configuration(sidebar: true, inspector: true))
            let closingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 808), styleMask: [.borderless], backing: .buffered, defer: false)
            closingWindow.isReleasedWhenClosed = false
            closingWindow.level = NSWindow.Level(rawValue: -1000)
            closingWindow.contentViewController = controller
            closingWindow.orderBack(nil)
            closedTransitionController = controller
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                controller.configure(self.configuration(sidebar: false, inspector: false))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { closingWindow.close() }
            }
        case 24:
            if let split = window.contentView.flatMap({ descendants($0).compactMap { $0 as? NSSplitView }.first }),
               let controller = split.delegate as? NativeLibraryController,
               let inner = controller.sidebarSplitView.delegate as? NSSplitViewController {
                inner.splitViewItems[0].isCollapsed = true
            } else { failures.append("Could not exercise native sidebar collapse synchronization") }
        case 25: showSidebar = true
        case 26: store.statusMessage = String(repeating: "很长的侧栏状态 LongSidebarStatus", count: 40)
        case 27: store.enqueueMetadataRefresh(paperIDs: Array(store.snapshot.papers.prefix(2)).map(\.id))
        case 28: store.cancelMetadataRefresh()
        case 29: store.statusMessage = nil
        case 30:
            var paper = store.snapshot.papers[0]
            paper.title = "Footer completion fixture"
            do { try store.updatePaperDurably(paper) }
            catch { failures.append("Could not prepare the owned footer completion fixture: \(error)") }
            if !store.enqueueMetadataRefresh(paperIDs: [paper.id]) {
                failures.append("Could not start a fresh successful footer completion task")
            }
        case 31: store.statusMessage = nil
        default: finish(); return
        }
        if [3, 4, 20, 21, 22].contains(index) { sampleMotion(window, step: index, remaining: 40) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (index == 18 ? 1.0 : 0.65)) {
            if self.settledMode {
                if let controller = self.nativeController(in: window) {
                    self.timingSnapshots.append(self.panelDiagnosticState(window, controller: controller,
                        step: index, reason: index == 18 ? "1s-diagnostic-snapshot" : "650ms-diagnostic-snapshot"))
                }
                self.awaitStageCompletion(window, step: index,
                    deadline: (self.stepStartedAt[index] ?? Date().timeIntervalSince1970) + 2)
                return
            }
            self.capture(window, step: index)
            if index == 20, self.step20OriginalUnsettled {
                self.observeStep20Completion(window, deadline: (self.stepStartedAt[20] ?? Date().timeIntervalSince1970) + 2)
            } else {
                self.runStep(index + 1)
            }
        }
    }

    private func awaitForegroundReadiness(_ window: NSWindow, deadline: TimeInterval) {
        if window.isKeyWindow && NSApp.isActive && window.isVisible {
            foregroundReady = true
            print("FOREGROUND: key=\(window.isKeyWindow) active=\(NSApp.isActive) visible=\(window.isVisible) occlusion=\(window.occlusionState.contains(.visible)) level=\(window.level.rawValue)")
            runStep(0)
        } else if Date().timeIntervalSince1970 >= deadline {
            failures.append("Owned foreground fixture could not become key, active and visible within two seconds")
            finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.awaitForegroundReadiness(window, deadline: deadline)
            }
        }
    }

    private func nativeController(in window: NSWindow) -> NativeLibraryController? {
        let split = window.contentView.flatMap { descendants($0).compactMap { $0 as? NSSplitView }.first }
        return split?.delegate as? NativeLibraryController
    }

    private func awaitStageCompletion(_ window: NSWindow, step: Int, deadline: TimeInterval) {
        guard currentStep == step, let controller = nativeController(in: window) else {
            failures.append("Step \(step): lost the owned controller while awaiting completion")
            finish()
            return
        }
        let state = panelDiagnosticState(window, controller: controller, step: step, reason: "completion-observation")
        let hasMotion = [3, 4, 20, 21, 22].contains(step)
        let samplesComplete = !hasMotion || completedMotionSteps.contains(step)
        let settled = state["settled"] as? Bool == true
        if settled && samplesComplete {
            capture(window, step: step)
            runStep(step + 1)
        } else if Date().timeIntervalSince1970 >= deadline {
            failures.append("Step \(step): latest panel intent/native completion and owned motion samples did not finish within two seconds (settled=\(settled), samplesComplete=\(samplesComplete))")
            capture(window, step: step)
            runStep(step + 1)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.awaitStageCompletion(window, step: step, deadline: deadline)
            }
        }
    }

    private func panelDiagnosticState(_ window: NSWindow, controller: NativeLibraryController,
                                      step: Int, reason: String) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        return ["step": step, "ownerStep": currentStep, "reason": reason,
                "time": now, "elapsed": now - (stepStartedAt[step] ?? now),
                "mainThread": Thread.isMainThread,
                "keyWindow": window.isKeyWindow, "appActive": NSApp.isActive,
                "windowVisible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
                "windowLevel": window.level.rawValue,
                "motionSamplesComplete": ![3, 4, 20, 21, 22].contains(step) || completedMotionSteps.contains(step),
                "transitionActive": controller.isPanelTransitionActive,
                "showSidebar": showSidebar, "showInspector": showInspector,
                "actualSidebarCollapsed": controller.isSidebarCollapsed,
                "actualInspectorCollapsed": controller.isInspectorCollapsed,
                "sidebarWidth": controller.sidebarSplitView.arrangedSubviews[0].frame.width,
                "inspectorWidth": controller.splitView.arrangedSubviews[1].frame.width,
                "windowWidth": window.frame.width,
                "settled": !controller.isPanelTransitionActive &&
                    controller.isSidebarCollapsed != showSidebar && controller.isInspectorCollapsed != showInspector]
    }

    private func observeStep20Completion(_ window: NSWindow, deadline: TimeInterval) {
        // This observation never changes the original 650ms assertion/result.
        // Hold the next step so a later inspector request cannot pollute it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.currentStep == 20,
                  let split = window.contentView.flatMap({ self.descendants($0).compactMap { $0 as? NSSplitView }.first }),
                  let controller = split.delegate as? NativeLibraryController else {
                self.failures.append("Step 20 diagnostic lost its owned native controller")
                self.runStep(21)
                return
            }
            let state = self.panelDiagnosticState(window, controller: controller, step: 20, reason: "post-capture-observation")
            self.step20Diagnostics.append(state)
            print("DIAGNOSTIC: step20 elapsed=\(state["elapsed"]!) active=\(state["transitionActive"]!) settled=\(state["settled"]!) sidebar=\(state["sidebarWidth"]!) inspector=\(state["inspectorWidth"]!) main=\(Thread.isMainThread)")
            if state["settled"] as? Bool == true || Date().timeIntervalSince1970 >= deadline {
                self.runStep(21)
            } else {
                self.observeStep20Completion(window, deadline: deadline)
            }
        }
    }

    private func capture(_ window: NSWindow, step: Int) {
        let captureAt = Date().timeIntervalSince1970
        guard let content = window.contentView,
              let split = descendants(content).compactMap({ $0 as? NSSplitView }).first else {
            failures.append("Step \(step): no native split"); return
        }
        guard let controller = split.delegate as? NativeLibraryController else {
            failures.append("Step \(step): no outer native controller"); return
        }
        let sidebarSplit = controller.sidebarSplitView
        guard split.arrangedSubviews.count == 2, sidebarSplit.arrangedSubviews.count == 2,
              controller.splitViewItems[1].behavior == .inspector else {
            failures.append("Step \(step): native nested sidebar/content/inspector roles were lost"); return
        }
        let panes = [sidebarSplit.arrangedSubviews[0], sidebarSplit.arrangedSubviews[1], split.arrangedSubviews[1]]
        let active = panes.enumerated().filter { index, _ in
            index == 1 || (index == 0 ? !controller.isSidebarCollapsed : !controller.isInspectorCollapsed)
        }.map { $0.element }
        if let splitIdentity, splitIdentity != ObjectIdentifier(split) {
            failures.append("Step \(step): the native split was replaced")
        }
        splitIdentity = ObjectIdentifier(split)
        if step < 13 {
            guard let toolbar = window.toolbar else { failures.append("Step \(step): missing toolbar"); return }
            let prefix: [NSToolbarItem.Identifier] = [.flexibleSpace, NativeSidebarToolbarBridge.toggleID, NativeSidebarToolbarBridge.separatorID]
            if Array(toolbar.items.prefix(3).map(\.itemIdentifier)) != prefix ||
               toolbar.items.filter({ $0.itemIdentifier == NativeSidebarToolbarBridge.toggleID }).count != 1 ||
               toolbar.items.filter({ $0.itemIdentifier == NativeSidebarToolbarBridge.separatorID }).count != 1 {
                failures.append("Step \(step): native sidebar prefix was absent or duplicated")
            }
            if let button = toolbar.items.first(where: { $0.itemIdentifier == NativeSidebarToolbarBridge.toggleID }) {
                if button.target !== controller.sidebarActionTarget { failures.append("Step \(step): sidebar target was not its own split controller") }
                let nativeButton = window.contentView?.superview.flatMap { frame in
                    descendants(frame).compactMap { $0 as? NSButton }.first { $0.image?.accessibilityDescription == PMLocalization.text("边栏") }
                }
                if nativeButton == nil { failures.append("Step \(step): native sidebar image button was not rendered") }
                if showSidebar, let view = nativeButton {
                    let center = view.convert(view.bounds, to: nil).midX
                    let divider = sidebarSplit.convert(CGPoint(x: sidebarSplit.arrangedSubviews[0].frame.maxX, y: 0), to: nil).x
                    if abs(center - (divider - 26)) > 1 { failures.append("Step \(step): sidebar center \(center) did not track divider \(divider)") }
                } else if let view = nativeButton {
                    // AppKit's native toolbar spacing varies across macOS releases.
                    // Check the actual window-control boundary, not a historical x=110.
                    let buttonFrame = view.convert(view.bounds, to: nil)
                    if let zoom = window.standardWindowButton(.zoomButton) {
                        let controlsEnd = zoom.convert(zoom.bounds, to: nil).maxX
                        let gap = buttonFrame.minX - controlsEnd
                        if gap < 4 || gap > 40 {
                            failures.append("Step \(step): collapsed sidebar overlaps or separates from window controls: gap=\(gap)")
                        }
                    } else { failures.append("Step \(step): missing native window controls") }
                }
            }
            if step == 11, showSidebar { failures.append("Native sidebar action failed to update SwiftUI visibility") }
        } else if window.toolbar?.delegate is NativeSidebarToolbarBridge ||
                  window.toolbar?.items.contains(where: { $0.itemIdentifier == NativeSidebarToolbarBridge.separatorID || $0.itemIdentifier == NativeSidebarToolbarBridge.toggleID }) == true {
            failures.append("Detaching did not restore the original SwiftUI toolbar delegate/items")
        }
        let expectedCount = 1 + (showSidebar ? 1 : 0) + (showInspector ? 1 : 0)
        let contentFrame = content.convert(content.bounds, to: nil)
        let splitFrame = split.convert(split.bounds, to: nil)
        let rootFrame = controller.view.convert(controller.view.bounds, to: nil)
        let safeFrame = split.convert(split.safeAreaRect, to: nil)
        let contentLayout = window.contentLayoutRect
        if abs(splitFrame.minY - contentFrame.minY) > 1 || abs(splitFrame.maxY - contentFrame.maxY) > 1 ||
           abs(rootFrame.minY - contentFrame.minY) > 1 || abs(rootFrame.maxY - contentFrame.maxY) > 1 {
            failures.append("Step \(step): native root/split do not cover the full window behind the titlebar")
        }
        if abs(safeFrame.maxY - contentLayout.maxY) > 1 || abs(contentFrame.maxY - contentLayout.maxY - 52) > 1 {
            failures.append("Step \(step): full-height layout lost the native 52pt titlebar safe area")
        }
        if active.count != expectedCount { failures.append("Step \(step): wrong visible pane count \(active.count)") }
        if active.contains(where: { abs($0.frame.height - split.bounds.height) > 1 }) {
            failures.append("Step \(step): pane heights \(active.map { $0.frame.height }) != split \(split.bounds.height)")
        }
        let tableOutline = descendants(panes[1]).compactMap { $0 as? NSOutlineView }.first {
            $0.accessibilityIdentifier() == "paper-table"
        }
        let tableScrollFrame = tableOutline?.enclosingScrollView.map { $0.convert($0.bounds, to: nil) }
        let tableHeaderFrame = tableOutline?.headerView.map { $0.convert($0.bounds, to: nil) }
        if tableScrollFrame.map({ abs($0.minY - contentLayout.minY) < 1 && abs($0.maxY - contentLayout.maxY) < 1 }) != true ||
           tableHeaderFrame.map({ abs($0.maxY - contentLayout.maxY) < 1 }) != true {
            failures.append("Step \(step): the table/header moved underneath the titlebar")
        }
        let searchFrame = descendants(panes[0]).compactMap { $0 as? NSSearchField }.first.map {
            $0.convert($0.bounds, to: nil)
        }
        if showSidebar, searchFrame.map({ abs($0.maxY - (contentLayout.maxY - 12)) < 1 && abs($0.height - 25) < 1 }) != true {
            failures.append("Step \(step): full-height sidebar changed the search field's content-safe-area inset")
        }
        let sidebarItem = controller.sidebarActionTarget.splitViewItems[0]
        let inspectorItem = controller.splitViewItems[1]
        let sidebarView = sidebarItem.viewController.view
        let inspectorView = inspectorItem.viewController.view
        // The public semantic role owns its system material. AppKit does not
        // promise a public glass/effect descendant in the managed hierarchy;
        // assert its layout contract here and verify rendered color separately.
        func semanticPaneCoversTitlebar(_ item: NSSplitViewItem, role: NSSplitViewItem.Behavior) -> Bool {
            let pane = item.viewController.view
            let frame = pane.convert(pane.bounds, to: nil)
            return item.behavior == role && item.allowsFullHeightLayout &&
                abs(frame.minY - contentFrame.minY) < 1 && abs(frame.maxY - contentFrame.maxY) < 1
        }
        if showSidebar, !semanticPaneCoversTitlebar(sidebarItem, role: .sidebar) {
            failures.append("Step \(step): native sidebar role does not cover the full window/titlebar")
        }
        if showInspector, !semanticPaneCoversTitlebar(inspectorItem, role: .inspector) {
            failures.append("Step \(step): native inspector role does not cover the full window/titlebar")
        }
        if step == 6 {
            selectedPaneBaseline = panes.map { $0.frame.width }
            if abs(panes[0].frame.width - 240) > 1 || abs(panes[2].frame.width - 320) > 1 {
                failures.append("Initial sidebar/inspector widths were not 240/320")
            }
        }
        if ([7, 8].contains(step) || (14...19).contains(step)), let baseline = selectedPaneBaseline {
            let widths = panes.map { $0.frame.width }
            if abs(widths[0] - baseline[0]) > 1 || abs(widths[2] - baseline[2]) > 1 {
                failures.append("Step \(step): selecting/clearing full metadata changed sidebar/inspector widths from \(baseline) to \(widths)")
            }
        }
        if (14...18).contains(step), selection != [store.snapshot.papers[47].id] {
            failures.append("Step \(step): offscreen native selection did not reach the inspector binding")
        }
        if (20...25).contains(step) {
            if step == 20 {
                let state = panelDiagnosticState(window, controller: controller, step: step,
                    reason: settledMode ? "settled-assertion-capture" : "original-650ms-capture")
                step20Diagnostics.append(state)
                step20OriginalUnsettled = state["settled"] as? Bool != true
            }
            if controller.isPanelTransitionActive || controller.isSidebarCollapsed == showSidebar || controller.isInspectorCollapsed == showInspector {
                failures.append("Step \(step): rapid panel requests did not settle at the latest intent")
            }
            let saved = UserDefaults.standard.dictionary(forKey: "PaperManager.NativeLibraryPaneWidths") ?? [:]
            if abs(((saved["sidebar"] as? NSNumber)?.doubleValue ?? 0) - 240) > 1 ||
               abs(((saved["inspector"] as? NSNumber)?.doubleValue ?? 0) - 320) > 1 {
                failures.append("Step \(step): panel animation contaminated expanded-width persistence")
            }
        }
        if step == 23, closedTransitionController?.isPanelTransitionActive != false {
            failures.append("Closing a window left its native panel transition active")
        }
        if step == 24, showSidebar {
            failures.append("Native sidebar collapse did not synchronize scene visibility")
        }
        if (26...31).contains(step) {
            if abs(panes[0].frame.width - 240) > 1 || abs(panes[2].frame.width - 320) > 1 || abs(window.frame.width - 1760) > 1 {
                failures.append("Step \(step): long footer status/progress changed pane or floating-window widths")
            }
        }
        if step == 27, store.metadataRefreshProgress?.isRunning != true {
            failures.append("The footer progress fixture did not have an active owned metadata task")
        }
        if step == 31, store.metadataRefreshProgress.map({ $0.isRunning || $0.failed > 0 || $0.cancelled }) != false {
            failures.append("The final idle footer fixture did not have a completed successful task")
        }
        let sidebarOutline = descendants(panes[0]).compactMap { $0 as? NSOutlineView }.first {
            $0.accessibilityIdentifier() == "library-sidebar-outline"
        }
        let sidebarScroll = sidebarOutline?.enclosingScrollView
        let sidebarScrollFrame = sidebarScroll.map { $0.convert($0.bounds, to: nil) }
        let footer = descendants(panes[0]).first { $0.accessibilityIdentifier() == "library-task-footer" }
        let footerFrame = footer.map { $0.convert($0.bounds, to: nil) }
        let sidebarFrame = sidebarView.convert(sidebarView.bounds, to: nil)
        let idleFooter = step < 26 || step == 31
        var lastSidebarRowVisible: Bool?
        if showSidebar {
            if let sidebarScrollFrame, let footerFrame {
                if idleFooter {
                    if abs(footerFrame.height) > 0.5 || abs(sidebarScrollFrame.minY - sidebarFrame.minY) > 0.5 {
                        failures.append("Step \(step): empty footer reserved a bottom strip (height \(footerFrame.height), scroll gap \(sidebarScrollFrame.minY - sidebarFrame.minY))")
                    }
                } else if footerFrame.height <= 20 ||
                            abs(sidebarScrollFrame.minY - footerFrame.maxY) > 0.5 ||
                            abs(footerFrame.minY - sidebarFrame.minY) > 0.5 {
                    failures.append("Step \(step): visible status/task footer lost its content/padding or overlapped the sidebar viewport")
                }
            } else { failures.append("Step \(step): sidebar scroll/owned task footer host was absent") }
            if [0, 31].contains(step), let sidebarOutline, let sidebarScroll {
                let lastRow = sidebarOutline.numberOfRows - 1
                if lastRow >= 0 {
                    sidebarOutline.scrollRowToVisible(lastRow)
                    let row = sidebarOutline.convert(sidebarOutline.rect(ofRow: lastRow), to: nil)
                    let viewport = sidebarScroll.contentView.convert(sidebarScroll.contentView.bounds, to: nil)
                    lastSidebarRowVisible = row.minY >= viewport.minY - 0.5 && row.maxY <= viewport.maxY + 0.5
                    if lastSidebarRowVisible != true || sidebarOutline.bounds.height <= sidebarScroll.contentView.bounds.height {
                        failures.append("Step \(step): overflowing sidebar's last row could not be fully scrolled into the idle bottom viewport")
                    }
                } else { failures.append("Step \(step): footer overflow fixture had no sidebar rows") }
            }
        }
        let inspectorViews = descendants(panes[2])
        let horizontal = inspectorViews.prefix(8).map { view -> [String: Any] in
            ["class": String(describing: type(of: view)), "frame": rect(view.frame),
             "intrinsicWidth": view.intrinsicContentSize.width,
             "horizontalConstraints": view.constraintsAffectingLayout(for: .horizontal).map { $0.description }]
        }
        stages.append(["step": step, "startedAt": stepStartedAt[step] ?? captureAt,
                       "captureAt": captureAt, "captureElapsed": captureAt - (stepStartedAt[step] ?? captureAt),
                       "captureMainThread": Thread.isMainThread,
                       "keyWindow": window.isKeyWindow, "appActive": NSApp.isActive,
                       "windowVisible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
                       "frontmostBundleIdentifier": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                       "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                       "windowLevel": window.level.rawValue,
                       "motionSamplesCompleteAtCapture": ![3, 4, 20, 21, 22].contains(step) || completedMotionSteps.contains(step),
                       "panelTransitionActiveAtCapture": controller.isPanelTransitionActive,
                       "window": rect(window.frame), "contentLayout": rect(window.contentLayoutRect),
                       "split": rect(split.frame), "bounds": rect(split.bounds), "paneFrames": active.map { rect($0.frame) },
                       "contentFrame": rect(contentFrame), "rootFrame": rect(rootFrame), "splitSafeArea": rect(safeFrame),
                       "tableScrollFrame": tableScrollFrame.map(rect) ?? [:], "tableHeaderFrame": tableHeaderFrame.map(rect) ?? [:],
                       "searchFrame": searchFrame.map(rect) ?? [:],
                       "sidebarScrollFrame": sidebarScrollFrame.map(rect) ?? [:],
                       "taskFooterFrame": footerFrame.map(rect) ?? [:], "idleTaskFooter": idleFooter,
                       "lastSidebarRowVisible": lastSidebarRowVisible.map { $0 as Any } ?? NSNull(),
                       "semanticPaneFrames": ["sidebar": rect(sidebarView.convert(sidebarView.bounds, to: nil)),
                                              "inspector": rect(inspectorView.convert(inspectorView.bounds, to: nil))],
                       "semanticPaneRoles": ["sidebar": sidebarItem.behavior.rawValue, "inspector": inspectorItem.behavior.rawValue],
                       "allowsFullHeightLayout": ["sidebar": sidebarItem.allowsFullHeightLayout, "inspector": inspectorItem.allowsFullHeightLayout],
                       "selectionCount": selection.count, "showSidebar": showSidebar, "showInspector": showInspector,
                       "actualSidebarCollapsed": controller.isSidebarCollapsed,
                       "actualInspectorCollapsed": controller.isInspectorCollapsed,
                       "inspectorHorizontalLayout": horizontal])
        if frontmostMode, !window.isKeyWindow || !NSApp.isActive || !window.isVisible {
            let owner = NSWorkspace.shared.frontmostApplication
            failures.append("Step \(step): owned foreground window lost key/active/visible state (frontmost=\(owner?.bundleIdentifier ?? "unbundled"), pid=\(owner?.processIdentifier ?? 0), expected=\(ProcessInfo.processInfo.processIdentifier))")
        }
    }

    private func sampleMotion(_ window: NSWindow, step: Int, remaining: Int) {
        guard remaining > 0 else { return }
        if let split = window.contentView.flatMap({ descendants($0).compactMap { $0 as? NSSplitView }.first }),
           let controller = split.delegate as? NativeLibraryController {
            let now = Date().timeIntervalSince1970
            motionSamples.append(["step": step, "ownerStep": currentStep, "belongsToStep": currentStep == step,
                                  "remainingSamples": remaining,
                                  "time": now, "elapsed": now - (stepStartedAt[step] ?? now),
                                  "mainThread": Thread.isMainThread,
                                  "sidebar": Double(controller.sidebarSplitView.arrangedSubviews[0].frame.width),
                                  "inspector": Double(split.arrangedSubviews[1].frame.width),
                                  "window": Double(window.frame.width),
                                  "active": controller.isPanelTransitionActive])
            if remaining == 1 { completedMotionSteps.insert(step) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.sampleMotion(window, step: step, remaining: remaining - 1) }
    }

    private func finish() {
        for (step, key, expanded) in [(3, "sidebar", 240.0), (4, "inspector", 320.0)] {
            let samples = motionSamples.filter { ($0["step"] as? Int) == step && ($0["ownerStep"] as? Int) == step }
            if !samples.contains(where: { sample in
                guard let width = sample[key] as? Double else { return false }
                return width > 1 && width < expanded - 1
            }) {
                failures.append("Step \(step): no native intermediate \(key) motion frame was rendered")
            }
            if samples.contains(where: { abs(($0["window"] as? Double ?? 0) - 1760) > 1 }) {
                failures.append("Step \(step): collapsing a floating panel changed the window width")
            }
        }
        for key in ["PaperManager.NativeLibraryPaneWidths", "NSSplitView Subview Frames PaperManager.NativeLibrarySplit"] {
            if let value = previousPanePreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if settledMode, motionSamples.contains(where: { $0["belongsToStep"] as? Bool != true }) {
            failures.append("Motion samples crossed stage ownership in settled mode")
        }
        if settledMode {
            for step in [3, 4, 20, 21, 22] {
                let count = motionSamples.filter { ($0["step"] as? Int) == step && ($0["ownerStep"] as? Int) == step }.count
                if count != 40 { failures.append("Step \(step): expected 40 owned motion samples, observed \(count)") }
            }
        }
        let payload: [String: Any] = ["ok": failures.isEmpty, "failures": failures, "stages": stages,
                                    "pid": ProcessInfo.processInfo.processIdentifier,
                                    "timestamp": Date().timeIntervalSince1970, "motionSamples": motionSamples,
                                    "step20Diagnostics": step20Diagnostics,
                                    "step20OriginalUnsettled": step20OriginalUnsettled,
                                    "frontmostMode": frontmostMode, "settledMode": settledMode,
                                    "timingSnapshots": timingSnapshots]
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
