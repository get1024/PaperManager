import AppKit
import SwiftUI

/// The recovered app uses AppKit split, outline, and table controllers. Keep
/// their native selection, disclosure, header, and keyboard behavior here.
struct NativeLibraryView: NSViewControllerRepresentable {
    let store: LibraryStore
    let papers: [Paper]
    @Binding var selectedFilter: LibraryFilter
    @Binding var selection: Set<UUID>
    @Binding var searchText: String
    @Binding var includeSubcollections: Bool
    @Binding var sortDescriptor: PaperSortDescriptor
    let showSidebar: Bool
    let showInspector: Bool
    let focusSearchToken: Int
    let onOpenSelected: () -> Void
    let onRevealSelected: () -> Void
    let onDeleteSelected: () -> Void
    let onImportURLs: ([URL]) -> Void
    let onRefreshMetadata: () -> Void
    let onExportBibTeX: () -> Void
    let onExportRIS: () -> Void
    let onExportDetailed: () -> Void
    var onToggleSidebar: () -> Void = {}
    var onPanelVisibilityChanged: (Bool, Bool) -> Void = { _, _ in }
    var selectionCommands: NativePaperSelectionCommands? = nil

    @MainActor
    final class Coordinator {
        private(set) var controller: NativeLibraryController?

        func makeController(_ configuration: NativeLibraryView) -> NativeLibraryController {
            let controller = NativeLibraryController()
            self.controller = controller
            controller.configure(configuration)
            DispatchQueue.main.async { [weak controller] in controller?.recordBridgeAttachment() }
            return controller
        }

        func update(_ configuration: NativeLibraryView) { controller?.configure(configuration) }

