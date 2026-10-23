import AppKit
import Darwin
import Foundation
import SwiftUI

/// Renders the shipping views with an isolated, synthetic library. This is a
/// documentation renderer, not a screen capture or an application entry point.
@main
@MainActor
struct DocumentationPreview {
    private final class State {
        var filter: LibraryFilter = .all
        var selection: Set<UUID> = []
        var search = ""
        var includeSubcollections = true
        var sort = PaperSortDescriptor(field: .year, ascending: false)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { _exit(3) }
        Task { @MainActor in
            do { try await render() ; exit(0) }
            catch { fputs("Documentation preview: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    private static func render() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["PAPERMANAGER_DOCUMENTATION_OUTPUT"],
              let fixturePath = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              let domain = Bundle.main.bundleIdentifier,
              domain.hasPrefix("org.papermanager.documentation-preview.") else {
            throw NSError(domain: "DocumentationPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run scripts/render-readme-images.sh to isolate the library and preferences."])
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UserDefaults.standard.set(["sidebar": 220, "inspector": 340], forKey: "PaperManager.NativeLibraryPaneWidths")
        let columnLayout: [[String: Any]] = [
            ["id": "title", "width": 340.0, "hidden": false],
            ["id": "authors", "width": 165.0, "hidden": false],
            ["id": "year", "width": 55.0, "hidden": false],
            ["id": "source", "width": 155.0, "hidden": false],
            ["id": "rating", "width": 78.0, "hidden": false],
            ["id": "dateAdded", "width": 103.0, "hidden": true],
            ["id": "notes", "width": 147.0, "hidden": true]
        ]
        UserDefaults.standard.set(columnLayout, forKey: "PaperManager.NativePaperColumnLayout.v2")
        UserDefaults.standard.set("templates", forKey: "PaperManager.Settings.selectedPane")
        PMLocalization.configure("zh-Hans")
        let store = LibraryStore(persistenceURL: URL(fileURLWithPath: fixturePath))
        let snapshot = demonstrationLibrary()
        try store.replaceSnapshotDurably(snapshot)
        store.statusMessage = nil
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = State()
        state.selection = [snapshot.papers[0].id]
        let library = NativeLibraryView(store: store, papers: snapshot.papers,
            selectedFilter: Binding(get: { state.filter }, set: { state.filter = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            searchText: Binding(get: { state.search }, set: { state.search = $0 }),
            includeSubcollections: Binding(get: { state.includeSubcollections }, set: { state.includeSubcollections = $0 }),
            sortDescriptor: Binding(get: { state.sort }, set: { state.sort = $0 }),
            showSidebar: true, showInspector: true, focusSearchToken: 0,
            onOpenSelected: {}, onRevealSelected: {}, onDeleteSelected: {}, onImportURLs: { _ in },
            onRefreshMetadata: {}, onExportBibTeX: {}, onExportRIS: {}, onExportDetailed: {})
        try await capture(library, store: store, name: "library", size: NSSize(width: 1420, height: 860), output: output)

        let candidates = snapshot.papers.prefix(6).enumerated().map { index, paper in
            ImportCandidate(paper: paper, sourceURL: nil,
                duplicateID: index == 0 ? paper.id : nil, isSelected: index != 0)
        }
        try await capture(ImportPreviewView(plan: ImportPlan(candidates: candidates), targetFilter: nil, sourceKind: "BibTeX"),
            store: store, name: "import-preview", size: NSSize(width: 500, height: 400), output: output)

        let api = LocalAPIServer()
        try await capture(SettingsView().environmentObject(api), store: store,
            name: "templates", size: NSSize(width: 780, height: 740), output: output)
        let manifest: [String: Any] = [
            "kind": "offscreen-native-component-render",
            "description": "Current production AppKit/SwiftUI views rendered with a generated demonstration library. These are not screenshots of a running PaperManager application or the user's library.",
            "generator": "scripts/tools/DocumentationPreview.swift",
            "command": "./scripts/render-readme-images.sh",
            "productionSources": ["NativeLibraryView", "NativeSidebarController", "NativePaperTableController", "PaperDetailView", "ImportPreviewView", "SettingsView"],
            "fixture": ["papers": snapshot.papers.count, "collections": snapshot.collections.count, "tags": snapshot.tags.count,
                        "content": "Synthetic research titles, authors, abstracts, notes, identifiers, and dates. No real library or attachments are opened.",
                        "network": "No metadata lookups, API listener, or import commits are invoked."],
            "isolation": "Unique temporary .app bundle identifier for UserDefaults.standard; explicit temporary JSON library; no production app is launched. Temporary bundle and fixture are deleted after rendering.",
            "appearance": "Aqua/light, zh-Hans; opaque RGBA PNG (all pixels alpha=1) at 2 pixels per point",
            "method": "Non-activating NSWindow.orderBack, NSView.bitmapImageRepForCachingDisplay/cacheDisplay, opaque NSColor.windowBackgroundColor composition. No system screen capture.",
            "limitations": "Native view content only; library window chrome/toolbar is not included. Backdrop-dependent vibrancy is flattened against the Aqua window background in offscreen rendering. Source-list selection emphasis is omitted because its backdrop-only blend renders black in NSView bitmap caching; the selected table record and inspector content are preserved. Some backdrop-dependent symbols may differ from an onscreen window. The templates pane is taller than the app's default settings window to show both editors.",
            "preferences": ["sidebarPoints": 220, "inspectorPoints": 340,
                            "columns": "Documentation-specific supported column layout; dateAdded and notes hidden to fit the native table."],
            "images": [
                ["file": "library.png", "points": [1420, 860], "pixels": [2840, 1720]],
                ["file": "import-preview.png", "points": [500, 400], "pixels": [1000, 800]],
                ["file": "templates.png", "points": [780, 740], "pixels": [1560, 1480]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("manifest.json"))
        print("Rendered library.png, import-preview.png, templates.png with synthetic fixtures.")
    }

    private static func capture<V: View>(_ view: V, store: LibraryStore, name: String, size: NSSize, output: URL) async throws {
        let host = NSHostingController(rootView: view.environmentObject(store)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .preferredColorScheme(.light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.level = NSWindow.Level(rawValue: -1000)
        window.contentViewController = host
        window.setContentSize(size)
        host.view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 700_000_000)
        // A source-list material otherwise installs a VibrantLight appearance
        // whose blend-only selection colors are invalid in an offscreen bitmap.
        // Pin native descendants to the same explicit Aqua drawing appearance.
        func pinDrawingAppearance(_ nativeView: NSView) {
            nativeView.appearance = NSAppearance(named: .aqua)
            if let table = nativeView as? NSTableView, table.style == .sourceList {
                // Vibrant selection fills require WindowServer compositing.
                // Omit emphasis in this renderer instead of drawing a false
                // replacement selection or editing pixels after capture.
                table.allowsEmptySelection = true
                table.deselectAll(nil)
                table.selectionHighlightStyle = .none
                for row in 0..<table.numberOfRows {
                    table.rowView(atRow: row, makeIfNecessary: true)?.selectionHighlightStyle = .none
                    for column in 0..<table.numberOfColumns {
                        if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView {
                            cell.backgroundStyle = .normal
                            cell.textField?.textColor = .labelColor
                        }
                    }
                }
            }
            nativeView.subviews.forEach(pinDrawingAppearance)
        }
        pinDrawingAppearance(host.view)
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let cached = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else {
            throw NSError(domain: "DocumentationPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot cache \(name) view at \(host.view.bounds)"])
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "DocumentationPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create bitmap for \(name)"])
        }
        host.view.cacheDisplay(in: host.view.bounds, to: cached)
        guard let cgImage = cached.cgImage else { throw NSError(domain: "DocumentationPreview", code: 3) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSImage(cgImage: cgImage, size: size).draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        if let pixels = bitmap.bitmapData {
            for row in 0..<bitmap.pixelsHigh {
                for column in 0..<bitmap.pixelsWide where pixels[row * bitmap.bytesPerRow + column * 4 + 3] != 255 {
                    throw NSError(domain: "DocumentationPreview", code: 4, userInfo: [NSLocalizedDescriptionKey: "Nonopaque pixel in \(name)"])
                }
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }

    private static func demonstrationLibrary() -> LibrarySnapshot {
        let collectionNames = ["世界模型", "交互与具身智能", "研究方法"]
        let collections = collectionNames.enumerated().map { index, name in PaperCollection(name: name, sortIndex: index) }
        let tags = [PaperTag(name: "精读", colorHex: "#4C83E9"), PaperTag(name: "待复现", colorHex: "#E8A640"), PaperTag(name: "设计参考", colorHex: "#A06CD5")]
        let titles = [
            "Learning World Models for Embodied Agents", "A Survey of Interactive Representation Learning",
            "Visual Planning with Structured Memory", "Language-Guided Robot Skill Discovery",
            "Understanding Human–Robot Collaboration", "Learning from Multimodal Demonstrations",
            "Efficient Prediction in Dynamic Environments", "Towards Generalizable Spatial Reasoning",
            "Interactive Tools for Scientific Discovery", "A Framework for Reproducible Research",
            "Embodied Navigation through Visual Context", "Representation Learning with Sparse Feedback",
            "Designing Transparent Intelligent Systems", "Continuous Adaptation in Open Worlds",
            "Hierarchical Control with Latent Dynamics", "Grounding Language in Physical Interaction",
            "Robust Action Selection under Uncertainty", "Measuring Progress in Interactive Learning",
            "Compositional Reasoning for Visual Tasks", "Human Feedback for Adaptive Interfaces",
            "Learning Compact Models of Motion", "Memory-Augmented Decision Making",
            "Coordinating Multiple Embodied Agents", "From Simulation to Everyday Interaction",
            "Interpretable Features for World Modeling", "Benchmarking Long-Horizon Planning",
            "Shared Context in Collaborative Tasks", "Exploring Causal Structure through Action",
            "Visual Abstraction for Efficient Control", "A Practical Guide to Research Workflows",
            "Multimodal Alignment for Situated Agents", "Design Patterns for Interactive Research"
        ]
        let authors = [["Lin, Alex", "Chen, Maya", "Rivera, Sam"], ["Wang, Robin", "Kim, Jamie"], ["Patel, Avery", "Liu, Taylor"]]
        let sources = ["Embodied AI Workshop", "Interactive Systems", "Learning Research"]
        var papers = titles.enumerated().map { index, title -> Paper in
            var paper = Paper()
            paper.citekey = "demo\(2026 - index / 8)_\(index + 1)"
            paper.title = title
            paper.authors = authors[index % authors.count]
            paper.year = 2026 - index / 8
            paper.paperType = index % 4 == 0 ? .inProceedings : .article
            paper.journal = sources[index % sources.count]
            paper.bookTitle = paper.journal
            paper.rating = [5, 4, 3, 0][index % 4]
            paper.collectionIDs = [collections[index % collections.count].id]
            paper.tagIDs = [tags[index % tags.count].id]
            paper.dateAdded = Date(timeIntervalSince1970: 1_790_000_000 - Double(index * 86_400))
            paper.dateModified = paper.dateAdded
            return paper
        }
        papers[0].doi = "10.0000/documentation.demo.001"
        papers[0].abstract = "This demonstration record explores how compact world models can support embodied agents in changing environments. It brings together visual representation, temporal prediction, and action planning in a shared research workflow.\n\nThe metadata shown here is synthetic and exists only to illustrate PaperManager's native library and inspector."
        papers[0].notes = "阅读重点：预测表征、规划与交互反馈。\n下一步：梳理实验设置，比较不同环境中的泛化能力。"
        papers[0].customFields = [CustomField(key: "Research area", value: "Embodied intelligence")]
        var snapshot = LibrarySnapshot(papers: papers, collections: collections, tags: tags)
        snapshot.settings.appearance = .light
        snapshot.settings.languageIdentifier = "zh-Hans"
        snapshot.settings.localAPIEnabled = false
        snapshot.settings.autoExtractMetadataAfterImport = false
        return snapshot
    }
}
