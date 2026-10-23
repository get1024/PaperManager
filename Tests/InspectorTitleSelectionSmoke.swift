import AppKit

@MainActor
private final class RecordingTitleFieldEditor: InspectorTitleFieldEditor {
    private(set) var fullInvalidations = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { fullInvalidations += 1 }
            super.needsDisplay = newValue
        }
    }
}

@main
@MainActor
struct InspectorTitleSelectionSmoke {
    private struct Layout {
        let storage: NSTextStorage
        let manager: NSTextLayoutManager
        let container: NSTextContainer
        let editor: NSTextView
    }
    private static var results: [[String: Any]] = []
    private static let title = "A Comprehensive Survey on World Models for Embodied AI"
    private static func rect(_ value: NSRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private static func check(_ name: String, _ passed: Bool, details: [String: Any] = [:]) {
        var entry = details; entry["name"] = name; entry["passed"] = passed; results.append(entry)
        print("\(passed ? "PASS" : "FAIL"): \(name)")
    }
    private static func layout(_ text: String, width: CGFloat, custom: Bool, selection: NSRange) -> Layout {
        let editor: NSTextView
        if custom {
            let candidate = RecordingTitleFieldEditor.fieldEditor()
            candidate.observeSelectionTailChanges()
            editor = candidate
        } else { editor = NSTextView.fieldEditor() }
        let manager = editor.textLayoutManager!
        let container = editor.textContainer!
        editor.frame = NSRect(x: 0, y: 0, width: width + 4, height: 2000)
        container.widthTracksTextView = false; container.heightTracksTextView = false
        container.containerSize = NSSize(width: width + 4, height: 2000); container.lineFragmentPadding = 2
        editor.textContainerInset = .zero
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.lineBreakMode = .byWordWrapping
        editor.textStorage!.setAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont.inspectorSerif(size: 15, weight: .bold), .paragraphStyle: paragraph]))
        editor.selectedTextAttributes = [.backgroundColor: NSColor.systemBlue]
        editor.setSelectedRange(selection)
        manager.ensureLayout(for: manager.textContentManager!.documentRange)
        return Layout(storage: editor.textStorage!, manager: manager, container: container, editor: editor)
    }
    private static func textRange(_ range: NSRange, layout: Layout) -> NSTextRange {
        let content = layout.manager.textContentManager!
        let beginning = content.documentRange.location
        let start = content.location(beginning, offsetBy: range.location)!
        let end = content.location(beginning, offsetBy: NSMaxRange(range))!
        return NSTextRange(location: start, end: end)!
    }
    private static func selectionRects(_ layout: Layout) -> [NSRect] {
        var rectangles: [NSRect] = []
        layout.manager.enumerateTextSegments(in: textRange(layout.editor.selectedRange(), layout: layout),
            type: .selection, options: []) { _, frame, _, _ in rectangles.append(frame); return true }
        return rectangles
    }
    private static func tails(_ layout: Layout) -> [NSRect] {
        (layout.editor as? InspectorTitleFieldEditor)?.selectionTailRects() ?? []
    }
    private static func layoutSignature(_ layout: Layout) -> [[CGFloat]] {
        let content = layout.manager.textContentManager!
        var signature: [[CGFloat]] = []
        layout.manager.enumerateTextSegments(in: content.documentRange, type: .standard, options: []) { range, frame, baseline, _ in
            let start = content.offset(from: content.documentRange.location, to: range!.location)
            let end = content.offset(from: content.documentRange.location, to: range!.endLocation)
            signature.append([CGFloat(start), CGFloat(end), baseline] + rect(frame)); return true
        }
        return signature
    }
    private static func pixels(_ layout: Layout, scale: Int = 2) -> Data {
        let width = Int(ceil(layout.editor.bounds.width)) * scale
        let height = Int(ceil(layout.manager.usageBoundsForTextContainer.height + 2)) * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.cgContext.clear(NSRect(x: 0, y: 0, width: layout.editor.bounds.width, height: CGFloat(height) / CGFloat(scale)))
        layout.editor.draw(layout.editor.bounds)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    static func main() throws {
        let application = NSApplication.shared
        let full = NSRange(location: 0, length: (title as NSString).length)
        let baseline = layout(title, width: 264, custom: false, selection: full)
        let custom = layout(title, width: 264, custom: true, selection: full)
        let before = selectionRects(custom), tail = tails(custom)
        check("Baseline and candidate preserve the native TextKit2 engine",
              baseline.editor.textLayoutManager != nil && custom.editor.textLayoutManager != nil)
        check("Native first36px and last40px selection heights remain unchanged",
              before.count == 2 && before == selectionRects(baseline) &&
              before[0] == NSRect(x: 2, y: 0, width: 264, height: 18) &&
              before[1] == NSRect(x: 2, y: 18, width: 183.41126078463276, height: 20),
              details: ["nativeSelectionRects": before.map(rect)])
        check("Only the native first-line18pt tail receives2pt additional width",
              tail == [NSRect(x: 266, y: 0, width: 2, height: 18)], details: ["tailRects": tail.map(rect)])
        let nativePixels = pixels(baseline), decoratedPixels = pixels(custom)
        let changed = stride(from: 0, to: nativePixels.count, by: 4).filter { offset in
            (0..<4).contains { nativePixels[offset + $0] != decoratedPixels[offset + $0] }
        }
        let rasterWidth = Int(custom.editor.bounds.width) * 2
        check("Actual native2x draw adds only a4x36px tail, preserving the full native vertical split",
              changed.count == 144 && changed.allSatisfy { ($0 / 4) % rasterWidth >= 532 } &&
              layoutSignature(baseline) == layoutSignature(custom) && custom.storage.string == title &&
              custom.editor.selectedRange() == full && custom.editor.textLayoutManager != nil,
              details: ["changedPixelCount": changed.count, "nativeSelectionRectsAfterDraw": selectionRects(custom).map(rect)])
        let systemAttributes = NSTextView.fieldEditor().selectedTextAttributes
        let systemOriginal = layout(title, width: 264, custom: false, selection: full)
        let systemCandidate = layout(title, width: 264, custom: true, selection: full)
        systemOriginal.editor.selectedTextAttributes = systemAttributes; systemCandidate.editor.selectedTextAttributes = systemAttributes
        check("System selection colors preserve native drawing with the extra tail",
              pixels(systemOriginal) != pixels(systemCandidate) && selectionRects(systemOriginal) == selectionRects(systemCandidate))

        for (name, selection) in [("Partial word", NSRange(location: 2, length: 8)),
                                  ("Before wrapped trailing space", NSRange(location: 0, length: 31)),
                                  ("Final line only", NSRange(location: 32, length: 22)),
                                  ("Caret", NSRange(location: 12, length: 0))] {
            let original = layout(title, width: 264, custom: false, selection: selection)
            let candidate = layout(title, width: 264, custom: true, selection: selection)
            check("\(name) keeps native selection rectangles and pixels with no tail",
                  tails(candidate).isEmpty && selectionRects(original) == selectionRects(candidate) && pixels(original) == pixels(candidate))
        }
        let crossing = layout(title, width: 264, custom: true, selection: NSRange(location: 15, length: 22))
        check("Cross-line partial selection adds only the native row tail, leaving its unselected prefix native",
              tails(crossing) == tail && selectionRects(crossing)[0].minX > before[0].minX)
        let firstLine = layout(title, width: 264, custom: true, selection: NSRange(location: 0, length: 32))
        check("Selection through the wrapped trailing space adds only the first-line tail", tails(firstLine) == tail)
        for text in ["Short title", "First line\nSecond line"] {
            let selected = NSRange(location: 0, length: (text as NSString).length)
            let original = layout(text, width: 264, custom: false, selection: selected)
            let candidate = layout(text, width: 264, custom: true, selection: selected)
            check("Single/final line and explicit separator stay native: \(text.replacingOccurrences(of: "\n", with: " / "))",
                  tails(candidate).isEmpty && selectionRects(original) == selectionRects(candidate) && pixels(original) == pixels(candidate))
        }
        let longTitle = title + ": " + String(repeating: "Vision and Geometry for Robotics ", count: 4)
        var unchanged = true
        for width: CGFloat in [150, 200, 264, 266, 350, 500] {
            for text in ["Short title", title, longTitle] {
                let selected = NSRange(location: 0, length: (text as NSString).length)
                let original = layout(text, width: width, custom: false, selection: selected)
                let candidate = layout(text, width: width, custom: true, selection: selected)
                unchanged = unchanged && layoutSignature(original) == layoutSignature(candidate) &&
                    selectionRects(original) == selectionRects(candidate) && candidate.editor.textLayoutManager != nil
            }
        }
        check("All18 short/long title and width combinations preserve native TextKit2 positions, wrapping and selection heights", unchanged)
        check("1x and2x drawing add only logical tail decoration", pixels(baseline, scale: 1) != pixels(custom, scale: 1))
        let markedOriginal = layout(title, width: 264, custom: false, selection: full)
        let markedCandidate = layout(title, width: 264, custom: true, selection: full)
        for value in [markedOriginal, markedCandidate] { value.editor.setMarkedText(title, selectedRange: full, replacementRange: full) }
        check("Marked text preserves native TextKit2 selection, composition range and pixels",
              markedCandidate.editor.hasMarkedText() && tails(markedCandidate).isEmpty &&
              markedOriginal.editor.markedRange() == markedCandidate.editor.markedRange() &&
              pixels(markedOriginal) == pixels(markedCandidate) && markedCandidate.editor.textLayoutManager != nil)

        custom.editor.needsDisplay = false
        let recordingEditor = custom.editor as! RecordingTitleFieldEditor
        let beforeCollapse = recordingEditor.fullInvalidations
        custom.editor.setSelectedRange(NSRange(location: 12, length: 0))
        let caretOriginal = layout(title, width: 264, custom: false, selection: NSRange(location: 12, length: 0))
        check("Selection collapse invalidates the full editor and redraws without stale tail",
              recordingEditor.fullInvalidations > beforeCollapse && tails(custom).isEmpty && pixels(custom) == pixels(caretOriginal),
              details: ["fullInvalidationCalls": recordingEditor.fullInvalidations - beforeCollapse,
                        "tails": tails(custom).map(rect), "samePixels": pixels(custom) == pixels(caretOriginal)])
        custom.editor.setSelectedRange(full)
        custom.editor.needsDisplay = false
        let beforeReflow = recordingEditor.fullInvalidations
        custom.editor.string = "Short title"; custom.editor.setSelectedRange(NSRange(location: 0, length: 11)); custom.editor.didChangeText()
        check("Text reflow invalidates and removes the old wrapped tail",
              recordingEditor.fullInvalidations > beforeReflow && tails(custom).isEmpty,
              details: ["fullInvalidationCalls": recordingEditor.fullInvalidations - beforeReflow, "tails": tails(custom).map(rect)])

        let titleField = InspectorInlineTextField(frame: NSRect(x: 0, y: 0, width: 268, height: 41))
        titleField.configure(text: title, font: .inspectorSerif(size: 15, weight: .bold), color: .labelColor,
            multiline: true, editingLineSpacing: 2, identifier: "paper-field-title", onChange: { _ in }, onCommit: { true })
        let firstEditor = titleField.cell?.fieldEditor(for: titleField), secondEditor = titleField.cell?.fieldEditor(for: titleField)
        check("Only the title supplies a stable standard TextKit2 subclass field editor",
              firstEditor is InspectorTitleFieldEditor && firstEditor === secondEditor && firstEditor!.isFieldEditor && firstEditor!.textLayoutManager != nil)
        if let firstEditor {
            titleField.cell?.select(withFrame: titleField.bounds, in: titleField, editor: firstEditor, delegate: titleField, start: 0, length: full.length)
            check("Native cell setup retains TextKit2, width268 and padding2",
                  firstEditor.textLayoutManager != nil && firstEditor.textContainer?.containerSize.width == 268 &&
                  firstEditor.textContainer?.lineFragmentPadding == 2 && firstEditor.string == title)
        } else { check("Native cell setup retains TextKit2, width268 and padding2", false) }
        titleField.configure(text: "Authors", font: .systemFont(ofSize: 12), color: .labelColor,
            multiline: true, identifier: "paper-field-authors", onChange: { _ in }, onCommit: { true })
        check("Other values retain the standard shared-editor query", titleField.cell?.fieldEditor(for: titleField) == nil)
        let failures = results.filter { $0["passed"] as? Bool != true }.count
        let report: [String: Any] = ["passed": results.count - failures, "failed": failures, "results": results,
            "active": application.isActive, "windowStates": application.windows.map { ["visible": $0.isVisible, "key": $0.isKeyWindow, "main": $0.isMainWindow] },
            "scope": "CPU-only native TextKit2 factory baseline versus title subclass; never accesses NSLayoutManager. No ordering, activation, GUI events or real library. AppKit helper windows remain hidden. Live focus/IME/selection still requires integration verification."]
        let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAPERMANAGER_TITLE_SELECTION_REPORT"] ?? ".build/test-results/inspector-title-selection/report.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        if failures > 0 { exit(1) }
    }
}
