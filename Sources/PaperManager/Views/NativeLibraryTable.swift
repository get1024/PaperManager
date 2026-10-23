import AppKit
import SwiftUI

@MainActor
final class NativePaperSelectionCommands: ObservableObject {
    enum Command { case open, quickLook, reveal, delete }
    fileprivate weak var controller: NativePaperTableController?

    @discardableResult
    func perform(_ command: Command) -> Bool { controller?.performApplicationCommand(command) ?? false }
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
    private static let columnLayoutDefaultsKey = "PaperManager.NativePaperColumnLayout.v2"
    private static let defaultColumns: [(id: String, title: String, width: CGFloat)] = [
        ("title", "标题", 452), ("authors", "作者", 123), ("year", "年份", 63),
        ("source", "来源", 103), ("rating", "评分", 89), ("dateAdded", "添加日期", 103), ("notes", "备注", 147)
    ]
    private var restoringColumnLayout = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/M/d"; return formatter
    }()
#if NATIVE_TABLE_SMOKE
    var smokeFullReloadCount: Int { outline.smokeFullReloadCount }
    var smokeRowReloadCount: Int { outline.smokeRowReloadCount }
#endif

    override func loadView() {
        // The center section needs its own window material behind the toolbar;
        // otherwise the outer split's default sidebar decoration leaks past
        // the inner sidebar divider.
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        view = background
        for (id, title, width) in Self.defaultColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.headerCell = NativePaperHeaderCell(textCell: "", isOutlineColumn: id == "title")
            column.title = PMLocalization.text(title)
            column.headerCell.font = .systemFont(ofSize: 12, weight: .semibold)
            column.width = width
            column.minWidth = id == "title" ? 180 : 45
            if id != "notes" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "title" || id == "authors" || id == "source") }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        // Expanding attachments must not add their indentation to the title
        // column's width and move every following column.
        outline.autoresizesOutlineColumn = false
        outline.style = .inset
        outline.preservesHorizontalPositionOnSelection = true
        outline.rowHeight = 27
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .controlBackgroundColor
        // A single versioned layout owns widths/order/visibility. AppKit's old
        // autosave restores obsolete widths before our layout can be applied.
        outline.autosaveTableColumns = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.menuProvider = { [weak self] in self?.rowMenu() }
        outline.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setAccessibilityIdentifier("paper-table")
        restoreColumnLayout()
        let headerMenu = NSMenu()
        for column in outline.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = column
            item.state = column.isHidden ? .off : .on
            item.isEnabled = column != outline.outlineTableColumn
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
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        if self.configuration?.selectionCommands !== configuration.selectionCommands,
           self.configuration?.selectionCommands?.controller === self {
            self.configuration?.selectionCommands?.controller = nil
        }
        configuration.selectionCommands?.controller = self
        let revealSelection = lastAppliedSelection != configuration.selection
        lastAppliedSelection = configuration.selection
        if revealSelection { selectedAttachmentIDs.removeAll() }
        self.configuration = configuration
        updating = true
        defer { updating = false }
        let rowHeight: CGFloat = configuration.store.settings.tableDensity == .compact ? 27 : 34
        if outline.rowHeight != rowHeight { outline.rowHeight = rowHeight }
        for defaults in Self.defaultColumns {
            guard let column = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(defaults.id)) else { continue }
            let title = PMLocalization.text(defaults.title)
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
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        NativePaperRowView.reusable(in: outlineView, owner: self)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NativePaperNode, let id = tableColumn?.identifier.rawValue else { return nil }
        let paper = node.paper
        if let attachment = node.attachment {
            let cell = NativeTextCell.reusable(in: outlineView, owner: self)
            cell.configure(symbol: id == "title" ? (attachment.kind == .pdf ? "doc.richtext" : "paperclip") : "",
                           text: id == "title" ? attachment.displayName : "")
            cell.contentLeadingInset = id == "title" ? 5 : 0
            cell.setTextStyle(font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            return cell
        }
        let text: String
        switch id {
        case "title": text = paper.displayTitle
        case "authors": text = authorSummary(paper.authors)
        case "year": text = paper.year.map(String.init) ?? "—"
        case "source": text = paper.sourceDisplay.nilIfBlank ?? "—"
        case "rating":
            let cell = NativeRatingCell.reusable(in: outlineView, owner: self)
            cell.configure(rating: paper.rating, onChange: { [weak self, weak cell] value in
                guard let store = self?.configuration?.store, var updated = store.paper(with: paper.id) else { return }
                updated.rating = value
                if !store.updatePaper(updated) {
                    cell?.ratingControl.restoreRating(store.paper(with: paper.id)?.rating ?? paper.rating)
                }
            })
            return cell
        case "dateAdded": text = dateFormatter.string(from: paper.dateAdded)
        case "notes": text = paper.notes.replacingOccurrences(of: "\n", with: " ")
        default: text = ""
        }
        let cell = NativeTextCell.reusable(in: outlineView, owner: self)
        cell.configure(symbol: id == "title" ? "doc.text" : "", text: text)
        cell.contentLeadingInset = id == "title" ? 5 : 0
        cell.setTextStyle(font: .systemFont(ofSize: id == "title" ? 13 : 12.5, weight: .regular),
                          color: id == "title" ? .labelColor : .secondaryLabelColor)
        return cell
    }
    private func authorSummary(_ authors: [String]) -> String {
        guard let first = authors.first else { return "—" }
        if authors.count == 1 { return first }
        if authors.count == 2 { return "\(first) & \(authors[1])" }
        return "\(first) et al."
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
        case 49: quickLookSelected(); return true
        case 51, 117: deleteSelected(); return true
        default: return false
        }
    }
    private func selectedAttachment() -> Attachment? {
        (outline.item(atRow: outline.selectedRow) as? NativePaperNode)?.attachment
    }
    fileprivate func performApplicationCommand(_ command: NativePaperSelectionCommands.Command) -> Bool {
        guard outline.selectedRow >= 0 else { return false }
        switch command {
        case .open: openSelected()
        case .quickLook: quickLookSelected()
        case .reveal: revealSelected()
        case .delete: deleteSelected()
        }
        return true
    }

    private func quickLookSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? NativePaperNode,
              let store = configuration?.store,
              let attachment = node.attachment ?? store.paper(with: node.paper.id)?.primaryPDF else { return }
        useAttachment(attachment) { url in
            QuickLookService.shared.preview(url: url)
            if attachment.id == store.paper(with: node.paper.id)?.primaryPDF?.id { store.markOpened(node.paper.id) }
        }
    }
    @objc private func openSelected() {
        if let attachment = selectedAttachment() {
            if attachment.kind == .pdf,
               let node = outline.item(atRow: outline.selectedRow) as? NativePaperNode,
               let store = configuration?.store {
                guard PaperDraftSession.flushAll() else { return }
                PaperReaderActions.openPDF(node.paper, attachment: attachment, store: store)
            } else { useAttachment(attachment) { NSWorkspace.shared.open($0) } }
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
                guard store.updatePaper(paper) else { return }
            }
            selectedAttachmentIDs.removeAll()
            store.statusMessage = PMLocalization.text("已移除附件链接，原文件保留在访达中。")
        } else { configuration?.onDeleteSelected() }
    }
    @objc private func refreshMetadata() { configuration?.onRefreshMetadata() }
    @objc private func exportBibTeX() { configuration?.onExportBibTeX() }
    @objc private func exportRIS() { configuration?.onExportRIS() }
    @objc private func exportDetailed() { configuration?.onExportDetailed() }
    @objc private func copyBibTeX() {
        guard let configuration, PaperDraftSession.flushAll() else { return }
        let papers = configuration.store.papers.filter { configuration.selection.contains($0.id) }
        ExportService.copyToPasteboard(ExportService.bibTeX(for: papers, settings: configuration.store.settings, tags: configuration.store.tags))
    }
    @objc private func copyRIS() {
        guard let configuration, PaperDraftSession.flushAll() else { return }
        let papers = configuration.store.papers.filter { configuration.selection.contains($0.id) }
        ExportService.copyToPasteboard(ExportService.ris(for: papers, settings: configuration.store.settings, tags: configuration.store.tags))
    }
    @objc private func organizeSelectedFiles() { performFileOperation(renameOnly: false) }
    @objc private func renameSelectedFiles() { performFileOperation(renameOnly: true) }
    private func performFileOperation(renameOnly: Bool) {
        guard let configuration, !configuration.selection.isEmpty else { return }
        guard PaperDraftSession.flushAll() else { return }
        _ = configuration.store.enqueueFileOperation(paperIDs: configuration.selection, renameOnly: renameOnly)
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
    func outlineViewColumnDidMove(_ notification: Notification) { persistColumnLayout() }
    func outlineViewColumnDidResize(_ notification: Notification) { persistColumnLayout() }

    private func restoreColumnLayout() {
        guard let saved = UserDefaults.standard.array(forKey: Self.columnLayoutDefaultsKey) as? [[String: Any]] else {
            resetColumns()
            return
        }
        restoringColumnLayout = true
        defer { restoringColumnLayout = false }
        var restoredIDs = Set<String>()
        var destination = 0
        for entry in saved {
            guard let id = entry["id"] as? String, restoredIDs.insert(id).inserted,
                  let current = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { continue }
            outline.moveColumn(current, toColumn: destination)
            let column = outline.tableColumns[destination]
            if let width = (entry["width"] as? NSNumber)?.doubleValue, width.isFinite {
                column.width = min(column.maxWidth, max(column.minWidth, CGFloat(width)))
            }
            column.isHidden = id != "title" && (entry["hidden"] as? Bool ?? false)
            destination += 1
        }
    }

    private func persistColumnLayout() {
        guard !restoringColumnLayout else { return }
        let layout: [[String: Any]] = outline.tableColumns.map {
            ["id": $0.identifier.rawValue, "width": Double($0.width), "hidden": $0.isHidden]
        }
        UserDefaults.standard.set(layout, forKey: Self.columnLayoutDefaultsKey)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn, column != outline.outlineTableColumn else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
        persistColumnLayout()
    }

    @objc private func resetColumns() {
        restoringColumnLayout = true
        for (destination, defaults) in Self.defaultColumns.enumerated() {
            guard let current = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == defaults.id }) else { continue }
            outline.moveColumn(current, toColumn: destination)
            let column = outline.tableColumns[destination]
            column.isHidden = false
            column.width = defaults.width
        }
        for item in outline.headerView?.menu?.items ?? [] where item.representedObject is NSTableColumn { item.state = .on }
        restoringColumnLayout = false
        persistColumnLayout()
    }
}
