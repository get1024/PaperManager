import AppKit
import SwiftUI

@MainActor
private struct HoverGeometryValues: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Preprint").font(.system(size: 10)).padding(.bottom, 2)
                    InspectorInlineEditor(text: .constant("A Comprehensive Survey on World Models for Embodied AI"),
                        font: .system(size: 15, weight: .bold, design: .serif),
                        nativeFont: .systemFont(ofSize: 15, weight: .bold), color: .primary,
                        multiline: true, lineSpacing: 4, identifier: "owned-title",
                        highlightInsets: EdgeInsets(top: 6.5, leading: 6.5, bottom: 5.5, trailing: 8.5),
                        onCommit: { true })
                        .padding(.horizontal, 8).padding(.top, 14).offset(y: -2)
                    InspectorInlineEditor(text: .constant("Xinqing Li; Xin He; Le Zhang; Min Wu; Xiaoli Li; Yun Liu"),
                        font: .system(size: 12), nativeFont: .systemFont(ofSize: 12),
                        multiline: true, lineSpacing: 5.5, identifier: "owned-authors", onCommit: { true })
                        .padding(.horizontal, 8).padding(.trailing, 4).padding(.top, 16)
                    Text("li2025").font(.system(size: 10)).padding(.horizontal, 8).padding(.top, 12)
                }
                ForEach(0..<4) { index in
                    HStack(spacing: 12) {
                        Text("Field \(index)").frame(width: 62, alignment: .leading)
                        InspectorInlineEditor(text: .constant("Value \(index)"),
                            identifier: "owned-value-\(index)", onCommit: { true })
                    }
                    .font(.system(size: 12)).frame(minHeight: 23)
                }
                InspectorInlineEditor(text: .constant(String(repeating: "This is a multiline abstract. ", count: 30)),
                    font: .system(size: 12, design: .serif), multiline: true, lineSpacing: 19.0 / 3,
                    identifier: "owned-abstract", onCommit: { true })
            }
            .padding(.horizontal, 20).padding(.top, 20.5).padding(.bottom, 18)
        }
        .frame(width: 320, height: 440)
        .environment(\.displayScale, 2)
    }
}

@main
@MainActor
struct InspectorHoverGeometrySmoke {
    private static var results: [[String: Any]] = []

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func rect(_ value: NSRect) -> [CGFloat] {
        [value.minX, value.minY, value.width, value.height]
    }

    private static func check(_ name: String, _ passed: Bool, details: [String: Any] = [:]) {
        var row = details
        row["name"] = name
        row["passed"] = passed
        results.append(row)
        print("\(passed ? "PASS" : "FAIL"): \(name)")
    }

