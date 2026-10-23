import AppKit
import SwiftUI

/// Keep the inspector's typeset text while idle. Editing is local to the value,
/// rather than requiring the inspector's bulk-edit pencil to be enabled first.
struct InspectorInlineEditor: View {
    @Binding var text: String
    var placeholder = ""
    var font: Font = .system(size: 13)
    var nativeFont: NSFont = .systemFont(ofSize: 13)
    var color: Color = .secondary
    var multiline = false
    var lineSpacing: CGFloat = 0
    var editingLineSpacing: CGFloat? = nil
    var identifier: String
    var isBulkEditing = false
    var selectAllOnActivation = true
    var highlightInset: CGFloat = 6
    var highlightInsets: EdgeInsets? = nil
    var isCurrent: () -> Bool = { true }
    var onCommit: () -> Bool
    @State private var isLocallyEditing = false
    @State private var isFocused = false

    private var isEditing: Bool { isBulkEditing || isLocallyEditing }

    var body: some View {
        Group {
            if isEditing {
                InspectorNativeField(text: $text, font: nativeFont,
                                     multiline: multiline, lineSpacing: lineSpacing,
                                     editingLineSpacing: editingLineSpacing,
                                     identifier: identifier, requestFocus: isLocallyEditing,
                                     selectAll: selectAllOnActivation,
                                     endsEditingOnTab: isLocallyEditing && !isBulkEditing,
                                     isCurrent: isCurrent,
                                     onCommit: onCommit,
                                     onFocusChange: { isFocused = $0 },
                                     onEndEditing: { isLocallyEditing = false })
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? (placeholder.isEmpty ? " " : placeholder) : text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineSpacing(lineSpacing)
                        .lineLimit(multiline ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { activate() }
                // Give the whole value a single activation target. Native
                // text selection starts in the active field editor.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .accessibilityAction { activate() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            InspectorInlineHighlight(isFocused: isFocused)
                .padding(highlightPadding)
                .allowsHitTesting(false)
        }
        .onChange(of: isBulkEditing) { _, value in
            if !value {
                isLocallyEditing = false
                isFocused = false
            }
        }
    }

    private func activate() {
        guard isCurrent() else { return }
        isLocallyEditing = true
    }

    private var highlightPadding: EdgeInsets {
        let insets = highlightInsets ?? EdgeInsets(top: highlightInset, leading: highlightInset,
                                                   bottom: highlightInset, trailing: highlightInset)
        return EdgeInsets(top: -insets.top, leading: -insets.leading,
                          bottom: -insets.bottom, trailing: -insets.trailing)
    }
}

private struct InspectorInlineHighlight: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> InspectorInlineHighlightView {
        InspectorInlineHighlightView(frame: .zero)
    }

    func updateNSView(_ view: InspectorInlineHighlightView, context: Context) {
        view.isFocused = isFocused
    }
}

/// Tracking belongs to the value's own view and does not move the system mouse.
/// It stays out of hit testing/accessibility so text keeps its native actions.
final class InspectorInlineHighlightView: NSView {
    private(set) var isHovered = false
    var isFocused = false { didSet { if oldValue != isFocused { needsDisplay = true } } }
    var hasVisibleBorder: Bool { isFocused || isHovered }
    private var hoverArea: NSTrackingArea?
    private var lifecycleObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { lifecycleObservers.forEach(NotificationCenter.default.removeObserver) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        setHovered(false)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification] {
                observeLifecycle(name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observeLifecycle(name, object: NSApp)
            }
        }
        refreshHoverFromPointer()
        needsDisplay = true
    }

