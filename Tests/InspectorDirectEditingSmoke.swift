import AppKit
import Darwin
import SwiftUI

/// The runner compiles this App without launching it by default. Execution
/// requires an explicit UI-test window so it cannot interfere with live CUA.
@main
@MainActor
struct InspectorDirectEditingSmoke: App {
    @StateObject private var fixture = InspectorDirectEditingFixture()

    var body: some Scene {
        WindowGroup {
            PaperDetailView(selection: $fixture.selection)
                .environmentObject(fixture.store)
                .frame(width: 360, height: 780)
                .background(InspectorFixtureWindowReader { fixture.attach($0) })
        }
        .defaultSize(width: 360, height: 780)
    }
}

@MainActor
private final class InspectorDirectEditingFixture: ObservableObject {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    @Published var selection: Set<UUID>
    let store: LibraryStore
    private let paperID: UUID
    private weak var window: NSWindow?
    private var started = false
    private var passed: [String] = []
    private var failures: [String] = []
    private var activationSequence = 0
    private let initialTitle = "Selectable 😀 synthetic title"
    private let initialAuthor = "Synthetic, Selectable Author"
    private let initialSource = "Synthetic editable source"
    private let initialAbstract = "Synthetic abstract text for native selection."
    private let initialNotes = "Synthetic notes only; no user library is opened."

