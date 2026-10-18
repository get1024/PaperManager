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
    private let sidebar = NativeSidebarController()
    private let paperTable = NativePaperTableController()
    private let inspector = NSHostingController(rootView: AnyView(EmptyView()))
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var lastFocusToken = 0
    private var geometryLog: NativeLibraryGeometryLog?

    override func loadView() {
        super.loadView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "PaperManager.NativeLibrarySplit"

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.preferredThicknessFraction = 240.0 / 1420.0
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultHigh
        addSplitViewItem(sidebarItem)

        let tableItem = NSSplitViewItem(viewController: paperTable)
        tableItem.minimumThickness = 350
        addSplitViewItem(tableItem)

        // The split item owns this pane's size. NSHostingController otherwise
        // installs the empty inspector's 175pt maximum-height constraint,
        // which also caps every sibling through the split's shared edges.
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 300
        inspectorItem.maximumThickness = 460
        inspectorItem.preferredThicknessFraction = 340.0 / 1420.0
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .defaultHigh
        addSplitViewItem(inspectorItem)
        inspector.view.setAccessibilityIdentifier("inspector-root")
        geometryLog = NativeLibraryGeometryLog(controller: self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        geometryLog?.captureAfterAppearance()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        geometryLog?.schedule(reason: "viewDidLayout")
    }

    func recordBridgeAttachment() {
        geometryLog?.schedule(reason: "NSViewControllerBridgeAttached")
        geometryLog?.captureAfterAppearance()
    }

    func recordProposedSize(_ proposal: ProposedViewSize) {
        geometryLog?.proposal = proposal
    }

    func configure(_ configuration: NativeLibraryView) {
        loadViewIfNeeded()
        sidebar.configure(configuration)
        paperTable.configure(configuration)
        inspector.rootView = AnyView(
            PaperDetailView(selection: configuration.$selection)
                .environmentObject(configuration.store)
                .environment(\.locale, PMLocalization.locale(for: configuration.store.settings.languageIdentifier))
                .accessibilityIdentifier("inspector-root")
        )
        sidebarItem.isCollapsed = !configuration.showSidebar
        inspectorItem.isCollapsed = !configuration.showInspector
        if lastFocusToken != configuration.focusSearchToken {
            lastFocusToken = configuration.focusSearchToken
            sidebar.focusSearch()
        }
        geometryLog?.schedule(reason: "configure")
    }
}

/// Opt-in, local-only geometry evidence for the real SwiftUI WindowGroup.
/// It reads frames without changing layout and records no library text/paths.
@MainActor
private final class NativeLibraryGeometryLog {
    private weak var controller: NativeLibraryController?
    private let destination: URL
    private var pending = false
    private var events: [[String: Any]] = []
    var proposal = ProposedViewSize.unspecified

    init?(controller: NativeLibraryController) {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_GEOMETRY_LOG_PATH"], path.hasPrefix("/") else { return nil }
        self.controller = controller
        destination = URL(fileURLWithPath: path)
    }

    func captureAfterAppearance() {
        schedule(reason: "viewDidAppear")
        for delay in [0.1, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.schedule(reason: "appearance+\(delay)s")
            }
        }
    }

    func schedule(reason: String) {
        guard !pending, events.count < 32 else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.capture(reason: reason)
        }
    }

    private func capture(reason: String) {
        guard let controller else { return }
        let root = controller.view
        var ancestors: [[String: Any]] = []
        var ancestor: NSView? = root
        while let current = ancestor, ancestors.count < 16 {
            ancestors.append(Self.geometry(current))
            ancestor = current.superview
        }
        var splitAncestors: [[String: Any]] = []
        ancestor = controller.splitView
        while let current = ancestor, splitAncestors.count < 16 {
            splitAncestors.append(Self.geometry(current))
            ancestor = current.superview
        }
        var event: [String: Any] = [
            "reason": reason, "time": Date().timeIntervalSince1970,
            "proposal": ["width": Self.number(proposal.width), "height": Self.number(proposal.height)],
            "nativeAncestors": ancestors,
            "splitAncestors": splitAncestors,
            "bridgeState": ["strategy": "NSViewControllerRepresentable", "rootIsSplit": controller.view === controller.splitView],
            "split": Self.geometry(controller.splitView),
            "panes": controller.splitView.arrangedSubviews.map { Self.tree($0, depth: 4) }
        ]
        if let window = root.window {
            event["window"] = ["frame": Self.rect(window.frame), "contentLayoutRect": Self.rect(window.contentLayoutRect),
                               "styleMask": window.styleMask.rawValue, "visible": window.isVisible,
                               "backingScaleFactor": window.backingScaleFactor,
                               "content": window.contentView.map { Self.tree($0, depth: 4) } ?? [:]]
        }
        events.append(event)
        do {
            let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                          "controller": String(describing: ObjectIdentifier(controller)), "events": events]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            // Diagnostics never change app status or the success of a user edit.
        }
    }

    private static func number(_ value: CGFloat?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return Double(value)
    }

    private static func rect(_ rect: NSRect) -> [String: Any] {
        ["x": number(rect.minX), "y": number(rect.minY), "width": number(rect.width), "height": number(rect.height)]
    }

    private static func geometry(_ view: NSView) -> [String: Any] {
        var result: [String: Any] = ["class": String(describing: type(of: view)), "identity": String(describing: ObjectIdentifier(view)),
                                   "frame": rect(view.frame), "bounds": rect(view.bounds),
                                   "visibleRect": rect(view.visibleRect), "safeAreaRect": rect(view.safeAreaRect),
                                   "flipped": view.isFlipped, "hidden": view.isHidden,
                                   "autoresizingMask": view.autoresizingMask.rawValue,
                                   "autoresizesSubviews": view.autoresizesSubviews,
                                   "translatesAutoresizingMaskIntoConstraints": view.translatesAutoresizingMaskIntoConstraints,
                                   "hasAmbiguousLayout": view.hasAmbiguousLayout,
                                   "verticalConstraints": view.constraintsAffectingLayout(for: .vertical).map { $0.description }]
        if view.window != nil { result["inWindow"] = rect(view.convert(view.bounds, to: nil)) }
        if let table = view as? NSTableView { result["rows"] = table.numberOfRows; result["rowHeight"] = table.rowHeight }
        if let scroll = view as? NSScrollView { result["documentVisibleRect"] = rect(scroll.documentVisibleRect) }
        return result
    }

    private static func tree(_ view: NSView, depth: Int) -> [String: Any] {
        var result = geometry(view)
        if depth > 0 { result["subviews"] = view.subviews.prefix(12).map { tree($0, depth: depth - 1) } }
        return result
    }
}