    private func observeLifecycle(_ name: Notification.Name, object: AnyObject) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.activityDidChange(notification) }
        }
        lifecycleObservers.append(observer)
    }

    private func activityDidChange(_ notification: Notification) {
        if let owner = notification.object as? NSWindow, owner !== window { return }
        if [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
            NSApplication.didResignActiveNotification].contains(notification.name) {
            setHovered(false)
        } else {
            refreshHoverFromPointer()
        }
        // Losing activation changes presentation, not native editor ownership.
        // Keep logical focus so its feedback can return with the same editor.
        needsDisplay = true
    }

    private func refreshHoverFromPointer() {
        guard let window, window.isKeyWindow, NSApp.isActive,
              !isHiddenOrHasHiddenAncestor, !hoverRect.isEmpty else {
            setHovered(false)
            return
        }
        setHovered(hoverRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    // SwiftUI can expose the hosting viewport as a background view's
    // visibleRect, extending beyond this value's actual bounds.
    private var hoverRect: NSRect { bounds.intersection(visibleRect) }

    private func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        if !hoverRect.isEmpty {
            let area = NSTrackingArea(rect: hoverRect,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
            hoverArea = area
            addTrackingArea(area)
        }
        // Replacing an area does not promise an exit from its previous rect.
        // Re-evaluate the current viewport even when the pointer is stationary.
        refreshHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        if let window, !window.isKeyWindow || !NSApp.isActive { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let window, !window.isKeyWindow || !NSApp.isActive { return }
        guard hasVisibleBorder else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isFocused ? NSColor.controlBackgroundColor.withAlphaComponent(0.65) :
            NSColor.labelColor.withAlphaComponent(0.045)).setFill()
        path.fill()
        (isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.65) :
            NSColor.labelColor.withAlphaComponent(0.085)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private struct InspectorNativeField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let multiline: Bool
    let lineSpacing: CGFloat
    let editingLineSpacing: CGFloat?
    let identifier: String
    let requestFocus: Bool
    let selectAll: Bool
    let endsEditingOnTab: Bool
    let isCurrent: () -> Bool
    let onCommit: () -> Bool
    let onFocusChange: (Bool) -> Void
    let onEndEditing: () -> Void

    func makeNSView(context: Context) -> InspectorInlineTextField {
        InspectorInlineTextField(frame: .zero)
    }

    func updateNSView(_ field: InspectorInlineTextField, context: Context) {
        field.configure(text: text, font: font, color: .labelColor,
                        multiline: multiline, lineSpacing: lineSpacing,
                        editingLineSpacing: editingLineSpacing,
                        identifier: identifier, endsEditingOnTab: endsEditingOnTab, isCurrent: isCurrent,
                        onChange: { text = $0 }, onCommit: onCommit,
                        onFocusChange: onFocusChange, onEndEditing: onEndEditing)
        if requestFocus { field.requestInitialFocus(selectAll: selectAll) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorInlineTextField,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? nsView.bounds.width)
        return CGSize(width: width, height: nsView.naturalHeight(for: width))
    }

    static func dismantleNSView(_ field: InspectorInlineTextField, coordinator: ()) {
        field.invalidateCallbacks()
    }
}

/// A normal AppKit field editor: selection, copy/paste, undo and accessibility
/// remain native. The delegate rejects losing focus when a durable save fails.
final class InspectorInlineTextField: NSTextField, NSTextFieldDelegate {
    private var onChangeValue: (String) -> Void = { _ in }
    private var onCommitValue: () -> Bool = { true }
    private var onFocusValue: (Bool) -> Void = { _ in }
    private var onEndValue: () -> Void = {}
    private var isCurrentValue: () -> Bool = { true }
    private var paragraph = NSMutableParagraphStyle()
    private var editingLineSpacing: CGFloat?
    private var initialFocusRequested = false
    private var initialFocusPending = false
    private var initialSelection = true
    private var isMultiline = false
    private var endsEditingOnTab = true
    private var editingGeneration: UInt64 = 0
    private var scheduledEndGeneration: UInt64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = InspectorInlineTextFieldCell(textCell: "")
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        delegate = self
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, font: NSFont, color: NSColor, multiline: Bool,
                   lineSpacing: CGFloat = 0, editingLineSpacing: CGFloat? = nil, identifier: String,
                   endsEditingOnTab: Bool = true,
                   isCurrent: @escaping () -> Bool = { true },
                   onChange: @escaping (String) -> Void,
                   onCommit: @escaping () -> Bool,
                   onFocusChange: @escaping (Bool) -> Void = { _ in },
                   onEndEditing: @escaping () -> Void = {}) {
        onChangeValue = onChange
        onCommitValue = onCommit
        onFocusValue = onFocusChange
        onEndValue = onEndEditing
        isCurrentValue = isCurrent
        self.font = font
        textColor = color
        isMultiline = multiline
        self.endsEditingOnTab = endsEditingOnTab
        usesSingleLineMode = !multiline
        maximumNumberOfLines = multiline ? 0 : 1
        cell?.wraps = multiline
        cell?.isScrollable = !multiline
        lineBreakMode = multiline ? .byWordWrapping : .byClipping
        self.editingLineSpacing = editingLineSpacing
        paragraph.lineSpacing = editingLineSpacing ?? lineSpacing
        paragraph.lineBreakMode = lineBreakMode
        (cell as? InspectorInlineTextFieldCell)?.extendsWrappedTitleSelection = identifier == "paper-field-title"
        setAccessibilityIdentifier(identifier)
        // A store publication must not replace the shared field editor's live
        // selection or marked text while the user is composing a value.
        if currentEditor() == nil, stringValue != text || attributedStringValue.length == 0 {
            attributedStringValue = NSAttributedString(string: text, attributes: textAttributes)
        }
        invalidateIntrinsicContentSize()
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 13),
         .foregroundColor: textColor ?? NSColor.labelColor,
         .paragraphStyle: paragraph]
    }

    func naturalHeight(for width: CGFloat) -> CGFloat {
        let value = stringValue.isEmpty ? " " : stringValue
        let measured = NSAttributedString(string: value + (value.hasSuffix("\n") ? " " : ""),
                                         attributes: textAttributes)
            .boundingRect(with: CGSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(isMultiline ? measured.height : (font?.boundingRectForFont.height ?? 16)) + 1
    }

    func requestInitialFocus(selectAll: Bool) {
        guard !initialFocusRequested else { return }
        initialFocusRequested = true
        initialFocusPending = true
        initialSelection = selectAll
        scheduleInitialFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleInitialFocus() }
    }

    private func scheduleInitialFocus() {
        guard initialFocusPending, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.initialFocusPending, self.window != nil, self.isCurrentValue() else { return }
            self.initialFocusPending = false
            _ = self.beginEditing(selectAll: self.initialSelection)
        }
    }

    @discardableResult
    func beginEditing(selectAll: Bool = true) -> Bool {
        guard isCurrentValue(), let window, window.makeFirstResponder(self) else { return false }
        editingGeneration &+= 1
        scheduledEndGeneration = nil
        if let editor = currentEditor() as? NSTextView {
            applyInitialParagraph(to: editor)
            editor.typingAttributes = textAttributes
            editor.defaultParagraphStyle = paragraph
            editor.isAutomaticQuoteSubstitutionEnabled = false
            if selectAll {
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            }
            // DidBeginEditing is delivered on the first text change, whereas
            // focus feedback must also appear before the user starts typing.
            onFocusValue(true)
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let succeeded = super.becomeFirstResponder()
        if succeeded, let editor = currentEditor() as? NSTextView {
            applyInitialParagraph(to: editor)
        }
        return succeeded
    }

    private func applyInitialParagraph(to editor: NSTextView) {
        guard editingLineSpacing != nil else { return }
        // AppKit copies the field's characters into its shared editor with a
        // default paragraph. Typing attributes alone leave existing lines at
        // that default spacing. Set the paragraph when focus starts; subsequent
        // SwiftUI publications never replace live text or composition ranges.
        if let storage = editor.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph.copy(),
                                 range: NSRange(location: 0, length: storage.length))
        }
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = textAttributes
    }

    @discardableResult
    func attemptCommit() -> Bool {
        guard isCurrentValue() else { return true }
        return onCommitValue()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editingGeneration &+= 1
        scheduledEndGeneration = nil
        if let editor = currentEditor() as? NSTextView {
            editor.typingAttributes = textAttributes
            editor.defaultParagraphStyle = paragraph
            editor.isAutomaticQuoteSubstitutionEnabled = false
        }
        onFocusValue(true)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isCurrentValue() else { return }
        onChangeValue(stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        attemptCommit()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        scheduleEndEditing()
    }

    private var ownsCurrentEditor: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    private func scheduleEndEditing() {
        let generation = editingGeneration
        guard scheduledEndGeneration != generation else { return }
        scheduledEndGeneration = generation
        // Defer removal of the native field until AppKit has completed its
        // shared field-editor handoff. A transient end must not remove a field
        // which owns the editor again by the end of that handoff.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentValue(), self.editingGeneration == generation else { return }
            self.scheduledEndGeneration = nil
            guard !self.ownsCurrentEditor else { return }
            self.onFocusValue(false)
            self.onEndValue()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if endsEditingOnTab,
           commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // Inline editing finishes on Tab even when this is the only field
            // in AppKit's key-view loop. Bulk mode retains normal navigation.
            if attemptCommit(), let window, window.makeFirstResponder(nil) {
                onFocusValue(false)
                scheduleEndEditing()
            }
            return true
        }
        if isMultiline, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    func invalidateCallbacks() {
        initialFocusPending = false
        onChangeValue = { _ in }
        onCommitValue = { true }
        onFocusValue = { _ in }
        onEndValue = {}
        isCurrentValue = { false }
    }
}

