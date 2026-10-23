import AppKit
import SwiftUI

private struct NativeLibraryTaskFooter: View {
    @ObservedObject var store: LibraryStore
    @State private var dismissedMetadata: MetadataRefreshProgress?

    private var visibleMetadataProgress: MetadataRefreshProgress? {
        guard let progress = store.metadataRefreshProgress, progress != dismissedMetadata,
              progress.isRunning || progress.failed > 0 || progress.cancelled else { return nil }
        return progress
    }

    private var hasContent: Bool {
        visibleMetadataProgress != nil || store.fileOperationProgress?.isRunning == true ||
            store.statusMessage.map { !$0.isEmpty } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = visibleMetadataProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(PMLocalization.format("元数据：%lld / %lld，更新 %lld，失败 %lld", progress.completed, progress.total, progress.updated, progress.failed))
                        Spacer(minLength: 2)
                        if progress.isRunning {
                            Button { store.cancelMetadataRefresh() } label: { Image(systemName: "xmark.circle") }
                                .help("停止刷新").accessibilityIdentifier("metadata-refresh-cancel")
                        } else {
                            if progress.failed > 0 {
                                Button { store.retryFailedMetadataRefresh() } label: { Image(systemName: "arrow.clockwise") }
                                    .help("重试失败项").accessibilityIdentifier("metadata-refresh-retry")
                            }
                            Button { dismissedMetadata = progress } label: { Image(systemName: "xmark") }.help("关闭")
                        }
                    }
                    if progress.isRunning {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    }
                }
            }
            if let progress = store.fileOperationProgress, progress.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(PMLocalization.format("文件：%lld / %lld", progress.processed, progress.total))
                        Spacer(minLength: 2)
                        Button { store.cancelFileOperation() } label: { Image(systemName: "xmark.circle") }
                            .help("停止整理").accessibilityIdentifier("file-operation-cancel")
                    }
                    ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                }
            }
            if let message = store.statusMessage, !message.isEmpty {
                Text(message).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Empty task content must not reserve a permanent strip underneath
        // the source list. Preserve this spacing only while content is shown.
        .padding(.top, hasContent ? 8 : 0)
        .padding(.bottom, hasContent ? 12 : 0)
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
    var isSection: Bool { filter == nil }

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

final class NativeSidebarController: NSViewController, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let outline = LibraryOutlineView()
    private let search = NSSearchField()
    private let taskFooter = NSHostingView(rootView: AnyView(EmptyView()))
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
        // NSSplitViewItem's sidebar role supplies the system pane material.
        // A second visual effect here obscures its full-height glass background.
        view = NSView()
        view.setAccessibilityIdentifier("sidebar-root")

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
        outline.rowHeight = 32
        outline.intercellSpacing = NSSize(width: 0, height: 0)
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

        taskFooter.sizingOptions = [.intrinsicContentSize]
        taskFooter.setAccessibilityIdentifier("library-task-footer")
        taskFooter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taskFooter)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            search.heightAnchor.constraint(equalToConstant: 25),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: taskFooter.topAnchor),
            taskFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            taskFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            taskFooter.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func configure(_ configuration: NativeLibraryView) {
        loadViewIfNeeded()
        self.configuration = configuration
        updating = true
        defer { updating = false }
        search.placeholderString = PMLocalization.text("搜索文献")
        if search.stringValue != configuration.searchText { search.stringValue = configuration.searchText }
        taskFooter.rootView = AnyView(NativeLibraryTaskFooter(store: configuration.store))
        let store = configuration.store
        let counts = store.sidebarCounts(includeSubcollections: configuration.includeSubcollections)
        func filterNode(_ id: String, _ title: String, _ symbol: String, _ filter: LibraryFilter, count: Int) -> NativeSidebarNode {
            NativeSidebarNode(id: id, title: title, symbol: symbol, filter: filter,
                count: count)
        }
        let library = NativeSidebarNode(id: "library", title: PMLocalization.text("文库"), children: [
            filterNode("all", PMLocalization.text("全部文献"), "books.vertical", .all, count: counts.all),
            filterNode("unfiled", PMLocalization.text("未归类"), "tray", .unfiled, count: counts.unfiled),
            filterNode("missingIDs", PMLocalization.text("缺少标识符"), "exclamationmark.magnifyingglass", .missingIDs, count: counts.missingIDs),
            filterNode("missingPDF", PMLocalization.text("缺少 PDF"), "paperclip", .missingPDF, count: counts.missingPDF)
        ])
        func collections(parent: UUID?, visited: Set<UUID> = []) -> [NativeSidebarNode] {
            store.collections.filter { $0.parentID == parent && !visited.contains($0.id) }
                .sorted { $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex }
                .map { collection in
                    let node = filterNode(collection.id.uuidString, collection.name, "folder", .collection(collection.id),
                                          count: counts.collections[collection.id, default: 0])
                    node.children = collections(parent: collection.id, visited: visited.union([collection.id]))
                    return node
                }
        }
        let collectionSection = NativeSidebarNode(id: "collections", title: PMLocalization.text("文集"), children:
            collections(parent: nil))
        let tagSection = NativeSidebarNode(id: "tags", title: PMLocalization.text("标签"), children: store.tags.map { tag in
            NativeSidebarNode(id: tag.id.uuidString, title: tag.name, symbol: "circle.fill", filter: .tag(tag.id),
                count: counts.tags[tag.id, default: 0], color: NSColor(pmHex: tag.colorHex))
        })
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
        updateSidebarSelectionFonts()
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
        return node.filter != nil
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? NativeSidebarNode)?.isSection ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? NativeSidebarNode)?.isSection == true ? 18 : 32
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NativeSidebarNode else { return nil }
        let cell = NativeTextCell.reusable(in: outlineView, owner: self)
        cell.configure(symbol: node.symbol, text: node.title, trailing: node.count > 0 ? String(node.count) : "")
        cell.contentLeadingInset = node.isSection ? 2 : 5
        cell.imageTextOffset = 21
        cell.setTextStyle(font: .systemFont(ofSize: node.isSection ? 10 : 13,
                                          weight: node.isSection || outlineView.isRowSelected(outlineView.row(forItem: item)) ? .semibold : .regular),
                          color: node.isSection ? .secondaryLabelColor : .labelColor,
                          symbolColor: node.color ?? (node.isSection ? .secondaryLabelColor : .systemBlue))
        cell.setAccessibilityIdentifier("sidebar-\(node.id)")
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateSidebarSelectionFonts()
        guard !updating, let node = outline.item(atRow: outline.selectedRow) as? NativeSidebarNode else { return }
        if let filter = node.filter { configuration?.selectedFilter = filter }
    }
    private func updateSidebarSelectionFonts() {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NativeSidebarNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeTextCell else { continue }
            cell.textField?.font = .systemFont(ofSize: node.isSection ? 10 : 13,
                                              weight: node.isSection || outline.isRowSelected(row) ? .semibold : .regular)
        }
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

private extension NSColor {
    convenience init(pmHex: String) {
        var value: UInt64 = 0
        Scanner(string: pmHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