private final class NativeSidebarNode: NSObject {
    let id: String
    let title: String
    let symbol: String
    let filter: LibraryFilter?
    let count: Int
    let color: NSColor?
    var children: [NativeSidebarNode]
    var isAddAction: Bool { id == "add-collection" || id == "add-tag" }
    var isSection: Bool { filter == nil && !isAddAction }

    init(id: String, title: String, symbol: String = "", filter: LibraryFilter? = nil,
         count: Int = 0, color: NSColor? = nil, children: [NativeSidebarNode] = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.filter = filter
        self.count = count
        self.color = color
        self.children = children
    }

    func hasSameContent(as other: NativeSidebarNode) -> Bool {
        id == other.id && title == other.title && symbol == other.symbol && filter == other.filter &&
        count == other.count && color == other.color && children.count == other.children.count &&
        zip(children, other.children).allSatisfy { $0.hasSameContent(as: $1) }
    }
}

private final class NativeSidebarController: NSViewController, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let outline = LibraryOutlineView()
    private let search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var nodes: [NativeSidebarNode] = []
    private var configuration: NativeLibraryView?
    private var updating = false
    private static let expansionDefaultsKey = "PaperManager.NativeSidebar.expandedIDs"
    private var expandedIDs = Set(
        UserDefaults.standard.stringArray(forKey: expansionDefaultsKey) ?? ["library", "collections", "tags"]
    )
    private let paperDragType = NSPasteboard.PasteboardType("com.papermanager.paper-ids")
    private let collectionDragType = NSPasteboard.PasteboardType("com.papermanager.collection-id")
    private let tagDragType = NSPasteboard.PasteboardType("com.papermanager.tag-id")

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        material.setAccessibilityIdentifier("sidebar-root")
        view = material

        search.placeholderString = PMLocalization.text("搜索文献")
        search.font = .systemFont(ofSize: 12)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("library-search")
        search.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(search)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 25
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([paperDragType, collectionDragType, tagDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.menuProvider = { [weak self] in self?.contextMenu() }
        outline.setAccessibilityIdentifier("library-sidebar-outline")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            search.heightAnchor.constraint(equalToConstant: 25),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
    }

    func configure(_ configuration: NativeLibraryView) {
        loadViewIfNeeded()
        self.configuration = configuration
        updating = true
        defer { updating = false }
        search.placeholderString = PMLocalization.text("搜索文献")
        if search.stringValue != configuration.searchText { search.stringValue = configuration.searchText }
        status.stringValue = configuration.store.statusMessage ?? ""
        let store = configuration.store
        func filterNode(_ id: String, _ title: String, _ symbol: String, _ filter: LibraryFilter) -> NativeSidebarNode {
            NativeSidebarNode(id: id, title: title, symbol: symbol, filter: filter,
                count: store.filteredPapers(for: filter, searchText: "",
                    includeSubcollections: configuration.includeSubcollections).count)
        }
        let library = NativeSidebarNode(id: "library", title: PMLocalization.text("文库"), children: [
            filterNode("all", PMLocalization.text("全部文献"), "books.vertical", .all),
            filterNode("unfiled", PMLocalization.text("未归类"), "archivebox", .unfiled),
            filterNode("missingIDs", PMLocalization.text("缺少标识符"), "magnifyingglass.circle", .missingIDs),
            filterNode("missingPDF", PMLocalization.text("缺少 PDF"), "paperclip", .missingPDF)
        ])
        func collections(parent: UUID?, visited: Set<UUID> = []) -> [NativeSidebarNode] {
            store.collections.filter { $0.parentID == parent && !visited.contains($0.id) }
                .sorted { $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex }
                .map { collection in
                    let node = filterNode(collection.id.uuidString, collection.name, "folder", .collection(collection.id))
                    node.children = collections(parent: collection.id, visited: visited.union([collection.id]))
                    return node
                }
        }
        let collectionSection = NativeSidebarNode(id: "collections", title: PMLocalization.text("文集"), children:
            collections(parent: nil) + [NativeSidebarNode(id: "add-collection", title: PMLocalization.text("新建文集"), symbol: "plus")])
        let tagSection = NativeSidebarNode(id: "tags", title: PMLocalization.text("标签"), children: store.tags.map { tag in
            NativeSidebarNode(id: tag.id.uuidString, title: tag.name, symbol: "tag", filter: .tag(tag.id),
                count: store.papers.filter { $0.tagIDs.contains(tag.id) }.count, color: NSColor(pmHex: tag.colorHex))
        } + [NativeSidebarNode(id: "add-tag", title: PMLocalization.text("新建标签"), symbol: "plus")])
        let updatedNodes = [library, collectionSection, tagSection]
        if nodes.count != updatedNodes.count || !zip(nodes, updatedNodes).allSatisfy({ $0.hasSameContent(as: $1) }) {
            nodes = updatedNodes
            outline.reloadData()
            func expand(_ node: NativeSidebarNode) {
                if expandedIDs.contains(node.id) { outline.expandItem(node) }
                node.children.forEach(expand)
            }
            nodes.forEach(expand)
        }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? NativeSidebarNode,
               node.filter == configuration.selectedFilter {
                if outline.selectedRowIndexes != IndexSet(integer: row) {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                break
            }
        }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(search)
        search.selectText(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !updating else { return }
        configuration?.searchText = search.stringValue
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NativeSidebarNode)?.children.count ?? nodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? NativeSidebarNode)?.children[index] ?? nodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NativeSidebarNode else { return false }
        return node.isSection || !node.children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? NativeSidebarNode else { return false }
        return node.filter != nil || node.isAddAction
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? NativeSidebarNode)?.isSection ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? NativeSidebarNode)?.isSection == true ? 29 : 25
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NativeSidebarNode else { return nil }
        let cell = NativeTextCell.reusable(in: outlineView, owner: self)
        cell.configure(symbol: node.symbol, text: node.title, trailing: node.count > 0 ? String(node.count) : "")
        cell.textField?.font = .systemFont(ofSize: node.isSection ? 11 : 13, weight: node.isSection ? .semibold : .regular)
        cell.textField?.textColor = node.isSection || node.isAddAction ? .secondaryLabelColor : .labelColor
        cell.imageView?.contentTintColor = node.color ?? .secondaryLabelColor
        cell.setAccessibilityIdentifier("sidebar-\(node.id)")
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let node = outline.item(atRow: outline.selectedRow) as? NativeSidebarNode else { return }
        if node.isAddAction {
            defer { DispatchQueue.main.async { [weak self] in
                guard let self, let configuration = self.configuration else { return }
                self.configure(configuration)
            } }
            guard let name = DialogService.requestText(title: node.title), !name.isEmpty else { return }
            if node.id == "add-collection" { createCollection(name: name) }
            else { configuration?.store.addTag(name: name) }
        } else if let filter = node.filter { configuration?.selectedFilter = filter }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? NativeSidebarNode else { return }
        expandedIDs.insert(node.id)
        persistExpandedIDs()
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? NativeSidebarNode else { return }
        expandedIDs.remove(node.id)
        persistExpandedIDs()
    }
    private func persistExpandedIDs() {
        UserDefaults.standard.set(expandedIDs.sorted(), forKey: Self.expansionDefaultsKey)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let filter = (item as? NativeSidebarNode)?.filter else { return nil }
        let pasteboard = NSPasteboardItem()
        switch filter {
        case .collection(let id): pasteboard.setString(id.uuidString, forType: collectionDragType)
        case .tag(let id): pasteboard.setString(id.uuidString, forType: tagDragType)
        default: return nil
        }
        return pasteboard
    }

    private func collectionDropTarget(item: Any?, index: Int) -> (parentID: UUID?, index: Int)? {
        guard let store = configuration?.store, let node = item as? NativeSidebarNode else { return nil }
        let parentID: UUID?
        if node.id == "collections" { parentID = nil }
        else if case .collection(let id) = node.filter { parentID = id }
        else { return nil }
        let count = store.collections.filter { $0.parentID == parentID }.count
        return (parentID, index < 0 ? count : min(index, count))
    }

    private func tagDropTarget(item: Any?, index: Int) -> Int? {
        guard let store = configuration?.store, let node = item as? NativeSidebarNode else { return nil }
        if node.id == "tags" { return index < 0 ? store.tags.count : min(index, store.tags.count) }
        if case .tag(let id) = node.filter { return store.tags.firstIndex { $0.id == id } }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if let text = pasteboard.string(forType: collectionDragType), let id = UUID(uuidString: text) {
            guard info.draggingSource as? NSOutlineView === outline,
                  let target = collectionDropTarget(item: item, index: index),
                  configuration?.store.canMoveCollection(id: id, toParentID: target.parentID) == true else { return [] }
            return .move
        }
        if pasteboard.string(forType: tagDragType) != nil {
            guard info.draggingSource as? NSOutlineView === outline,
                  let target = tagDropTarget(item: item, index: index),
                  let tagSection = nodes.first(where: { $0.id == "tags" }) else { return [] }
            outlineView.setDropItem(tagSection, dropChildIndex: target)
            return .move
        }
        guard pasteboard.string(forType: paperDragType) != nil else { return [] }
        guard let node = item as? NativeSidebarNode else { return [] }
        switch node.filter {
        case .collection, .tag: outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex); return .copy
        default: return []
        }
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let store = configuration?.store else { return false }
        let pasteboard = info.draggingPasteboard
        if let text = pasteboard.string(forType: collectionDragType), let id = UUID(uuidString: text),
           let target = collectionDropTarget(item: item, index: index) {
            guard store.moveCollection(id: id, toParentID: target.parentID, at: target.index) else { return false }
            expandedIDs.insert(target.parentID?.uuidString ?? "collections")
            persistExpandedIDs()
            return true
        }
        if let text = pasteboard.string(forType: tagDragType), let id = UUID(uuidString: text),
           let target = tagDropTarget(item: item, index: index) {
            return store.moveTag(id: id, at: target)
        }
        guard let filter = (item as? NativeSidebarNode)?.filter,
              let text = info.draggingPasteboard.string(forType: paperDragType) else { return false }
        let ids = Set(text.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        switch filter {
        case .collection(let id): store.addPapers(ids: ids, toCollection: id)
        case .tag(let id): store.addPapers(ids: ids, toTag: id)
        default: return false
        }
        return !ids.isEmpty
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let node = outline.item(atRow: outline.clickedRow) as? NativeSidebarNode
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: PMLocalization.text(title), action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        add("新建文集", #selector(addCollection(_:)))
        add("新建标签", #selector(addTag(_:)))
        if node?.id == "collections" || isCollectionNode(node) {
            menu.addItem(.separator())
            let toggle = NSMenuItem(title: PMLocalization.text("显示子文集文献"), action: #selector(toggleSubcollectionItems(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.state = configuration?.includeSubcollections == true ? .on : .off
            menu.addItem(toggle)
        }
        if case .collection(let id) = node?.filter {
            add("新建子文集", #selector(addSubcollection(_:)))
            menu.items.last?.isEnabled = configuration?.store.canCreateCollection(parentID: id) == true
            if configuration?.store.collections.first(where: { $0.id == id })?.parentID != nil {
                add("移到顶层", #selector(moveCollectionToRoot(_:)))
            }
        }
        if case .collection = node?.filter { menu.addItem(.separator()); add("重命名", #selector(renameItem(_:))); add("删除文集", #selector(deleteItem(_:))) }
        if case .tag(let id) = node?.filter {
            menu.addItem(.separator())
            add("重命名", #selector(renameItem(_:)))
            let colors = NSMenuItem(title: PMLocalization.text("颜色"), action: nil, keyEquivalent: "")
            let colorMenu = NSMenu()
            let currentColor = configuration?.store.tags.first { $0.id == id }?.colorHex.uppercased()
            for (name, hex) in [("蓝色", "#5B8DEF"), ("绿色", "#36A572"), ("橙色", "#E99A36"),
                                ("红色", "#D75B5B"), ("紫色", "#9366C4"), ("灰色", "#888888")] {
                let entry = NSMenuItem(title: PMLocalization.text(name), action: #selector(setTagColor(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = ["id": id.uuidString, "color": hex]
                entry.state = currentColor == hex ? .on : .off
                colorMenu.addItem(entry)
            }
            colorMenu.addItem(.separator())
            let custom = NSMenuItem(title: PMLocalization.text("自定义颜色…"), action: #selector(customizeTagColor(_:)), keyEquivalent: "")
            custom.target = self; custom.representedObject = node
            colorMenu.addItem(custom)
            colors.submenu = colorMenu
            menu.addItem(colors)
            add("删除标签", #selector(deleteItem(_:)))
        }
        return menu
    }
    private func isCollectionNode(_ node: NativeSidebarNode?) -> Bool {
        if case .collection = node?.filter { return true }
        return false
    }
    @objc private func toggleSubcollectionItems(_ sender: NSMenuItem) {
        guard let configuration else { return }
        configuration.includeSubcollections.toggle()
        configure(configuration)
    }
    @objc private func addCollection(_ sender: NSMenuItem) {
        guard let name = DialogService.requestText(title: "新建文集"), !name.isEmpty else { return }
        createCollection(name: name)
    }
    @objc private func addSubcollection(_ sender: NSMenuItem) {
        guard case .collection(let id) = (sender.representedObject as? NativeSidebarNode)?.filter,
              let name = DialogService.requestText(title: "新建子文集"), !name.isEmpty else { return }
        expandedIDs.insert(id.uuidString)
        persistExpandedIDs()
        createCollection(name: name, parentID: id)
    }
    private func createCollection(name: String, parentID: UUID? = nil) {
        guard let store = configuration?.store else { return }
        do { try store.createCollection(name: name, parentID: parentID) }
        catch { store.statusMessage = error.localizedDescription }
    }
    @objc private func moveCollectionToRoot(_ sender: NSMenuItem) {
        guard case .collection(let id) = (sender.representedObject as? NativeSidebarNode)?.filter,
              let store = configuration?.store else { return }
        store.moveCollection(id: id, toParentID: nil, at: store.collections.filter { $0.parentID == nil }.count)
    }
    @objc private func setTagColor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String],
              let text = value["id"], let id = UUID(uuidString: text), let color = value["color"] else { return }
        configuration?.store.updateTagColor(id: id, colorHex: color)
    }
    @objc private func customizeTagColor(_ sender: NSMenuItem) {
        guard case .tag(let id) = (sender.representedObject as? NativeSidebarNode)?.filter,
              let store = configuration?.store,
              let tag = store.tags.first(where: { $0.id == id }),
              let color = DialogService.requestText(title: "标签颜色", message: "输入十六进制颜色，例如 #5B8DEF。", defaultValue: tag.colorHex) else { return }
        store.updateTagColor(id: id, colorHex: color)
    }
    @objc private func addTag(_ sender: NSMenuItem) {
        guard let name = DialogService.requestText(title: "新建标签"), !name.isEmpty else { return }
        configuration?.store.addTag(name: name)
    }
    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? NativeSidebarNode,
              let name = DialogService.requestText(title: "重命名", defaultValue: node.title), !name.isEmpty else { return }
        switch node.filter {
        case .collection(let id): configuration?.store.renameCollection(id: id, name: name)
        case .tag(let id): configuration?.store.renameTag(id: id, name: name)
        default: break
        }
    }
    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? NativeSidebarNode else { return }
        switch node.filter {
        case .collection(let id): configuration?.store.deleteCollection(id: id)
        case .tag(let id): configuration?.store.deleteTag(id: id)
        default: break
        }
    }
}

private final class NativePaperNode: NSObject {
    var paper: Paper
    var attachment: Attachment?
    let children: [NativePaperNode]
    init(paper: Paper, attachment: Attachment? = nil) {
        self.paper = paper
        self.attachment = attachment
        children = attachment == nil ? paper.attachments.map { NativePaperNode(paper: paper, attachment: $0) } : []
    }
}

final class NativePaperTableController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = LibraryOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private var configuration: NativeLibraryView?
    private var nodes: [NativePaperNode] = []
    private var expandedPaperIDs: Set<UUID> = []
    private var selectedAttachmentIDs: Set<UUID> = []
    private var lastAppliedSelection: Set<UUID> = []
    private var updating = false
    private let paperDragType = NSPasteboard.PasteboardType("com.papermanager.paper-ids")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/M/d"; return formatter
    }()
#if NATIVE_TABLE_SMOKE
    var smokeFullReloadCount: Int { outline.smokeFullReloadCount }
    var smokeRowReloadCount: Int { outline.smokeRowReloadCount }
#endif

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let columns: [(String, String, CGFloat)] = [
            ("title", "标题", 340), ("authors", "作者", 210), ("year", "年份", 58),
            ("source", "来源", 180), ("rating", "评分", 86), ("dateAdded", "添加日期", 105), ("notes", "备注", 180)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = PMLocalization.text(title)
            column.width = width
            column.minWidth = id == "title" ? 180 : 45
            if id != "notes" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "title" || id == "authors" || id == "source") }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.rowHeight = 25
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .controlBackgroundColor
        outline.autosaveName = "PaperManager.NativePaperColumns"
        outline.autosaveTableColumns = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.menuProvider = { [weak self] in self?.rowMenu() }
        outline.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setAccessibilityIdentifier("paper-table")
        let headerMenu = NSMenu()
        for column in outline.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = column; item.state = .on
            headerMenu.addItem(item)
        }
        headerMenu.addItem(.separator())
        let reset = NSMenuItem(title: PMLocalization.text("重置列"), action: #selector(resetColumns), keyEquivalent: "")
        reset.target = self; headerMenu.addItem(reset)
        outline.headerView?.menu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        emptyLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("paper-table-empty-title")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.setAccessibilityIdentifier("paper-table-empty-detail")
        for label in [emptyLabel, emptyDetail] { label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label) }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            emptyDetail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyDetail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            emptyDetail.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 10)
        ])
    }

    func configure(_ configuration: NativeLibraryView) {
        loadViewIfNeeded()
        // A stored Binding reads its current value, so keep a value snapshot of
        // the prior selection to detect external changes such as deep links.
        let revealSelection = lastAppliedSelection != configuration.selection
        lastAppliedSelection = configuration.selection
        if revealSelection { selectedAttachmentIDs.removeAll() }
        self.configuration = configuration
        updating = true
        defer { updating = false }
        let rowHeight: CGFloat = configuration.store.settings.tableDensity == .compact ? 25 : 34
        if outline.rowHeight != rowHeight { outline.rowHeight = rowHeight }
        let titles = ["title": "标题", "authors": "作者", "year": "年份", "source": "来源", "rating": "评分", "dateAdded": "添加日期", "notes": "备注"]
        for column in outline.tableColumns {
            let title = PMLocalization.text(titles[column.identifier.rawValue] ?? column.title)
            if column.title != title { column.title = title }
        }
        for item in outline.headerView?.menu?.items ?? [] {
            if let column = item.representedObject as? NSTableColumn { item.title = column.title }
            else if !item.isSeparatorItem { item.title = PMLocalization.text("重置列") }
        }
        // SwiftUI also configures this controller for selection, focus and status
        // changes. Preserve item identity and native reusable cells in those
        // updates; a full reload makes AX recreate every offscreen row.
        let sameStructure = nodes.count == configuration.papers.count && zip(nodes, configuration.papers).allSatisfy { node, paper in
            node.paper.id == paper.id && node.children.compactMap { $0.attachment?.id } == paper.attachments.map(\.id)
        }
        if !sameStructure {
            nodes = configuration.papers.map { NativePaperNode(paper: $0) }
            outline.reloadData()
            for node in nodes where expandedPaperIDs.contains(node.paper.id) { outline.expandItem(node) }
        } else {
            var changedRows = IndexSet()
            for (node, paper) in zip(nodes, configuration.papers) where node.paper != paper {
                node.paper = paper
                let row = outline.row(forItem: node)
                if row >= 0 { changedRows.insert(row) }
                for (child, attachment) in zip(node.children, paper.attachments) {
                    child.paper = paper
                    child.attachment = attachment
                    let childRow = outline.row(forItem: child)
                    if childRow >= 0 { changedRows.insert(childRow) }
                }
            }
            if !changedRows.isEmpty {
                outline.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
            }
        }
        var indexes = IndexSet()
        let papersWithSelectedAttachments = Set(nodes.filter { node in
            node.children.contains { child in child.attachment.map { selectedAttachmentIDs.contains($0.id) } ?? false }
        }.map { $0.paper.id })
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? NativePaperNode,
               configuration.selection.contains(node.paper.id) {
                if let attachment = node.attachment {
                    if selectedAttachmentIDs.contains(attachment.id) { indexes.insert(row) }
                } else if !papersWithSelectedAttachments.contains(node.paper.id) {
                    indexes.insert(row)
                }
            }
        }
        if indexes != outline.selectedRowIndexes { outline.selectRowIndexes(indexes, byExtendingSelection: false) }
        if revealSelection, let first = indexes.first { outline.scrollRowToVisible(first) }
        let expectedSort = NSSortDescriptor(key: configuration.sortDescriptor.field.rawValue, ascending: configuration.sortDescriptor.ascending)
        if outline.sortDescriptors.first != expectedSort { outline.sortDescriptors = [expectedSort] }
        emptyLabel.stringValue = PMLocalization.text(configuration.searchText.isEmpty ? "暂无文献" : "没有结果")
        emptyDetail.stringValue = PMLocalization.text(configuration.searchText.isEmpty ? "导入 PDF、BibTeX 文件，或通过 DOI 添加文献。" : "尝试其他标题、作者、来源或年份。")
        emptyLabel.isHidden = !nodes.isEmpty
        emptyDetail.isHidden = !nodes.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? NativePaperNode)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? NativePaperNode)?.children[index] ?? nodes[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? NativePaperNode)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NativePaperNode, let id = tableColumn?.identifier.rawValue else { return nil }
        let paper = node.paper
        if let attachment = node.attachment {
            let cell = NativeTextCell.reusable(in: outlineView, owner: self)
            cell.configure(symbol: id == "title" ? (attachment.kind == .pdf ? "doc.richtext" : "paperclip") : "",
                           text: id == "title" ? attachment.displayName : "")
            cell.textField?.font = .systemFont(ofSize: 13)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
        let text: String
        switch id {
        case "title": text = paper.displayTitle
        case "authors": text = paper.authors.joined(separator: "; ")
        case "year": text = paper.year.map(String.init) ?? ""
        case "source": text = paper.sourceDisplay
        case "rating":
            let cell = NativeRatingCell.reusable(in: outlineView, owner: self)
            cell.configure(rating: paper.rating, onChange: { [weak self] value in
                guard let store = self?.configuration?.store, var updated = store.paper(with: paper.id) else { return }
                updated.rating = value; store.updatePaper(updated)
            })
            return cell
        case "dateAdded": text = dateFormatter.string(from: paper.dateAdded)
        case "notes": text = paper.notes.replacingOccurrences(of: "\n", with: " ")
        default: text = ""
        }
        let cell = NativeTextCell.reusable(in: outlineView, owner: self)
        cell.configure(symbol: id == "title" ? (paper.hasPDF ? "doc.richtext" : "doc.text") : "", text: text)
        cell.textField?.font = .systemFont(ofSize: 13, weight: id == "title" ? .medium : .regular)
        cell.textField?.textColor = id == "title" ? .labelColor : .secondaryLabelColor
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        let ids = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NativePaperNode)?.paper.id })
        selectedAttachmentIDs = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NativePaperNode)?.attachment?.id })
        lastAppliedSelection = ids
        configuration?.selection = ids
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? NativePaperNode { expandedPaperIDs.insert(node.paper.id) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? NativePaperNode { expandedPaperIDs.remove(node.paper.id) }
    }
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updating, let descriptor = outline.sortDescriptors.first,
              let field = descriptor.key.flatMap(PaperSortField.init(rawValue:)) else { return }
        configuration?.sortDescriptor = PaperSortDescriptor(field: field, ascending: descriptor.ascending)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? NativePaperNode else { return nil }
        let pasteboardItem = NSPasteboardItem()
        let selectedIDs = configuration?.selection ?? []
        let ids = selectedIDs.contains(node.paper.id) ? selectedIDs : [node.paper.id]
        pasteboardItem.setString(ids.map(\.uuidString).sorted().joined(separator: ","), forType: paperDragType)
        return pasteboardItem
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        configuration?.onImportURLs(urls); return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: openSelected(); return true
        case 49:
            if let node = outline.item(atRow: outline.selectedRow) as? NativePaperNode,
               let attachment = node.attachment ?? configuration?.store.paper(with: node.paper.id)?.primaryPDF {
                useAttachment(attachment) { QuickLookService.shared.preview(url: $0) }
            }
            return true
        case 51, 117: deleteSelected(); return true
        default: return false
        }
    }
    private func selectedAttachment() -> Attachment? {
        (outline.item(atRow: outline.selectedRow) as? NativePaperNode)?.attachment
    }
    @objc private func openSelected() {
        if let attachment = selectedAttachment() {
            useAttachment(attachment) { NSWorkspace.shared.open($0) }
        }
        else { configuration?.onOpenSelected() }
    }
    @objc private func revealSelected() {
        if let attachment = selectedAttachment() { useAttachment(attachment) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
        else { configuration?.onRevealSelected() }
    }
    private func useAttachment(_ attachment: Attachment, body: (URL) -> Void) {
        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message(PMLocalization.text("附件不存在，可能已在访达中移动或删除。"))
                }
                body(url)
            }
        } catch { configuration?.store.statusMessage = PMLocalization.format("无法访问附件：%@", error.localizedDescription) }
    }
    @objc private func deleteSelected() {
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? NativePaperNode }
        guard !selected.isEmpty else { return }
        if selected.allSatisfy({ $0.attachment != nil }), let store = configuration?.store {
            let ids = Set(selected.compactMap { $0.attachment?.id })
            for paperID in Set(selected.map { $0.paper.id }) {
                guard var paper = store.paper(with: paperID) else { continue }
                paper.attachments.removeAll { ids.contains($0.id) }
                store.updatePaper(paper)
            }
            selectedAttachmentIDs.removeAll()
            store.statusMessage = PMLocalization.text("已移除附件链接，原文件保留在访达中。")
        } else { configuration?.onDeleteSelected() }
    }
    @objc private func refreshMetadata() { configuration?.onRefreshMetadata() }
    @objc private func exportBibTeX() { configuration?.onExportBibTeX() }
    @objc private func exportRIS() { configuration?.onExportRIS() }
    @objc private func exportDetailed() { configuration?.onExportDetailed() }
    @objc private func copyBibTeX() { if let configuration { ExportService.copyToPasteboard(ExportService.bibTeX(for: configuration.papers.filter { configuration.selection.contains($0.id) }, settings: configuration.store.settings, tags: configuration.store.tags)) } }
    @objc private func copyRIS() { if let configuration { ExportService.copyToPasteboard(ExportService.ris(for: configuration.papers.filter { configuration.selection.contains($0.id) }, settings: configuration.store.settings, tags: configuration.store.tags)) } }
    @objc private func organizeSelectedFiles() { performFileOperation(renameOnly: false) }
    @objc private func renameSelectedFiles() { performFileOperation(renameOnly: true) }
    private func performFileOperation(renameOnly: Bool) {
        guard let configuration, !configuration.selection.isEmpty else { return }
        PaperDraftSession.flushAll()
        do {
            if renameOnly { _ = try configuration.store.renameFiles(paperIDs: configuration.selection) }
            else { _ = try configuration.store.organizeFiles(paperIDs: configuration.selection) }
        } catch { configuration.store.statusMessage = error.localizedDescription }
    }
    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: PMLocalization.text(title), action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = configuration?.selection.isEmpty == false
            menu.addItem(item)
        }
        add(selectedAttachment() == nil ? "打开 PDF" : "打开附件", #selector(openSelected)); add("在访达中显示", #selector(revealSelected))
        add("整理文件到文库…", #selector(organizeSelectedFiles))
        add("按规则重命名文件…", #selector(renameSelectedFiles))
        menu.addItem(.separator()); add("刷新元数据", #selector(refreshMetadata))
        menu.addItem(.separator()); add("导出 BibTeX…", #selector(exportBibTeX)); add("导出 RIS…", #selector(exportRIS)); add("详细导出…", #selector(exportDetailed))
        add("拷贝 BibTeX", #selector(copyBibTeX)); add("拷贝 RIS", #selector(copyRIS))
        menu.addItem(.separator()); add(selectedAttachment() == nil ? "删除记录" : "移除附件链接", #selector(deleteSelected))
        return menu
    }
    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn, column != outline.outlineTableColumn else { return }
        column.isHidden.toggle(); sender.state = column.isHidden ? .off : .on
    }
    @objc private func resetColumns() {
        for column in outline.tableColumns { column.isHidden = false }
        for item in outline.headerView?.menu?.items ?? [] where item.representedObject is NSTableColumn { item.state = .on }
        let order = ["title", "authors", "year", "source", "rating", "dateAdded", "notes"]
        for (destination, id) in order.enumerated() {
            if let current = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) { outline.moveColumn(current, toColumn: destination) }
        }
    }
}

private final class LibraryOutlineView: NSOutlineView {
    var menuProvider: (() -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
#if NATIVE_TABLE_SMOKE
    private(set) var smokeFullReloadCount = 0
    private(set) var smokeRowReloadCount = 0
    override func reloadData() { smokeFullReloadCount += 1; super.reloadData() }
    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        smokeRowReloadCount += 1
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }
#endif
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return menuProvider?() ?? super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// AX asks the outline delegate for offscreen reusable cells many times. Avoid
/// invalidating AppKit's appearance/layout graph when their style is unchanged.
private final class NativeCellLabel: NSTextField {
    override var font: NSFont? {
        get { super.font }
        set { if super.font != newValue { super.font = newValue } }
    }

    override var textColor: NSColor? {
        get { super.textColor }
        set { if super.textColor != newValue { super.textColor = newValue } }
    }
}

private final class NativeTextCell: NSTableCellView {
    private let trailingLabel = NativeCellLabel(labelWithString: "")
    private static let reuseID = NSUserInterfaceItemIdentifier("NativeTextCell")
    private static var symbols: [String: NSImage] = [:]
    private var lastContent: (symbol: String, text: String, trailing: String)?

    static func reusable(in outline: NSOutlineView, owner: AnyObject) -> NativeTextCell {
        if let cell = outline.makeView(withIdentifier: reuseID, owner: owner) as? NativeTextCell { return cell }
        let cell = NativeTextCell()
        cell.identifier = reuseID
        return cell
    }

    init() {
        super.init(frame: .zero)
        let label = NativeCellLabel(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        textField = label; addSubview(label)
        let image = NSImageView()
        image.contentTintColor = .secondaryLabelColor
        image.setAccessibilityElement(false)
        imageView = image; addSubview(image)
        trailingLabel.font = .systemFont(ofSize: 11)
        trailingLabel.textColor = .tertiaryLabelColor
        trailingLabel.setAccessibilityElement(false)
        addSubview(trailingLabel)
        // One readable value replaces decorative descendants, while AppKit's
        // native row/cell wrappers still expose every row and table column.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityChildren([])
    }

    func configure(symbol: String = "", text: String, trailing: String = "") {
        if let old = lastContent, old.symbol == symbol, old.text == text, old.trailing == trailing { return }
        lastContent = (symbol, text, trailing)
        textField?.stringValue = text
        trailingLabel.stringValue = trailing
        imageView?.isHidden = symbol.isEmpty
        if !symbol.isEmpty {
            if Self.symbols[symbol] == nil { Self.symbols[symbol] = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            imageView?.image = Self.symbols[symbol]
        }
        imageView?.contentTintColor = .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let leading: CGFloat = imageView?.isHidden == false ? 23 : 0
        imageView?.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let trailingWidth = trailingLabel.stringValue.isEmpty ? 0 : min(bounds.width / 2, trailingLabel.intrinsicContentSize.width)
        trailingLabel.frame = NSRect(x: bounds.width - trailingWidth - 4, y: (bounds.height - 16) / 2, width: trailingWidth, height: 16)
        textField?.frame = NSRect(x: leading, y: (bounds.height - 18) / 2,
                                 width: max(0, bounds.width - leading - (trailingWidth > 0 ? trailingWidth + 9 : 0)), height: 18)
    }
    override func accessibilityValue() -> Any? {
        [textField?.stringValue ?? "", trailingLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class NativeRatingCell: NSTableCellView {
    private static let reuseID = NSUserInterfaceItemIdentifier("NativeRatingCell")
    let ratingControl = NativeStarRatingControl()

    static func reusable(in outline: NSOutlineView, owner: AnyObject) -> NativeRatingCell {
        if let cell = outline.makeView(withIdentifier: reuseID, owner: owner) as? NativeRatingCell { return cell }
        let cell = NativeRatingCell()
        cell.identifier = reuseID
        return cell
    }

    init() {
        super.init(frame: .zero)
        addSubview(ratingControl)
    }

    func configure(rating: Int, onChange: @escaping (Int) -> Void) {
        ratingControl.configure(rating: rating, onChange: onChange)
    }

    override func layout() {
        super.layout()
        ratingControl.frame = NSRect(x: 0, y: 0, width: min(76, bounds.width), height: bounds.height)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Five clickable stars with a single AppKit control and one AX slider. In
/// macOS 27, creating image NSButtons can invoke a SwiftUI sizing graph even
/// when the buttons are borderless; never do that while AX materializes rows.
final class NativeStarRatingControl: NSControl {
    private(set) var rating = 0
    private var onChange: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 25))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 5))
    }

    func configure(rating: Int, onChange: @escaping (Int) -> Void) {
        self.rating = min(5, max(0, rating))
        self.onChange = onChange
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = min(15, bounds.width / 5)
        for index in 0..<5 {
            let center = NSPoint(x: step * (CGFloat(index) + 0.5), y: bounds.midY)
            let path = NSBezierPath()
            for point in 0..<10 {
                let angle = CGFloat.pi / 2 + CGFloat(point) * CGFloat.pi / 5
                let radius: CGFloat = point.isMultiple(of: 2) ? 5.8 : 2.6
                let vertex = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if point == 0 { path.move(to: vertex) } else { path.line(to: vertex) }
            }
            path.close()
            if index < rating {
                NSColor.systemYellow.setFill(); path.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke(); path.lineWidth = 1; path.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        window?.makeFirstResponder(self)
        let value = min(5, max(1, Int(point.x / max(1, min(15, bounds.width / 5))) + 1))
        commit(value == rating ? 0 : value)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 123, 125: commit(rating - 1)
        case 124, 126: commit(rating + 1)
        case 51, 117: commit(0)
        default:
            if let text = event.charactersIgnoringModifiers, let value = Int(text), (0...5).contains(value) { commit(value) }
            else { super.keyDown(with: event) }
        }
    }

    private func commit(_ value: Int) {
        guard isEnabled else { return }
        let value = min(5, max(0, value))
        guard value != rating else { return }
        rating = value
        needsDisplay = true
        onChange?(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityLabel() -> String? { PMLocalization.text("评分") }
    override func accessibilityValue() -> Any? { NSNumber(value: rating) }
    override func accessibilityValueDescription() -> String? { PMLocalization.format("%lld 星", rating) }

    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber else { return }
        commit(number.intValue)
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled, rating < 5 else { return false }
        commit(rating + 1); return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled, rating > 0 else { return false }
        commit(rating - 1); return true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension NSColor {
    convenience init(pmHex: String) {
        var value: UInt64 = 0
        Scanner(string: pmHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
