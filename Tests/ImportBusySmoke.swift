import AppKit
import Darwin
import SwiftUI

/// Owns the data and suspended preparation. A human/CUA drives the visible
/// checkpoint buttons, Cmd-I and Cancel; the executable sends no UI actions.
@main @MainActor
struct ImportBusySmoke: App {
    @StateObject private var fixture = ImportBusyFixture()
    var body: some Scene {
        WindowGroup {
            ContentView(prepareImport: { urls, _ in await fixture.prepare(urls) })
                .environmentObject(fixture.store).environmentObject(fixture.api)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .frame(minWidth: 1080, minHeight: 680)
                .background(WindowChromeConfigurator { fixture.attach($0) })
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fixture.phase).accessibilityIdentifier("import-busy-phase")
                        NonFocusCheckpoint(title: "开始忙碌验证", identifier: "import-busy-start", action: fixture.requestStart)
                            .frame(width: 260, height: 28)
                        NonFocusCheckpoint(title: "已检查忙碌 Cmd-I；释放准备", identifier: "import-busy-release", action: fixture.requestRelease)
                            .frame(width: 260, height: 28)
                    }
                    .font(.system(size: 13)).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                }
        }
        .defaultSize(width: 1420, height: 860)
        .commands { PaperManagerCommands(store: fixture.store, localAPI: fixture.api) }
    }
}

/// Test controls live outside ContentView's focused-scene provider. Keep them
/// mounted and explicitly refuse first responder so a CUA click preserves the
/// production search/table responder instead of deleting a focused test view.
private struct NonFocusCheckpoint: NSViewRepresentable {
    let title: String
    let identifier: String
    let action: () -> Void
    final class Button: NSButton { override var acceptsFirstResponder: Bool { false } }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> Button {
        let button = Button(title: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.refusesFirstResponder = true
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        context.coordinator.action = action
    }
}

@MainActor private final class ImportBusyFixture: ObservableObject {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    let store: LibraryStore
    let api = LocalAPIServer()
    @Published private(set) var phase = "1. 请通过 CUA 激活此浮动窗口，点击开始。"
    @Published private(set) var canStart = true
    @Published private(set) var canRelease = false
    private let libraryBytes: Data
    private let input: URL
    private var started = false
    private var startRequested = false
    private var releaseRequested = false
    private var prepareCalls = 0
    private var releasePreparation: CheckedContinuation<Void, Never>?
    private var checks: [String] = []
    private var stages: [[String: Any]] = []
    private weak var observedWindow: NSWindow?
    private var nextDiagnosticAt = Date.distantPast

    init() {
        setbuf(stdout, nil)
        guard Bundle.main.bundleIdentifier == "tests.import-busy",
              let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            fatalError("Import busy fixture requires its unique App and owned temporary library")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        var snapshot = LibrarySnapshot.empty
        snapshot.settings.languageIdentifier = "zh-Hans"
        snapshot.settings.localAPIEnabled = false
        do {
            try store.replaceSnapshotDurably(snapshot)
            libraryBytes = try Data(contentsOf: store.persistenceURL)
            input = store.persistenceURL.deletingLastPathComponent().appendingPathComponent("fixture.bib")
            try Data("@article{owned,title={Owned import candidate}}".utf8).write(to: input)
        } catch { fatalError("Cannot create owned import fixture: \(error)") }
        UserDefaults.standard.set(true, forKey: "PaperManager.hasShownWelcome")
        PMLocalization.configure("zh-Hans")
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            fputs("FAIL: Manual-CUA import fixture exceeded its 240-second deadline\n", stderr); exit(3)
        }
    }

    func requestStart() { guard canStart else { return }; startRequested = true; canStart = false }
    func requestRelease() { guard canRelease else { return }; releaseRequested = true; canRelease = false }
    func prepare(_ urls: [URL]) async -> ImportPlan {
        prepareCalls += 1
        await withCheckedContinuation { releasePreparation = $0 }
        var paper = Paper(); paper.title = "Owned import candidate"
        return ImportPlan(candidates: [ImportCandidate(paper: paper, sourceURL: nil)])
    }
    func attach(_ window: NSWindow) {
        observedWindow = window
        guard !started else { return }; started = true
        Task { await run(window) }
    }