        func dismantle(_ controller: NativeLibraryController) {
            controller.invalidatePanelTransitions()
            controller.detachSidebarToolbar()
            controller.view.window?.makeFirstResponder(nil)
            // A closed window must flush even when SwiftUI no longer owns the
            // controller lifecycle. Failed sessions retain their drafts for retry.
            PaperDraftSession.flushAll()
            self.controller = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NativeLibraryController { context.coordinator.makeController(self) }

    func updateNSViewController(_ controller: NativeLibraryController, context: Context) { context.coordinator.update(self) }

    static func dismantleNSViewController(_ controller: NativeLibraryController, coordinator: Coordinator) {
        coordinator.dismantle(controller)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeLibraryController, context: Context) -> CGSize? {
        context.coordinator.controller?.recordProposedSize(proposal)
        // The library fills its proposed content area; the split controller
        // retains its native root hierarchy and manages pane geometry.
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

final class NativeLibraryController: NSSplitViewController {
    private let contentSplit = NativeLibraryContentSplitController()
    private let sidebar = NativeSidebarController()
    private let paperTable = NativePaperTableController()
    private let inspector = NSHostingController(rootView: AnyView(EmptyView()))
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var lastFocusToken = 0
    private var pendingSearchFocusToken: Int?
    private var onToggleSidebar: () -> Void = {}
    private var onPanelVisibilityChanged: (Bool, Bool) -> Void = { _, _ in }
    private struct PanelVisibility: Equatable { var sidebar: Bool; var inspector: Bool }
    private var desiredVisibility: PanelVisibility?
    private var activeTransition: (generation: UInt64, target: PanelVisibility)?
    private var transitionGeneration: UInt64 = 0
    private var isApplyingVisibility = false
    private var panelCoordinatorDetached = false
    private var collapseObservations: [NSKeyValueObservation] = []
    var sidebarSplitView: NSSplitView { contentSplit.splitView }
    var sidebarActionTarget: NSSplitViewController { contentSplit }
    var isSidebarCollapsed: Bool { sidebarItem?.isCollapsed ?? false }
    var isInspectorCollapsed: Bool { inspectorItem?.isCollapsed ?? false }
    var isPanelTransitionActive: Bool { activeTransition != nil }
    private lazy var sidebarToolbar = NativeSidebarToolbarBridge(controller: self)
    private var sidebarToolbarInstallPending = false
    private var sidebarToolbarInstallAttempts = 0
    private var sidebarToolbarDetached = false
    private var geometryLog: NativeLibraryGeometryLog?
    private var hasAppliedPaneWidths = false
    private var applyingPaneWidths = false
    private var paneWidthApplicationPending = false
    private var initialPaneSizingAttempts = 0
    private var fullScreenPaneWidths: [String: CGFloat]?
    private static let paneWidthsDefaultsKey = "PaperManager.NativeLibraryPaneWidths"

    override func loadView() {
        super.loadView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        // Explicit pane preferences are the sole authority. Legacy AppKit
        // autosave can restore stale widths after the initial manual layout.
        splitView.autosaveName = nil
        contentSplit.loadViewIfNeeded()
        contentSplit.splitView.isVertical = true
        contentSplit.splitView.dividerStyle = .thin
        contentSplit.splitView.autosaveName = nil
        contentSplit.onToggleSidebar = { [weak self] sender in self?.toggleSidebar(sender) }

        let initialWidths = UserDefaults.standard.dictionary(forKey: Self.paneWidthsDefaultsKey) ?? [:]
        let initialSidebarWidth = CGFloat(min(320, max(200, (initialWidths["sidebar"] as? NSNumber)?.doubleValue ?? 240)))
        let initialInspectorWidth = CGFloat(min(460, max(300, (initialWidths["inspector"] as? NSNumber)?.doubleValue ?? 320)))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // NSSplitViewController derives its initial holding constraints from the
        // minimum before the window appears. A preferred fraction only affects
        // fullscreen/double-click, and setPosition alone cannot change that
        // initial Auto Layout constraint. Seed it with the restored width; relax
        // the temporary minimum after the first real layout for normal dragging.
        sidebarItem.minimumThickness = initialSidebarWidth
        sidebarItem.maximumThickness = 320
        // Preserve the user's absolute width when entering full screen.
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.holdingPriority = .defaultHigh
        contentSplit.addSplitViewItem(sidebarItem)

        let tableItem = NSSplitViewItem(viewController: paperTable)
        tableItem.minimumThickness = 350
        contentSplit.addSplitViewItem(tableItem)
        addSplitViewItem(NSSplitViewItem(viewController: contentSplit))

        // The split item owns this pane's size. NSHostingController otherwise
        // installs the empty inspector's 175pt maximum-height constraint,
        // which also caps every sibling through the split's shared edges.
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.maximumThickness = 460
        inspectorItem.minimumThickness = initialInspectorWidth
        inspectorItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        inspectorItem.canCollapse = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.holdingPriority = .defaultHigh
        addSplitViewItem(inspectorItem)
        inspector.view.setAccessibilityIdentifier("inspector-root")
        geometryLog = NativeLibraryGeometryLog(controller: self)
        NotificationCenter.default.addObserver(self, selector: #selector(panesDidResize),
            name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        NotificationCenter.default.addObserver(self, selector: #selector(panesDidResize),
            name: NSSplitView.didResizeSubviewsNotification, object: sidebarSplitView)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification, object: nil)
        collapseObservations = [sidebarItem, inspectorItem].map { item in
            item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.nativeVisibilityChanged() }
            }
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(willChangeFullScreen), name: name, object: nil)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(didChangeFullScreen), name: name, object: nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !hasAppliedPaneWidths { initialPaneSizingAttempts = 0 }
        sidebarToolbarInstallAttempts = 0
        scheduleSidebarToolbar()
        scheduleInitialPaneWidths()
        focusSearchIfReady()
        geometryLog?.captureAfterAppearance()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleInitialPaneWidths()
        geometryLog?.schedule(reason: "viewDidLayout")
    }

    private func scheduleInitialPaneWidths() {
        guard !hasAppliedPaneWidths, !paneWidthApplicationPending, initialPaneSizingAttempts < 8 else { return }
        paneWidthApplicationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.paneWidthApplicationPending = false
            self.applyInitialPaneWidthsIfNeeded()
        }
    }

