import AppKit

/// SwiftUI owns the Add/Export popovers and the rest of this toolbar. The
/// embedded AppKit split is not a NavigationSplitView, so SwiftUI's default
/// sidebar item has no environment action and is omitted. Supply just the
/// sidebar section with public AppKit items and forward the original delegate.
@MainActor
final class NativeSidebarToolbarBridge: NSObject, NSToolbarDelegate {
    static let separatorID = NSToolbarItem.Identifier("PaperManager.SidebarTrackingSeparator")
    static let toggleID = NSToolbarItem.Identifier("PaperManager.SidebarToggle")
    private weak var controller: NativeLibraryController?
    private weak var toolbar: NSToolbar?
    private var originalDelegate: NSToolbarDelegate?
    private weak var leadingSpace: NSToolbarItem?
    private weak var sidebarToggle: NSToolbarItem?
    private var reconciling = false
    private var reconciliationPending = false

    init(controller: NativeLibraryController) { self.controller = controller }

    func attach(to window: NSWindow) {
        guard let controller, controller.viewIfLoaded?.window === window,
              let target = window.toolbar else { return }
        if toolbar !== target || target.delegate !== self {
            detach()
            // A replacement split controller can arrive before its predecessor
            // is dismantled. Never wrap another instance or form delegate loops.
            if let previous = target.delegate as? NativeSidebarToolbarBridge { previous.detach() }
            originalDelegate = target.delegate
            toolbar = target
            target.delegate = self
        }
        reconcile()
    }

    func detach() {
        if let toolbar, toolbar.delegate === self {
            reconciling = true
            removeOwnedItems(from: toolbar)
            toolbar.delegate = originalDelegate
            reconciling = false
        }
        toolbar = nil
        originalDelegate = nil
        leadingSpace = nil
        sidebarToggle = nil
    }

    private func removeOwnedItems(from toolbar: NSToolbar) {
        for (index, item) in toolbar.items.enumerated().reversed()
        where item === leadingSpace || item === sidebarToggle || item.itemIdentifier == Self.separatorID {
            toolbar.removeItem(at: index)
        }
    }

    private func reconcile() {
        guard !reconciling, let toolbar, toolbar.delegate === self, let controller,
              controller.viewIfLoaded?.window?.toolbar === toolbar else { return }
        let prefix: [NSToolbarItem.Identifier] = [.flexibleSpace, Self.toggleID, Self.separatorID]
        let alreadyInstalled = toolbar.items.count >= 3 &&
            Array(toolbar.items.prefix(3).map(\.itemIdentifier)) == prefix &&
            toolbar.items[0] === leadingSpace && toolbar.items[1] === sidebarToggle
        if !alreadyInstalled {
            reconciling = true
            defer { reconciling = false }
            removeOwnedItems(from: toolbar)
            for (index, id) in prefix.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: index) }
            leadingSpace = toolbar.items.first
            sidebarToggle = toolbar.items.dropFirst().first
        }
        // Keep routing explicit; native first-responder discovery can otherwise
        // choose a different window or miss the embedded split controller.
        guard let sidebarToggle else { return }
        if sidebarToggle.target !== controller.sidebarActionTarget { sidebarToggle.target = controller.sidebarActionTarget }
        let action = #selector(NSSplitViewController.toggleSidebar(_:))
        if sidebarToggle.action != action { sidebarToggle.action = action }
        let label = PMLocalization.text("边栏")
        if sidebarToggle.label != label { sidebarToggle.label = label }
        let tooltip = PMLocalization.text(controller.isSidebarCollapsed ? "显示文库侧栏" : "隐藏文库侧栏")
        if sidebarToggle.toolTip != tooltip { sidebarToggle.toolTip = tooltip }
        if let view = sidebarToggle.view, view.accessibilityIdentifier() != "main-toolbar-sidebar" {
            view.setAccessibilityIdentifier("main-toolbar-sidebar")
        }
    }

    private func scheduleReconciliation() {
        guard !reconciling, !reconciliationPending else { return }
        reconciliationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationPending = false
            self.reconcile()
        }
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.separatorID, let controller {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: controller.sidebarSplitView, dividerIndex: 0)
        }
        if id == Self.toggleID, let controller {
            // The standard .toggleSidebar item forces target=nil at validation.
            // A normal native image item retains explicit per-window routing
            // while AppKit supplies the same 36pt toolbar button and rendering.
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: PMLocalization.text("边栏"))
            item.label = PMLocalization.text("边栏")
            item.target = controller.sidebarActionTarget
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        }
        return originalDelegate?.toolbar?(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toggleID, Self.separatorID] +
            (originalDelegate?.toolbarDefaultItemIdentifiers?(toolbar) ?? []).filter { $0 != Self.toggleID && $0 != Self.separatorID }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let original = originalDelegate?.toolbarAllowedItemIdentifiers?(toolbar) ?? []
        return original + [.flexibleSpace, Self.toggleID, Self.separatorID].filter { !original.contains($0) }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        originalDelegate?.toolbarWillAddItem?(notification)
        scheduleReconciliation()
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        originalDelegate?.toolbarDidRemoveItem?(notification)
        scheduleReconciliation()
    }
}