    private func run(_ window: NSWindow) async {
        var failure: String?
        do {
            // Activation/focus is observed by CUA. Do not gate setup on a
            // fixture overlay's responder topology or a lazy menu cache.
            try await wait("Start checkpoint was not clicked", seconds: 100) { self.startRequested }
            record("start", window)
            guard let outline = window.contentView.flatMap({ descendants($0).compactMap { $0 as? NSOutlineView }.first { $0.accessibilityIdentifier() == "paper-table" } }),
                  let table = outline.delegate as? NativePaperTableController else {
                throw Failure(description: "Production table drop delegate is missing")
            }
            let drag = OwnedFileDrag(url: input, window: window)
            try expect(table.outlineView(outline, acceptDrop: drag, item: nil, childIndex: -1), "First native file drop was rejected")
            try await wait("Native drop did not start its suspended preparation") { self.prepareCalls == 1 }
            await settle(0.12)
            record("preparingBeforeMenuOpen", window)
            checks.append("Native drop starts one suspended preparation")

            // These are in-process delegate/routing assertions. No pointer,
            // synthesized key, AX action or menu action is sent by the fixture.
            _ = table.outlineView(outline, acceptDrop: drag, item: nil, childIndex: -1)
            NotificationCenter.default.post(name: .paperManagerImportRequested, object: window)
            await settle(0.12)
            try expect(prepareCalls == 1 && panels.isEmpty && window.attachedSheet == nil,
                       "A second drop or targeted import route opened/replaced the in-flight import")
            try expect(store.statusMessage == PMLocalization.text("请先完成或取消当前导入。"), "Busy request was silently ignored")
            checks.append("Repeated native delegate/routing calls preserve the first operation and report busy")
            phase = "2. CUA 按 Cmd-I，再打开文件菜单核对导入已禁用；关闭菜单后释放准备。"
            canRelease = true
            try await wait("Busy Cmd-I checkpoint was not acknowledged through its visible button", seconds: 100) { self.releaseRequested }
            try expect(panels.isEmpty && importItem()?.item.isEnabled == false,
                       "After the CUA-opened menu, busy import is enabled or a chooser appeared")
            checks.append("CUA-opened native menu disables busy Cmd-I")
            record("busyAcknowledged", window)

            releasePreparation?.resume(); releasePreparation = nil
            try await wait("Prepared candidate did not reach the real preview sheet") { window.attachedSheet != nil && self.panels.isEmpty }
            phase = "3. 请通过 CUA 点击真实导入预览的取消。"
            record("preview", window)
            try await wait("CUA preview Cancel did not dismiss the preview", seconds: 100) { window.attachedSheet == nil }
            checks.append("CUA Cancel dismisses the unconfirmed preview")

            phase = "4. CUA 点搜索栏，再按 Cmd-I；选择器出现后点击取消。"
            record("readyForCmdI", window)
            try await wait("CUA Cmd-I did not open exactly one native picker", seconds: 100) { self.panels.count == 1 }
            record("picker", window)
            try await wait("CUA picker Cancel left a native panel", seconds: 100) { self.panels.isEmpty }
            try expect(try Data(contentsOf: store.persistenceURL) == libraryBytes && store.papers.isEmpty && !api.isRunning,
                       "Owned cancellation changed library data or started an API listener")
            checks.append("CUA Cmd-I and Cancel remain usable; temporary library bytes stay unchanged")
            record("complete", window)
        } catch { failure = String(describing: error) }
        releasePreparation?.resume(); releasePreparation = nil
        let payload: [String: Any] = ["ok": failure == nil, "passed": failure == nil ? 1 : 0,
            "failures": failure.map { [$0] } ?? [], "checks": checks, "stages": stages,
            "startCheckpointClicked": startRequested, "busyCheckpointClicked": releaseRequested,
            "driver": "manual-CUA; no executable activation, key, AX or menu actions",
            "prepareCalls": prepareCalls, "library": store.persistenceURL.path]
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_IMPORT_BUSY_REPORT"] {
            do { try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { print("FAIL: Cannot save import report: \(error)"); exit(2) }
        }
        if let failure { print("FAIL: \(failure)") }
        print("Import busy route: \(failure == nil ? 1 : 0) passed, \(failure == nil ? 0 : 1) failed")
        exit(failure == nil ? 0 : 1)
    }
    private func record(_ name: String, _ window: NSWindow) {
        writeLiveDiagnostic(window)
        let command = importItem()
        stages.append(["phase": name, "key": window.isKeyWindow, "appActive": NSApp.isActive,
            "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
            "level": window.level.rawValue, "nativePanelCount": panels.count,
            "attachedSheet": window.attachedSheet != nil, "importCommandEnabled": command?.item.isEnabled ?? false,
            "firstResponderType": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "productionResponderFocused": productionResponderIsFocused(window),
            "menuAutoenablesItems": command?.menu.autoenablesItems ?? false,
            "menuTarget": command?.item.target.map { String(describing: type(of: $0)) } ?? "nil",
            "menuAction": command?.item.action.map(NSStringFromSelector) ?? "nil"])
    }
    private func writeLiveDiagnostic(_ window: NSWindow) {
        guard let report = ProcessInfo.processInfo.environment["PAPERMANAGER_IMPORT_BUSY_REPORT"] else { return }
        let searches = window.contentView.map { descendants($0).compactMap { $0 as? NSSearchField } } ?? []
        let payload: [String: Any] = ["phase": phase, "startRequested": startRequested,
            "releaseRequested": releaseRequested, "prepareCalls": prepareCalls,
            "key": window.isKeyWindow, "appActive": NSApp.isActive, "visible": window.isVisible,
            "occlusionVisible": window.occlusionState.contains(.visible), "level": window.level.rawValue,
            "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "nativePanelCount": panels.count, "attachedSheet": window.attachedSheet != nil,
            "menuImportCachedEnabled": importItem()?.item.isEnabled ?? false,
            "searchFields": searches.map { ["class": String(describing: type(of: $0)),
                "AXID": $0.accessibilityIdentifier() ?? "nil", "viewID": $0.identifier?.rawValue ?? "nil",
                "ownsCurrentEditor": $0.currentEditor() === window.firstResponder] as [String: Any] }]
        let url = URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("live.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    private func productionResponderIsFocused(_ window: NSWindow) -> Bool {
        guard let content = window.contentView, let responder = window.firstResponder else { return false }
        return descendants(content).contains { view in
            if let search = view as? NSSearchField, search.accessibilityIdentifier() == "library-search" {
                return search === responder || search.currentEditor() === responder
            }
            return (view as? NSOutlineView)?.accessibilityIdentifier() == "paper-table" && view === responder
        }
    }
    private var panels: [NSOpenPanel] { NSApp.windows.compactMap { $0 as? NSOpenPanel }.filter(\.isVisible) }
    private func importItem() -> (menu: NSMenu, index: Int, item: NSMenuItem)? {
        func find(_ menu: NSMenu) -> (NSMenu, Int, NSMenuItem)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == PMLocalization.text("导入文件…"), item.keyEquivalent == "i" { return (menu, index, item) }
                if let child = item.submenu, let found = find(child) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func wait(_ message: String, seconds: Double = 3, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let window = observedWindow, Date() >= nextDiagnosticAt {
                writeLiveDiagnostic(window); nextDiagnosticAt = Date().addingTimeInterval(0.25)
            }
            if predicate() { return }
            await settle(0.04)
        }
        throw Failure(description: message)
    }
    private func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw Failure(description: message) } }
}

/// Supplies an owned pasteboard to the production drop delegate. It does not
/// synthesize an OS drag, access AX or move the user's pointer.
@MainActor private final class OwnedFileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingDestinationWindow: NSWindow?
    init(url: URL, window: NSWindow) { draggingDestinationWindow = window; super.init(); draggingPasteboard.writeObjects([url as NSURL]) }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
}