    private func applyInitialPaneWidthsIfNeeded() {
        guard !hasAppliedPaneWidths else { return }
        // A bridge may be constructed long before it is attached to a window.
        // Attachment/appearance schedules the next attempt; it must not exhaust
        // a finite sizing budget while there is no native viewport to measure.
        guard view.window != nil else { return }
        guard splitView.bounds.width >= 900 else {
            initialPaneSizingAttempts += 1
            scheduleInitialPaneWidths()
            return
        }
        hasAppliedPaneWidths = true
        applyingPaneWidths = true
        defer { applyingPaneWidths = false }
        let widths = UserDefaults.standard.dictionary(forKey: Self.paneWidthsDefaultsKey) ?? [:]
        let sidebarWidth = (widths["sidebar"] as? NSNumber)?.doubleValue ?? 240
        let inspectorWidth = (widths["inspector"] as? NSNumber)?.doubleValue ?? 320
        splitView.adjustSubviews()
#if NATIVE_TABLE_SMOKE
        print("MEASURE: applying initial pane widths before=\(splitView.arrangedSubviews.map { $0.frame.width }) target=\(sidebarWidth)/\(inspectorWidth)")
#endif
        if !sidebarItem.isCollapsed {
            sidebarSplitView.setPosition(CGFloat(min(320, max(200, sidebarWidth))), ofDividerAt: 0)
        }
        if !inspectorItem.isCollapsed {
            let width = CGFloat(min(460, max(300, inspectorWidth)))
            splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: 0)
        }
        sidebarItem.minimumThickness = 200
        inspectorItem.minimumThickness = 300
#if NATIVE_TABLE_SMOKE
        print("MEASURE: applying initial pane widths after=\(splitView.arrangedSubviews.map { $0.frame.width })")
#endif
    }

    @objc private func panesDidResize(_ notification: Notification) {
        scheduleInitialPaneWidths()
        guard hasAppliedPaneWidths, !applyingPaneWidths, !isApplyingVisibility, activeTransition == nil,
              !panelCoordinatorDetached, fullScreenPaneWidths == nil, view.window != nil else { return }
        var widths = UserDefaults.standard.dictionary(forKey: Self.paneWidthsDefaultsKey) ?? [:]
        if !sidebarItem.isCollapsed, sidebar.view.frame.width >= sidebarItem.minimumThickness {
            widths["sidebar"] = Double(sidebar.view.frame.width)
        }
        if !inspectorItem.isCollapsed, inspector.view.frame.width >= inspectorItem.minimumThickness {
            widths["inspector"] = Double(inspector.view.frame.width)
        }
        let previous = UserDefaults.standard.dictionary(forKey: Self.paneWidthsDefaultsKey) ?? [:]
        if !NSDictionary(dictionary: widths).isEqual(to: previous) {
            UserDefaults.standard.set(widths, forKey: Self.paneWidthsDefaultsKey)
        }
    }