    private static func titleEditorHost(insets: EdgeInsets?) -> NSHostingView<AnyView> {
        let value = InspectorInlineEditor(text: .constant("A Comprehensive Survey on World Models for Embodied AI"),
            font: .system(size: 15, weight: .bold, design: .serif),
            nativeFont: .systemFont(ofSize: 15, weight: .bold), multiline: true, lineSpacing: 4,
            identifier: "owned-native-title", isBulkEditing: true, highlightInsets: insets, onCommit: { true })
            .padding(.horizontal, 8).offset(y: -2)
            .padding(.horizontal, 20).padding(.top, 20)
            .frame(width: 320, height: 140, alignment: .top)
            .environment(\.displayScale, 2)
        let host = NSHostingView(rootView: AnyView(value))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func main() throws {
        let application = NSApplication.shared
        let host = NSHostingView(rootView: HoverGeometryValues())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
        host.layoutSubtreeIfNeeded()
        let values = descendants(host).compactMap { $0 as? InspectorInlineHighlightView }
        check("Real SwiftUI host contains seven distinct value highlights", values.count == 7)
        guard values.count == 7 else { try finish(application: application); return }

        let oldTitleHost = titleEditorHost(insets: nil)
        let newTitleHost = titleEditorHost(insets: EdgeInsets(top: 6.5, leading: 6.5, bottom: 5.5, trailing: 8.5))
        if let oldField = descendants(oldTitleHost).compactMap({ $0 as? InspectorInlineTextField }).first,
           let newField = descendants(newTitleHost).compactMap({ $0 as? InspectorInlineTextField }).first {
            let oldFrame = oldField.convert(oldField.bounds, to: oldTitleHost)
            let newFrame = newField.convert(newField.bounds, to: newTitleHost)
            let oldTextFrame = oldField.superview!.convert(oldField.alignmentRect(forFrame: oldField.frame), to: oldTitleHost)
            let newTextFrame = newField.superview!.convert(newField.alignmentRect(forFrame: newField.frame), to: newTitleHost)
            check("Title native text frame retains width264, left anchor28 and identical height",
                  oldFrame == newFrame && oldTextFrame == newTextFrame && newTextFrame.minX == 28 && newTextFrame.width == 264,
                  details: ["nativeBefore": rect(oldFrame), "nativeAfter": rect(newFrame),
                            "textAlignmentBefore": rect(oldTextFrame), "textAlignmentAfter": rect(newTextFrame)])
        } else {
            check("Title native text frame retains width264, left anchor28 and identical height", false)
        }

        func reconcile() { values.forEach { $0.updateTrackingAreas() } }
        func trackingRect(_ view: InspectorInlineHighlightView) -> NSRect {
            view.trackingAreas.first?.rect ?? .zero
        }
        func hits(_ point: NSPoint) -> [Int] {
            values.enumerated().compactMap { index, value in
                trackingRect(value).contains(value.convert(point, from: host)) ? index : nil
            }
        }
        func hovered() -> [Int] {
            values.enumerated().compactMap { $0.element.isHovered ? $0.offset : nil }
        }
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
        func routeOwnedPoint(_ point: NSPoint) {
            let target = Set(hits(point))
            for (index, view) in values.enumerated() {
                if target.contains(index), !view.isHovered { view.mouseEntered(with: entered) }
                if !target.contains(index), view.isHovered { view.mouseExited(with: exited) }
            }
        }

        reconcile()
        let titleFrame = values[0].convert(values[0].bounds, to: host)
        check("Title feedback uses measured asymmetric insets without changing its text layout height",
              titleFrame.minX == 21.5 && titleFrame.minY == 41 && titleFrame.width == 279 && titleFrame.height == 52,
              details: ["frameInHost": rect(titleFrame), "unchangedTextWidth": 264])
        let nativeViewportIsLarger = values.contains {
            $0.visibleRect.width > $0.bounds.width || $0.visibleRect.height > $0.bounds.height
        }
        check("Fixture reproduces SwiftUI visibleRect extending beyond value bounds", nativeViewportIsLarger)
        check("Every tracking area uses the clipped value bounds, not inVisibleRect", values.allSatisfy {
            $0.trackingAreas.count == 1 && !$0.trackingAreas[0].options.contains(.inVisibleRect) &&
            $0.trackingAreas[0].rect == $0.bounds.intersection($0.visibleRect)
        })
        let centers = values.map { $0.convert(NSPoint(x: trackingRect($0).midX, y: trackingRect($0).midY), to: host) }
        let centerHits = centers.map(hits)
        check("Seven visible value centers hit only their own tracking rectangle",
              centerHits.enumerated().allSatisfy { $0.element == [$0.offset] }, details: ["centerHits": centerHits])

        routeOwnedPoint(centers[0])
        check("Owned title point reveals only the title", hovered() == [0])
        routeOwnedPoint(centers[1])
        check("Owned move from title to authors clears title and reveals authors", hovered() == [1])
        let blank = NSPoint(x: 160, y: 164)
        routeOwnedPoint(blank)
        check("Owned move into a genuine gap clears all hover", hits(blank).isEmpty && hovered().isEmpty)

        routeOwnedPoint(centers[0])
        for _ in 0..<20 { values[0].updateTrackingAreas() }
        check("Repeated area replacement keeps one bounded area and clears obsolete unattached hover",
              values[0].trackingAreas.count == 1 && !values[0].isHovered)

        let abstract = values[6]
        check("Long abstract tracking is clipped to the viewport",
              trackingRect(abstract).height > 0 && trackingRect(abstract).height < abstract.bounds.height,
              details: ["bounds": rect(abstract.bounds), "visibleRect": rect(abstract.visibleRect),
                        "trackingRect": rect(trackingRect(abstract))])
        if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first {
            let previous = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: previous.x, y: previous.y + 180))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            reconcile()
            check("Scrolling removes offscreen title tracking and retains clipped visible values",
                  values[0].trackingAreas.isEmpty && values.dropFirst().contains { !$0.trackingAreas.isEmpty },
                  details: ["scrollBounds": rect(scroll.contentView.bounds), "titleBounds": rect(values[0].bounds),
                            "titleVisibleRect": rect(values[0].visibleRect), "titleTrackingCount": values[0].trackingAreas.count])
        } else {
            check("Scrolling removes offscreen title tracking and retains clipped visible values", false,
                  details: ["reason": "Owned SwiftUI host has no native scroll view"])
        }

        // This unattached view receives only locally constructed events. The
        // runner widens handler visibility in its disposable source copy;
        // the production handler bodies and lifecycle logic are unchanged.
        let lifecycle = InspectorInlineHighlightView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        lifecycle.mouseEntered(with: entered)
        lifecycle.isFocused = true
        lifecycle.activityDidChange(Notification(name: NSApplication.didResignActiveNotification, object: application))
        check("Owned deactivation handler clears hover while preserving editing focus",
              !lifecycle.isHovered && lifecycle.isFocused)
        lifecycle.mouseEntered(with: entered)
        lifecycle.activityDidChange(Notification(name: NSWindow.didResignKeyNotification))
        check("Owned resign-key handler clears hover while preserving editing focus",
              !lifecycle.isHovered && lifecycle.isFocused)
        lifecycle.mouseEntered(with: entered)
        lifecycle.viewWillMove(toWindow: nil)
        check("Detaching clears hover while preserving editing focus", !lifecycle.isHovered && lifecycle.isFocused)
        lifecycle.mouseEntered(with: entered)
        lifecycle.viewDidMoveToWindow()
        check("Unattached reattachment reconciliation cannot retain stale hover", !lifecycle.isHovered)
        try finish(application: application)
    }

    private static func finish(application: NSApplication) throws {
        let failed = results.filter { $0["passed"] as? Bool != true }.count
        let report: [String: Any] = ["passed": results.count - failed, "failed": failed, "results": results,
            "active": application.isActive, "windowCount": application.windows.count,
            "scope": "Unattached real NSHostingView; no NSWindow, activation, posted system events, system pointer movement or real library. Native tracking rectangles and locally routed enter/exit handlers are tested; actual OS event delivery still requires live verification."]
        let output = ProcessInfo.processInfo.environment["PAPERMANAGER_HOVER_GEOMETRY_REPORT"] ??
            ".build/test-results/inspector-hover-geometry/report.json"
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        if failed > 0 { exit(1) }
    }
}