    init() {
        setbuf(stdout, nil)
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            fatalError("Direct editing fixture requires its owned temporary library")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        var paper = Paper()
        paper.paperType = .preprint
        paper.title = initialTitle
        paper.authors = [initialAuthor]
        paper.journal = initialSource
        paper.year = 2026
        paper.doi = "10.5555/direct-editing-fixture"
        paper.abstract = initialAbstract
        paper.notes = initialNotes
        paperID = paper.id
        selection = [paper.id]
        var snapshot = LibrarySnapshot.empty
        snapshot.papers = [paper]
        do { try store.replaceSnapshotDurably(snapshot) }
        catch { fatalError("Cannot create direct-editing fixture: \(error)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
            fputs("FAIL: Direct-editing fixture exceeded its 25-second process deadline\n", stderr)
            exit(3)
        }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        // Native field-editor tests require an active app/key window. This
        // explicit --run fixture runs only while the parent has paused CUA.
        Task { await exercise() }
    }

    private func exercise() async {
        await settle(0.3)
        do {
            guard let window else { throw Failure(description: "Fixture window was not attached") }
            window.level = .normal
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<40 {
                if window.isKeyWindow && NSApp.isActive { break }
                await settle(0.05)
            }
            print("DETAIL: Direct-editing owned window key=\(window.isKeyWindow) canBecomeKey=\(window.canBecomeKey) appActive=\(NSApp.isActive)")
            try expect(window.isKeyWindow && NSApp.isActive, "Native direct-editing fixture could not become active and key")
            try testOwnedHoverFeedback(window: window)
            for (id, text) in [("title", initialTitle), ("authors", initialAuthor), ("journal", initialSource)] {
                let native = try await activateEditor(id: id, containing: text)
                try expect(native.isSelectable, "Directly activated \(id) is not natively selectable")
            }
            pass("Idle title, authors and source enter selectable native editing directly without a pencil")

            let title = try await activateEditor(id: "title", containing: initialTitle)
            let titleEditor = try title.focus(in: window)
            await settle(0.025)
            try expectParagraphLineSpacing(in: titleEditor, equals: 2, field: "title on activation")
            try expect(window.contentView.map { content in
                descendants(content).compactMap { $0 as? InspectorInlineHighlightView }.contains { $0.isFocused }
            } == true, "A directly focused field did not expose its focus feedback")
            let range = (initialTitle as NSString).range(of: "😀 synthetic")
            titleEditor.setSelectedRange(range)
            try expect(titleEditor.selectedRange() == range, "Native editor rejected its UTF-16 selection range")
            store.statusMessage = "Unrelated synthetic SwiftUI update"
            await settle(0.06)
            try expect(window.firstResponder === titleEditor && titleEditor.selectedRange() == range,
                       "An unrelated SwiftUI update replaced focus or reset the selected text")
            try expect((titleEditor.string as NSString).substring(with: range) == "😀 synthetic",
                       "The native selection no longer identifies the intended Unicode substring")
            try expectParagraphLineSpacing(in: titleEditor, equals: 2, field: "title after publication")
            pass("Native Unicode text selection and focus survive an unrelated SwiftUI update")

            let editedTitle = "Direct title committed on focus loss 😀"
            replaceAll(in: titleEditor, with: editedTitle)
            try expect(store.paper(with: paperID)?.title == initialTitle,
                       "The fixture lost its pending-draft window before focus loss")
            try expect(window.makeFirstResponder(nil), "The title editor refused a normal focus transition")
            try expect(try diskPaper().title == editedTitle,
                       "Focus loss did not persist the final title before the autosave debounce")
            pass("Typing directly and leaving the field durably commits the last title immediately")

            for (id, original) in [("abstract", initialAbstract), ("notes", initialNotes)] {
                let value = "第一段 😀 selectable \(id)\nSecond paragraph retains its newline.\n" +
                    String(repeating: "Multiline wrapping stays visible in the native inspector. ", count: 5)
                let handle = try await activateEditor(id: id, containing: original)
                let native = try handle.focus(in: window)
                if id == "abstract" {
                    try expectParagraphLineSpacing(in: native, equals: 1, field: "abstract on activation")
                }
                let originalHeight = handle.frameHeight
                let selection = (original as NSString).range(of: "native")
                if selection.location != NSNotFound { native.setSelectedRange(selection) }
                replaceAll(in: native, with: value)
                await settle(0.06)
                if id == "abstract" {
                    try expectParagraphLineSpacing(in: native, equals: 1, field: "abstract after multiline insertion")
                }
                let unicodeSelection = (value as NSString).range(of: "😀 selectable")
                native.setSelectedRange(unicodeSelection)
                try expect(native.selectedRange() == unicodeSelection &&
                           (native.string as NSString).substring(with: unicodeSelection) == "😀 selectable",
                           "Direct \(id) editor could not select its Unicode substring")
                try expect(handle.frameHeight > originalHeight,
                           "Direct \(id) editor did not grow to show inserted multiline/wrapped content")
                try expect(window.makeFirstResponder(nil), "Direct \(id) editor could not leave focus")
                let saved = try diskPaper()
                try expect((id == "abstract" ? saved.abstract : saved.notes) == value,
                           "Direct \(id) lost multiline Unicode content on focus commit")
                pass("Direct \(id) selection, multiline Unicode editing, growth and focus-loss persistence")
            }

            let author = try await activateEditor(id: "authors", containing: initialAuthor)
            let authorEditor = try author.focus(in: window)
            let preserved = store.persistenceURL.appendingPathExtension("preserved")
            let baseline = try Data(contentsOf: store.persistenceURL)
            try FileManager.default.moveItem(at: store.persistenceURL, to: preserved)
            try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
            var blocked = true
            defer {
                if blocked {
                    try? FileManager.default.removeItem(at: store.persistenceURL)
                    try? FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
                    PaperDraftSession.flushAll()
                }
            }
            let unsavedAuthor = "Retained, Unsaved Author 😀"
            replaceAll(in: authorEditor, with: unsavedAuthor)
            authorEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            await settle(0.025)
            try expect(window.firstResponder === authorEditor,
                       "Tab discarded the active editor when its pending draft could not be saved")
            // A safe editor may either retain focus or allow focus to leave on
            // failure. It must retain the text and must not publish a false save.
            _ = window.makeFirstResponder(nil)
            await settle(0.06)
            try expect(store.paper(with: paperID)?.authorsText == initialAuthor,
                       "A failed save published unsaved author metadata")
            try expect(try Data(contentsOf: preserved) == baseline,
                       "A failed focus commit altered the last durable library bytes")
            _ = try editor(containing: unsavedAuthor)
            try expect(!PaperDraftSession.flushAll(), "A blocked library was reported as saved")
            pass("Failed focus commit retains the editable text/draft and unchanged durable baseline")

            try FileManager.default.removeItem(at: store.persistenceURL)
            try FileManager.default.moveItem(at: preserved, to: store.persistenceURL)
            blocked = false
            _ = try (try editor(containing: unsavedAuthor)).focus(in: window)
            try expect(window.makeFirstResponder(nil), "A recovered field could not leave focus")
            try expect(try diskPaper().authorsText == unsavedAuthor,
                       "Leaving the recovered field did not retry and save its retained draft")
            try expect(try diskPaper().title == editedTitle, "Retrying the author draft lost the prior title edit")
            pass("After persistence recovers, leaving the retained field retries without losing prior edits")

            do {
                var currentTitle = editedTitle
                for (name, command) in [("Tab", #selector(NSResponder.insertTab(_:))),
                                        ("Shift-Tab", #selector(NSResponder.insertBacktab(_:)))] {
                    let value = try await activateEditor(id: "title", containing: currentTitle)
                    let native = try value.focus(in: window)
                    let tabTitle = "\(name) commits the pending direct title 😀"
                    replaceAll(in: native, with: tabTitle)
                    native.doCommand(by: command)
                    await settle(0.1)
                    try expect((try? editor(containing: tabTitle)) == nil,
                               "\(name) kept the local editor instead of returning to idle: key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), \(value.diagnosticDescription), attached=\(native.window != nil), selected=\(native.selectedRange())")
                    try expect(!hasFocusedHighlight,
                               "\(name) left a focused border after the local editor returned to idle")
                    try expect(try diskPaper().title == tabTitle,
                               "\(name) did not durably save the last typed value before the debounce")
                    currentTitle = tabTitle
                }
                pass("Tab and Shift-Tab commit the direct editor's pending value, return to idle and clear focus")
            } catch {
                failures.append(String(describing: error))
                _ = window.makeFirstResponder(nil)
                await settle(0.06)
            }

            do {
                try await pressAX(identifier: "paper-edit-metadata")
                await settle(0.06)
                let native = try (try editor(containing: unsavedAuthor)).focus(in: window)
                try expect(window.firstResponder === native, "Bulk editor did not acquire native focus")
                replaceAll(in: native, with: unsavedAuthor)
                await settle(0.025)
                try expect(hasFocusedHighlight, "Bulk editor never exposed focus feedback before Done")
                try await pressAX(identifier: "paper-edit-metadata")
                await settle(0.1)
                try expect((try? editor(containing: unsavedAuthor)) == nil,
                           "Bulk Done left the author editor mounted")
                try expect(!hasFocusedHighlight,
                           "Bulk Done left a focused border behind an idle value")
                pass("Bulk Done removes the focused editor and clears its idle focus feedback")
            } catch { failures.append(String(describing: error)) }
        } catch { failures.append(String(describing: error)) }
        finish()
    }

    private func testOwnedHoverFeedback(window: NSWindow) throws {
        let feedback = InspectorInlineHighlightView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        feedback.updateTrackingAreas()
        try expect(feedback.trackingAreas.contains { $0.options.contains([.mouseEnteredAndExited, .activeInKeyWindow]) },
                   "Hover feedback does not install native enter/exit tracking")
        let idle = try renderedFeedback(feedback)
        guard let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil),
              let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, trackingNumber: 0, userData: nil) else {
            throw Failure(description: "Cannot create fixture-owned hover events")
        }
        // Deliver only to this owned view. No system mouse movement or posted
        // event can affect the user's foreground application.
        feedback.mouseEntered(with: entered)
        try expect(feedback.isHovered && feedback.hasVisibleBorder, "Hover did not reveal the border")
        try expect(try renderedFeedback(feedback) != idle, "Hover state did not alter rendered pixels")
        feedback.isFocused = true
        let focused = try renderedFeedback(feedback)
        feedback.mouseExited(with: exited)
        try expect(!feedback.isHovered && feedback.hasVisibleBorder,
                   "Leaving the hovered view removed its active focus border")
        try expect(try renderedFeedback(feedback) == focused, "Hover exit changed the higher-priority focus rendering")
        feedback.isFocused = false
        try expect(!feedback.hasVisibleBorder && (try renderedFeedback(feedback)) == idle,
                   "Clearing hover and focus left a stale highlight")
        pass("Owned hover events render feedback, preserve the focus border on exit, and clear when idle")
    }

    private func renderedFeedback(_ view: NSView) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else {
            throw Failure(description: "Cannot create owned hover bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(view.bounds)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        context.flushGraphics()
        return Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func activateEditor(id: String, containing value: String) async throws -> NativeInspectorEditor {
        if let native = try? editor(containing: value) { return native }
        let identifier = "paper-field-\(id)"
        try await pressAX(identifier: identifier)
        // AX action delivery and the SwiftUI representable mount are
        // separate main-loop turns. Bound the wait for the real native
        // control without issuing a second activation action.
        for _ in 0..<12 {
            await settle(0.025)
            if let native = try? editor(containing: value) { return native }
        }
        return try editor(containing: value)
    }

    private var hasFocusedHighlight: Bool {
        window?.contentView.map { content in
            descendants(content).compactMap { $0 as? InspectorInlineHighlightView }.contains { $0.isFocused }
        } ?? false
    }

    private func pressAX(identifier: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_INSPECTOR_EDIT_CONTROL"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            throw Failure(description: "Missing owned external AX control directory")
        }
        let root = URL(fileURLWithPath: path)
        activationSequence += 1
        let sequence = activationSequence
        let command: [String: Any] = ["sequence": sequence, "identifier": identifier]
        try JSONSerialization.data(withJSONObject: command).write(to: root.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("ack.json")),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               ack["sequence"] as? Int == sequence {
                guard ack["ok"] as? Bool == true else {
                    throw Failure(description: ack["message"] as? String ?? "External AX activation failed")
                }
                return
            }
            await settle(0.05)
        }
        throw Failure(description: "External AX helper did not acknowledge \(identifier)")
    }

    private func editor(containing value: String) throws -> NativeInspectorEditor {
        guard let content = window?.contentView else { throw Failure(description: "Missing fixture content") }
        for view in descendants(content) {
            if let field = view as? NSTextField, field.isEditable,
               ((field.currentEditor() as? NSTextView)?.string ?? field.stringValue) == value {
                return .field(field)
            }
            if let text = view as? NSTextView, text.isEditable, text.string == value { return .text(text) }
        }
        let controls = descendants(content).compactMap { view -> String? in
            if let field = view as? NSTextField {
                return "\(type(of: field)) editable=\(field.isEditable) id=\(field.accessibilityIdentifier()) text=\(field.stringValue) live=\((field.currentEditor() as? NSTextView)?.string ?? "nil")"
            }
            if let text = view as? NSTextView { return "\(type(of: text)) editable=\(text.isEditable) text=\(text.string)" }
            return nil
        }
        throw Failure(description: "No default editable native inspector control contains: \(value); native controls: \(controls)")
    }

    private func replaceAll(in editor: NSTextView, with value: String) {
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.setSelectedRange(range)
        editor.insertText(value, replacementRange: range)
    }

    private func expectParagraphLineSpacing(in editor: NSTextView, equals expected: CGFloat,
                                            field: String) throws {
        guard editor.isFieldEditor, let storage = editor.textStorage, storage.length > 0 else {
            throw Failure(description: "\(field) did not expose nonempty native field-editor text storage")
        }
        var spacings: [CGFloat] = []
        var invalid: [String] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else {
                invalid.append("\(range): missing paragraph style")
                return
            }
            spacings.append(style.lineSpacing)
            if abs(style.lineSpacing - expected) > 0.001 {
                invalid.append("\(range): \(style.lineSpacing)")
            }
        }
        try expect(invalid.isEmpty && !spacings.isEmpty,
                   "\(field) actual text-storage line spacing differs from \(expected): \(invalid)")
        print("DETAIL: \(field) native textStorage UTF16=\(storage.length) paragraph lineSpacing=\(spacings)")
    }