    @objc private func willChangeFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        let stored = UserDefaults.standard.dictionary(forKey: Self.paneWidthsDefaultsKey) ?? [:]
        fullScreenPaneWidths = [
            "sidebar": sidebarItem.isCollapsed ? CGFloat((stored["sidebar"] as? NSNumber)?.doubleValue ?? 240) : sidebar.view.frame.width,
            "inspector": inspectorItem.isCollapsed ? CGFloat((stored["inspector"] as? NSNumber)?.doubleValue ?? 320) : inspector.view.frame.width
        ]
    }

    @objc private func didChangeFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window,
              let widths = fullScreenPaneWidths else { return }
        // AppKit may choose new holding sizes during the animation. Restore the
        // window's pre-transition widths after its completed fullscreen layout.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.view.window else { return }
            self.applyingPaneWidths = true
            self.splitView.layoutSubtreeIfNeeded()
            if !self.sidebarItem.isCollapsed {
                self.sidebarSplitView.setPosition(widths["sidebar"] ?? 240, ofDividerAt: 0)
            }
            if !self.inspectorItem.isCollapsed {
                self.splitView.setPosition(self.splitView.bounds.width - (widths["inspector"] ?? 320) - self.splitView.dividerThickness, ofDividerAt: 0)
            }
            self.splitView.layoutSubtreeIfNeeded()
            self.applyingPaneWidths = false
            self.fullScreenPaneWidths = nil
            self.panesDidResize(Notification(name: NSSplitView.didResizeSubviewsNotification, object: self.splitView))
        }
    }

    private func requestVisibility(sidebar: Bool, inspector: Bool) {
        guard !panelCoordinatorDetached else { return }
        // A later hide request supersedes an earlier search/reveal command.
        if !sidebar { pendingSearchFocusToken = nil }
        let target = PanelVisibility(sidebar: sidebar, inspector: inspector)
        let initial = desiredVisibility == nil
        guard desiredVisibility != target else { return }
        desiredVisibility = target
        if initial || view.window == nil {
            isApplyingVisibility = true
            sidebarItem.isCollapsed = !target.sidebar
            inspectorItem.isCollapsed = !target.inspector
            isApplyingVisibility = false
        } else {
            reconcilePanelVisibility()
        }
    }

    private func reconcilePanelVisibility() {
        guard !panelCoordinatorDetached, activeTransition == nil,
              let target = desiredVisibility, let window = view.window else { return }
        guard sidebarItem.isCollapsed != !target.sidebar || inspectorItem.isCollapsed != !target.inspector else { return }
        // Save only expanded stable geometry, before native constraint motion.
        panesDidResize(Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView))
        transitionGeneration &+= 1
        let generation = transitionGeneration
        activeTransition = (generation, target)
        NSAnimationContext.runAnimationGroup { context in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { context.duration = 0 }
            if sidebarItem.isCollapsed != !target.sidebar { sidebarItem.animator().isCollapsed = !target.sidebar }
            if inspectorItem.isCollapsed != !target.inspector { inspectorItem.animator().isCollapsed = !target.inspector }
        } completionHandler: { [weak self, weak window] in
            guard let self, let window, window === self.viewIfLoaded?.window,
                  !self.panelCoordinatorDetached, self.activeTransition?.generation == generation else { return }
            self.activeTransition = nil
            self.view.layoutSubtreeIfNeeded()
            if self.desiredVisibility != target {
                // Multiple clicks coalesce into the most recent requested state.
                self.reconcilePanelVisibility()
            } else {
                self.panesDidResize(Notification(name: NSSplitView.didResizeSubviewsNotification, object: self.splitView))
            }
            self.scheduleSidebarToolbar()
            self.focusSearchIfReady()
        }
    }

    private func requestSearchFocus(token: Int) {
        pendingSearchFocusToken = token
        let target = desiredVisibility ?? PanelVisibility(sidebar: !sidebarItem.isCollapsed, inspector: !inspectorItem.isCollapsed)
        if !target.sidebar {
            requestVisibility(sidebar: true, inspector: target.inspector)
            // configure() runs inside an NSViewControllerRepresentable update.
            // Publish the scene change after that update, retaining the latest
            // panel intent if another command arrives before this callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.panelCoordinatorDetached,
                      self.lastFocusToken == token, self.viewIfLoaded?.window != nil,
                      let latest = self.desiredVisibility, latest.sidebar else { return }
                self.onPanelVisibilityChanged(true, latest.inspector)
            }
        }
        focusSearchIfReady()
    }

    private func focusSearchIfReady() {
        guard pendingSearchFocusToken == lastFocusToken, pendingSearchFocusToken != nil,
              !panelCoordinatorDetached, activeTransition == nil,
              desiredVisibility?.sidebar == true, !sidebarItem.isCollapsed,
              viewIfLoaded?.window != nil else { return }
        pendingSearchFocusToken = nil
        sidebar.focusSearch()
    }

    private func nativeVisibilityChanged() {
        guard !panelCoordinatorDetached, !isApplyingVisibility, activeTransition == nil else { return }
        let actual = PanelVisibility(sidebar: !sidebarItem.isCollapsed, inspector: !inspectorItem.isCollapsed)
        guard actual != desiredVisibility else { return }
        if !actual.sidebar { pendingSearchFocusToken = nil }
        desiredVisibility = actual
        onPanelVisibilityChanged(actual.sidebar, actual.inspector)
        scheduleSidebarToolbar()
    }

    func invalidatePanelTransitions() {
        panelCoordinatorDetached = true
        transitionGeneration &+= 1
        activeTransition = nil
        pendingSearchFocusToken = nil
        collapseObservations.removeAll()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === viewIfLoaded?.window else { return }
        invalidatePanelTransitions()
    }

    func recordBridgeAttachment() {
        scheduleSidebarToolbar()
        scheduleInitialPaneWidths()
        geometryLog?.schedule(reason: "NSViewControllerBridgeAttached")
        geometryLog?.captureAfterAppearance()
    }

    func recordProposedSize(_ proposal: ProposedViewSize) {
        geometryLog?.proposal = proposal
    }

    override func toggleSidebar(_ sender: Any?) {
        // The inner sidebar controller forwards its native action here. Scene
        // intent then reaches the same coordinator as menu and keyboard input.
        onToggleSidebar()
    }

    override func toggleInspector(_ sender: Any?) {
        guard let desired = desiredVisibility, !panelCoordinatorDetached else { return }
        requestVisibility(sidebar: desired.sidebar, inspector: !desired.inspector)
        onPanelVisibilityChanged(desired.sidebar, !desired.inspector)
    }

    func detachSidebarToolbar() {
        sidebarToolbarDetached = true
        sidebarToolbar.detach()
    }

    private func scheduleSidebarToolbar() {
        guard !sidebarToolbarDetached, let window = viewIfLoaded?.window, !sidebarToolbarInstallPending else { return }
        guard window.toolbar != nil || sidebarToolbarInstallAttempts < 8 else { return }
        sidebarToolbarInstallPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.sidebarToolbarInstallPending = false
            guard !self.sidebarToolbarDetached, let window = self.viewIfLoaded?.window else { return }
            guard window.toolbar != nil else {
                self.sidebarToolbarInstallAttempts += 1
                self.scheduleSidebarToolbar()
                return
            }
            self.sidebarToolbar.attach(to: window)
        }
    }

    func configure(_ configuration: NativeLibraryView) {
        loadViewIfNeeded()
        onToggleSidebar = configuration.onToggleSidebar
        onPanelVisibilityChanged = configuration.onPanelVisibilityChanged
        sidebar.configure(configuration)
        paperTable.configure(configuration)
        inspector.rootView = AnyView(
            PaperDetailView(selection: configuration.$selection)
                .environmentObject(configuration.store)
                .environment(\.locale, PMLocalization.locale(for: configuration.store.settings.languageIdentifier))
                .accessibilityIdentifier("inspector-root")
        )
        requestVisibility(sidebar: configuration.showSidebar, inspector: configuration.showInspector)
        if lastFocusToken != configuration.focusSearchToken {
            lastFocusToken = configuration.focusSearchToken
            requestSearchFocus(token: configuration.focusSearchToken)
        }
        scheduleInitialPaneWidths()
        scheduleSidebarToolbar()
        geometryLog?.schedule(reason: "configure")
    }
}

private final class NativeLibraryContentSplitController: NSSplitViewController {
    var onToggleSidebar: (Any?) -> Void = { _ in }
    override func toggleSidebar(_ sender: Any?) { onToggleSidebar(sender) }
}