/// Give the title its own standard field editor so selection decoration never
/// changes the window's shared editor or another inspector value.
private final class InspectorInlineTextFieldCell: NSTextFieldCell {
    var extendsWrappedTitleSelection = false
    private var titleEditor: NSTextView?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard extendsWrappedTitleSelection else { return nil }
        if let titleEditor { return titleEditor }
        let editor = InspectorTitleFieldEditor.fieldEditor()
        editor.observeSelectionTailChanges()
        titleEditor = editor
        return editor
    }
}

/// Preserve the native TextKit2 editor and its selection/leading geometry.
/// Only paint the existing trailing padding when selection covers a soft wrap.
final class InspectorTitleFieldEditor: NSTextView {
    private var selectionObservers: [NSObjectProtocol] = []

    deinit { selectionObservers.forEach(NotificationCenter.default.removeObserver) }

    func observeSelectionTailChanges() {
        guard selectionObservers.isEmpty else { return }
        for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Native invalidation can stop at the usable text edge.
                    self?.needsDisplay = true
                }
            }
            selectionObservers.append(observer)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rectangles = selectionTailRects()
        guard !rectangles.isEmpty else { return }
        let color: NSColor
        if let window, !window.isKeyWindow || !NSApp.isActive {
            color = .unemphasizedSelectedTextBackgroundColor
        } else {
            color = selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor
        }
        NSGraphicsContext.saveGraphicsState()
        color.setFill()
        for rectangle in rectangles { rectangle.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

    func selectionTailRects() -> [NSRect] {
        guard !hasMarkedText(), let manager = textLayoutManager,
              let content = manager.textContentManager, let container = textContainer,
              container.lineFragmentPadding > 0 else { return [] }
        let selections = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !selections.isEmpty else { return [] }
        let string = self.string as NSString
        manager.ensureLayout(for: content.documentRange)
        var rectangles: [NSRect] = []
        manager.enumerateTextSegments(in: content.documentRange, type: .selection, options: []) { range, frame, _, _ in
            guard let range else { return true }
            let lineEnd = content.offset(from: content.documentRange.location, to: range.endLocation)
            guard lineEnd > 0, lineEnd < string.length,
                  selections.contains(where: { $0.location < lineEnd && NSMaxRange($0) >= lineEnd }),
                  abs(frame.maxX - (container.containerSize.width - container.lineFragmentPadding)) < 0.01 else { return true }
            // Explicit separators and the final line keep native decoration.
            switch string.character(at: lineEnd - 1) {
            case 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029: return true
            default: break
            }
            let origin = self.textContainerOrigin
            let x = origin.x + frame.maxX
            let width = min(container.lineFragmentPadding, max(0, self.bounds.maxX - x))
            if width > 0 {
                rectangles.append(NSRect(x: x, y: origin.y + frame.minY, width: width, height: frame.height))
            }
            return true
        }
        return rectangles
    }
}

extension NSFont {
    static func inspectorSerif(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
