import AppKit

/// Keep native row selection, emphasis and AX semantics within the visible
/// table viewport when columns overflow.
/// The floating reference fills that viewport without an inset or corner radius.
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
        let viewport = visibleRect.width > 0 ? visibleRect : bounds
        let selection = NSRect(x: viewport.minX, y: bounds.minY,
                               width: max(0, viewport.width), height: bounds.height)
        guard selection.width > 0 else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(rect: selection).fill()
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
    var contentLeadingInset: CGFloat = 0
    var imageTextOffset: CGFloat = 23

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateForegroundColors() }
    }

    func setTextStyle(font: NSFont, color: NSColor, symbolColor: NSColor = .secondaryLabelColor) {
        textField?.font = font
        normalTextColor = color
        normalSymbolColor = symbolColor
        updateForegroundColors()
    }

    private func updateForegroundColors() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .selectedControlTextColor : normalTextColor
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
        if !symbol.isEmpty {
            if Self.symbols[symbol] == nil {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                Self.symbols[symbol] = symbol == "circle.fill"
                    ? image?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular)) : image
            }
            imageView?.image = Self.symbols[symbol]
        }
        updateForegroundColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let leading: CGFloat = contentLeadingInset + (imageView?.isHidden == false ? imageTextOffset : 0)
        imageView?.frame = NSRect(x: contentLeadingInset, y: (bounds.height - 16) / 2, width: 16, height: 16)
        // NSTextField still insets its drawing rect. A tight intrinsic width
        // can clip the last digit, especially at fractional backing pixels.
        let trailingWidth = trailingLabel.stringValue.isEmpty ? 0 : min(bounds.width / 2, ceil(trailingLabel.intrinsicContentSize.width) + 4)
        trailingLabel.frame = NSRect(x: bounds.width - trailingWidth - 4, y: (bounds.height - 16) / 2, width: trailingWidth, height: 16)
        textField?.frame = NSRect(x: leading, y: (bounds.height - 18) / 2,
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
    var usesSelectedColors = false {
        didSet { if usesSelectedColors != oldValue { needsDisplay = true } }
    }
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

    func restoreRating(_ value: Int) {
        rating = min(5, max(0, value))
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
                NSColor.systemOrange.setFill(); path.fill()
            } else {
                let color = usesSelectedColors ? NSColor.selectedControlTextColor.withAlphaComponent(0.7) : .tertiaryLabelColor
                color.setStroke(); path.lineWidth = 1; path.stroke()
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
