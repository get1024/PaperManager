import AppKit

/// Paint a complete row while AppKit clips it to the table viewport.
/// Preserve native emphasis and AX semantics without an inset or corner radius.
final class NativePaperRowView: NSTableRowView {
    private static let reuseID = NSUserInterfaceItemIdentifier("NativePaperRowView")

    static func reusable(in outline: NSOutlineView, owner: AnyObject) -> NativePaperRowView {
        if let row = outline.makeView(withIdentifier: reuseID, owner: owner) as? NativePaperRowView { return row }
        let row = NativePaperRowView(frame: .zero)
        row.identifier = reuseID
        return row
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        // The row backing can be reused after horizontal scrolling or pane
        // resizing. Painting only visibleRect leaves newly exposed columns blank.
        guard !bounds.isEmpty else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

final class LibraryOutlineView: NSOutlineView {
    var preservesHorizontalPositionOnSelection = false
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
    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        let clip = preservesHorizontalPositionOnSelection ? enclosingScrollView?.contentView : nil
        let horizontalOffset = clip?.bounds.origin.x
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        restoreHorizontalOffset(horizontalOffset, in: clip)
    }

    override func scrollRowToVisible(_ row: Int) {
        let clip = preservesHorizontalPositionOnSelection ? enclosingScrollView?.contentView : nil
        let horizontalOffset = clip?.bounds.origin.x
        super.scrollRowToVisible(row)
        restoreHorizontalOffset(horizontalOffset, in: clip)
    }

    private func restoreHorizontalOffset(_ offset: CGFloat?, in clip: NSClipView?) {
        guard let offset, let clip, abs(clip.bounds.origin.x - offset) > 0.1 else { return }
        var bounds = clip.bounds
        bounds.origin.x = offset
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return menuProvider?() ?? super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

final class NativePaperHeaderCell: NSTableHeaderCell {
    private let leadingInset: CGFloat

    init(textCell: String, isOutlineColumn: Bool) {
        leadingInset = isOutlineColumn ? 6.5 : 3.5
        super.init(textCell: textCell)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Match the reference header's interior insets while preserving native
        // column dividers, hit regions and accessibility labels.
        var textFrame = cellFrame
        textFrame.origin.x += leadingInset
        textFrame.size.width = max(0, textFrame.width - leadingInset)
        super.drawInterior(withFrame: textFrame, in: controlView)
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

final class NativeTextCell: NSTableCellView {
    private let trailingLabel = NativeCellLabel(labelWithString: "")
    private static let reuseID = NSUserInterfaceItemIdentifier("NativeTextCell")
    private static var symbols: [String: NSImage] = [:]
    private var lastContent: (symbol: String, text: String, trailing: String)?
    private var normalTextColor = NSColor.labelColor
    private var normalSymbolColor = NSColor.secondaryLabelColor
    private var emphasizedTextColor = NSColor.selectedControlTextColor
    var contentLeadingInset: CGFloat = 0
    var imageTextOffset: CGFloat = 23
    var trailingInset: CGFloat = 4 { didSet { if trailingInset != oldValue { needsLayout = true } } }
    var textVerticalOffset: CGFloat = 0 { didSet { if textVerticalOffset != oldValue { needsLayout = true } } }
    var trailingVerticalOffset: CGFloat = 0 { didSet { if trailingVerticalOffset != oldValue { needsLayout = true } } }
    var symbolHorizontalOffset: CGFloat = 0 { didSet { if symbolHorizontalOffset != oldValue { needsLayout = true } } }
    var symbolVerticalOffset: CGFloat = 0 { didSet { if symbolVerticalOffset != oldValue { needsLayout = true } } }
    var symbolPointSize: CGFloat? {
        didSet { if symbolPointSize != oldValue { updateSymbolImage() } }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateForegroundColors() }
    }

    func setTextStyle(font: NSFont, color: NSColor, symbolColor: NSColor = .secondaryLabelColor,
                      selectedTextColor: NSColor = .selectedControlTextColor) {
        textField?.font = font
        normalTextColor = color
        normalSymbolColor = symbolColor
        emphasizedTextColor = selectedTextColor
        updateForegroundColors()
    }

    private func updateForegroundColors() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? emphasizedTextColor : normalTextColor
        trailingLabel.textColor = selected ? .selectedControlTextColor : .tertiaryLabelColor
        let symbolColor: NSColor = selected ? .selectedControlTextColor : normalSymbolColor
        if imageView?.contentTintColor != symbolColor { imageView?.contentTintColor = symbolColor }
    }

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
        trailingLabel.alignment = .right
        trailingLabel.usesSingleLineMode = true
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
        updateSymbolImage()
        updateForegroundColors()
        needsLayout = true
    }

    private func updateSymbolImage() {
        guard let symbol = lastContent?.symbol else { return }
        if !symbol.isEmpty {
            let pointSize = symbolPointSize ?? (symbol == "circle.fill" ? 8 : nil)
            let cacheKey = "\(symbol):\(pointSize.map(String.init(describing:)) ?? "default")"
            if Self.symbols[cacheKey] == nil {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                Self.symbols[cacheKey] = pointSize.map {
                    image?.withSymbolConfiguration(.init(pointSize: $0, weight: .regular))
                } ?? image
            }
            imageView?.image = Self.symbols[cacheKey]
        }
    }

    override func layout() {
        super.layout()
        let leading: CGFloat = contentLeadingInset + (imageView?.isHidden == false ? imageTextOffset : 0)
        imageView?.frame = NSRect(x: contentLeadingInset + symbolHorizontalOffset, y: (bounds.height - 16) / 2 + symbolVerticalOffset, width: 16, height: 16)
        // NSTextField still insets its drawing rect. A tight intrinsic width
        // can clip the last digit, especially at fractional backing pixels.
        let trailingWidth = trailingLabel.stringValue.isEmpty ? 0 : min(bounds.width / 2, ceil(trailingLabel.intrinsicContentSize.width) + 4)
        trailingLabel.frame = NSRect(x: bounds.width - trailingWidth - trailingInset, y: (bounds.height - 16) / 2 + trailingVerticalOffset, width: trailingWidth, height: 16)
        textField?.frame = NSRect(x: leading, y: (bounds.height - 18) / 2 + textVerticalOffset,
                                 width: max(0, bounds.width - leading - (trailingWidth > 0 ? trailingWidth + 9 : 0)), height: 18)
    }
    override func accessibilityValue() -> Any? {
        [textField?.stringValue ?? "", trailingLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class NativeRatingCell: NSTableCellView {
    private static let reuseID = NSUserInterfaceItemIdentifier("NativeRatingCell")
    let ratingControl = NativeStarRatingControl()

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { ratingControl.usesSelectedColors = backgroundStyle == .emphasized }
    }

    static func reusable(in outline: NSOutlineView, owner: AnyObject) -> NativeRatingCell {
        if let cell = outline.makeView(withIdentifier: reuseID, owner: owner) as? NativeRatingCell { return cell }
        let cell = NativeRatingCell()
        cell.identifier = reuseID
        return cell
    }

    init() {
        super.init(frame: .zero)
        ratingControl.setStarGeometry(size: 9.5, spacing: 4.5)
        ratingControl.usesTableStyle = true
        ratingControl.drawingVerticalOffset = 1.5
        addSubview(ratingControl)
    }

    func configure(rating: Int, identity: UUID? = nil, onChange: @escaping (Int) -> Void) {
        ratingControl.configure(rating: rating, identity: identity, onChange: onChange)
    }

    override func layout() {
        super.layout()
        ratingControl.frame = NSRect(x: 5, y: 0, width: min(70, max(0, bounds.width - 5)), height: bounds.height)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