    private func diskPaper() throws -> Paper {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: store.persistenceURL))
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
            throw Failure(description: "The synthetic paper disappeared from the saved library")
        }
        return paper
    }

    private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try value()) { throw Failure(description: message) }
    }

    private func pass(_ name: String) { passed.append(name); print("PASS: \(name)") }
    private func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func finish() {
        // Release any synthetic session before the runner removes its directory.
        window?.makeFirstResponder(nil)
        PaperDraftSession.flushAll()
        window?.close()
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_INSPECTOR_EDIT_REPORT"] {
            do {
                try JSONSerialization.data(withJSONObject: ["ok": failures.isEmpty, "passed": passed,
                    "failures": failures, "lifecycle": "SwiftUI.App.WindowGroup.PaperDetailView",
                    "actions": "owned-field AX activation without pencil, native selection/insertText/Tab/responder transitions; bulk pencil/Done checked separately"],
                    options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { failures.append("Cannot save test report: \(error)") }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("Inspector direct editing: \(passed.count) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    private enum NativeInspectorEditor {
        case field(NSTextField)
        case text(NSTextView)
        var isSelectable: Bool {
            switch self { case .field(let field): return field.isSelectable; case .text(let text): return text.isSelectable }
        }
        var frameHeight: CGFloat {
            switch self { case .field(let field): return field.frame.height; case .text(let text): return text.frame.height }
        }
        var diagnosticDescription: String {
            switch self {
            case .field(let field):
                return "field=\(field), currentEditor=\(String(describing: field.currentEditor())), fieldAttached=\(field.window != nil)"
            case .text(let text): return "textView=\(text), fieldEditor=\(text.isFieldEditor)"
            }
        }
        func focus(in window: NSWindow) throws -> NSTextView {
            switch self {
            case .field(let field):
                // Reusing the current field editor preserves focus. Calling
                // selectText after makeFirstResponder would begin editing a
                // second time and emit an intermediate end-edit notification.
                if field.currentEditor() == nil {
                    guard window.makeFirstResponder(field) else {
                        throw Failure(description: "Native text field rejected focus")
                    }
                }
                guard let editor = field.currentEditor() as? NSTextView else {
                    throw Failure(description: "Native text field did not create its field editor")
                }
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
                return editor
            case .text(let text):
                guard window.makeFirstResponder(text) else { throw Failure(description: "Native text view rejected focus") }
                return text
            }
        }
    }
}

@MainActor
private struct InspectorFixtureWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) { }

    private final class Probe: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onWindow(window)
            }
        }
    }
}
