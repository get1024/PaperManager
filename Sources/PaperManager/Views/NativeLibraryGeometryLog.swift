import AppKit
import SwiftUI

/// Opt-in, local-only geometry evidence for the real SwiftUI WindowGroup.
/// It reads frames without changing layout and records no library text/paths.
@MainActor
final class NativeLibraryGeometryLog {
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
