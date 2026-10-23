import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct InspectorTypeMatrixHost {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let directory = ProcessInfo.processInfo.environment["PAPERMANAGER_MATRIX_ROOT"] else { _exit(2) }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var snapshot = LibrarySnapshot.empty
        snapshot.papers = PaperType.allCases.map { type in
            var p = Paper(); p.title = "Matrix \(type.rawValue)"; p.paperType = type
            p.authors = ["Synthetic Author"]; p.year = 2026; p.citekey = "matrix-\(type.rawValue)"
            p.subtitle = "Matrix subtitle"; p.editors = ["Matrix editor"]; p.translators = ["Matrix translator"]
            p.address = "Matrix address"; p.organization = "Matrix organization"; p.type = "Matrix subtype"
            p.urlDate = "2026-10-22"; p.journal = "Matrix journal"; p.bookTitle = "Matrix bookTitle"
            p.publisher = "Matrix publisher"; p.institution = "Matrix institution"; p.school = "Matrix school"
            p.series = "Matrix series"; p.volume = "1"; p.issue = "2"; p.pages = "3-4"; p.month = "10"
            p.doi = "10.5555/matrix-\(type.rawValue)"; p.isbn = "9780000000002"
            p.url = "https://example.invalid/matrix"; p.language = "en"; p.event = "Matrix event"
            p.eventDate = "2026-10-22"; p.venue = "Matrix venue"; p.edition = "2"; p.chapter = "3"
            p.eprint = "2601.00001"; p.eprintType = "arxiv"; p.eprintClass = "cs.CV"
            p.publicationState = "Matrix state"; p.howPublished = "Matrix howpublished"
            p.customFields = [CustomField(key: "matrixCustom", value: "MATRIX-CUSTOM-VALUE")]
            p.annotations = (0..<85).map { index in
                ResearchAnnotation(page: index + 1, kind: AnnotationKind.allCases[index % AnnotationKind.allCases.count], selectedText: "MATRIX-ANNOTATION-\(index)")
            }
            return p
        }
        try store.replaceSnapshotDurably(snapshot)
        let baseline = try Data(contentsOf: store.persistenceURL)
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: -1000)
        window.contentViewController = hosting
        func select(_ index: Int) {
            let paper = snapshot.papers[index]
            hosting.rootView = AnyView(PaperDetailView(selection: .constant([paper.id])).environmentObject(store).id(paper.id))
            window.title = "Matrix \(paper.paperType.rawValue)"
            window.setContentSize(NSSize(width: 360, height: 780))
            hosting.view.layoutSubtreeIfNeeded()
        }
        select(0); window.orderBack(nil)
        var last = ""
        let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                let commandURL = root.appendingPathComponent("command")
                guard let command = try? String(contentsOf: commandURL), command != last else { return }
                last = command
                let parts = command.split(separator: ":")
                if parts.first == "select", parts.count >= 3, let index = Int(parts[1]), snapshot.papers.indices.contains(index) {
                    select(index)
                } else if parts.first == "scroll" {
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    for scroll in descendants(hosting.view).compactMap({ $0 as? NSScrollView }) {
                        guard let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height else { continue }
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                } else if parts.first == "finish" {
                    let unchanged = (try? Data(contentsOf: store.persistenceURL)) == baseline
                    try? Data((unchanged ? "unchanged" : "changed").utf8).write(to: root.appendingPathComponent("persistence"))
                }
                try? Data(command.utf8).write(to: root.appendingPathComponent("ack"), options: .atomic)
            }
        }
        _ = timer
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { _exit(3) }
        NSApplication.shared.run()
    }
}
