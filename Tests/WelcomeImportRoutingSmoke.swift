import AppKit
import Darwin
import SwiftUI

/// The fixture reuses actual ContentView/.fileImporter and the auxiliary guide,
/// sharing one temporary store across every real SwiftUI library window.
@main
@MainActor
struct WelcomeImportRoutingSmoke: App {
    @StateObject private var fixture = WelcomeImportRoutingFixture()
    var body: some Scene {
        WindowGroup(id: PaperManagerAuxiliaryWindow.library) {
            WelcomeRouteMainRoot(fixture: fixture)
        }
        .defaultSize(width: 1420, height: 860)
        Window("欢迎使用 PaperManager", id: PaperManagerAuxiliaryWindow.welcome) {
            PaperManagerAuxiliaryWelcomeView()
                .environmentObject(fixture.store)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
        .defaultSize(width: 640, height: 510)
        .windowResizability(.contentSize)
    }
}

private struct WelcomeRouteMainRoot: View {
    @Environment(\.openWindow) private var openWindow
    let fixture: WelcomeImportRoutingFixture
    var body: some View {
        ContentView()
            .environmentObject(fixture.store)
            .environmentObject(fixture.api)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .frame(minWidth: 1080, minHeight: 680)
            .background(WindowChromeConfigurator { window in
                fixture.attach(window, open: { openWindow(id: $0) })
            })
    }
}

@MainActor
private final class WelcomeImportRoutingFixture: ObservableObject {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }
    let store: LibraryStore
    let api = LocalAPIServer()
    private var windows: [WeakWindow] = []
    private var opener: ((String) -> Void)?
    private var started = false
    private var sequence = 0
    private var stages: [[String: Any]] = []
    private var failures: [String] = []
    private let baseline: Data
    private let previousWelcome: Any?

    init() {
        setbuf(stdout, nil)
        guard Bundle.main.bundleIdentifier == "tests.welcome-import-routing",
              let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            fatalError("Welcome routing requires its own unique App and temporary library")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        var snapshot = LibrarySnapshot.empty
        snapshot.settings.languageIdentifier = "zh-Hans"
        snapshot.settings.localAPIEnabled = false
        do {
            try store.replaceSnapshotDurably(snapshot)
            baseline = try Data(contentsOf: store.persistenceURL)
        } catch { fatalError("Cannot prepare welcome routing fixture: \(error)") }
        previousWelcome = UserDefaults.standard.object(forKey: "PaperManager.hasShownWelcome")
        UserDefaults.standard.set(true, forKey: "PaperManager.hasShownWelcome")
        PMLocalization.configure("zh-Hans")
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            fputs("FAIL: Welcome routing exceeded its 40-second deadline\n", stderr)
            exit(3)
        }
    }

    func attach(_ window: NSWindow, open: @escaping (String) -> Void) {
        if !windows.contains(where: { $0.value === window }) { windows.append(WeakWindow(window)) }
        opener = open
        guard !started else { return }; started = true
        NSApp.setActivationPolicy(.accessory)
        Task { await exercise() }
    }

    private var mainWindows: [NSWindow] {
        windows.compactMap(\.value).filter { $0.isVisible || $0.isMiniaturized }
    }
    private var panels: [NSOpenPanel] { NSApp.windows.compactMap { $0 as? NSOpenPanel }.filter(\.isVisible) }

    private func exercise() async {
        await settle(0.3)
        do {
            guard let first = mainWindows.first else { throw Failure(description: "No initial library window") }
            try await focus(first)
            try await guideImport(existingMainCount: 1, target: first)

            opener?(PaperManagerAuxiliaryWindow.library)
            try await wait("Second main window was not created") { self.mainWindows.count == 2 }
            guard let second = mainWindows.first(where: { $0 !== first }) else { throw Failure(description: "Cannot identify the second library window") }
            try await focus(second)
            try await guideImport(existingMainCount: 2, target: second)

            for window in mainWindows { window.close() }
            try await wait("Library windows did not close before the zero-window case") { self.mainWindows.isEmpty }
            try expect(PaperManagerLibraryWindowContext.currentWindow == nil, "A closed library window remained an import target")
            try await guideImport(existingMainCount: 0, target: nil)
            try expect(try Data(contentsOf: store.persistenceURL) == baseline,
                       "Cancelling the owned open panels changed the temporary library")
            try expect(!api.isRunning && !PaperManagerLibraryWindowContext.importRequestedForNextWindow,
                       "Routing left a listener or an unconsumed pending import")
        } catch { failures.append(String(describing: error)) }
        finish()
    }

    private func guideImport(existingMainCount: Int, target: NSWindow?) async throws {
        guard let opener else { throw Failure(description: "Missing real SwiftUI openWindow action") }
        opener(PaperManagerAuxiliaryWindow.welcome)
        try await wait("Auxiliary guide did not appear") {
            NSApp.windows.contains { $0.isVisible && $0.title == "欢迎使用 PaperManager" }
        }
        await settle(0.1)
        let step = try await request(action: "read", id: "welcome-step")
        let current = Int((step["text"] as? String ?? "").split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "")
        guard let current, (1...5).contains(current) else { throw Failure(description: "Cannot read the real guide page: \(step)") }
        if current < 5 {
            for _ in current..<5 {
                _ = try await request(action: "press", id: "welcome-continue")
                await settle(0.06)
            }
        }
        _ = try await request(action: "press", id: "welcome-import-first")
        try await wait("Guide import did not open exactly one native NSOpenPanel") { self.panels.count == 1 }
        await settle(0.15)
        try expect(panels.count == 1, "The auxiliary guide opened multiple file panels")
        guard let panel = panels.first else { throw Failure(description: "Native import panel disappeared") }
        let expectedCount = max(1, existingMainCount)
        try expect(mainWindows.count == expectedCount, "Guide import created an extra library window")
        guard let routed = target ?? mainWindows.first else { throw Failure(description: "No routed library window") }
        let actualParent = panel.sheetParent
        try expect(actualParent === routed || routed.attachedSheet === panel,
                   "The native import panel is attached to another window: actual=\(String(describing: actualParent?.windowNumber)), expected=\(routed.windowNumber)")
        try expect(PaperManagerLibraryWindowContext.currentWindow === routed,
                   "The auxiliary guide did not route to the current library window")
        let stage: [String: Any] = ["existingMainCount": existingMainCount, "mainCountAfterImport": mainWindows.count,
            "nativePanelCount": panels.count, "targetWindow": routed.windowNumber,
            "panelParent": actualParent?.windowNumber ?? -1, "panelWindow": panel.windowNumber,
            "targetKey": routed.isKeyWindow, "panelKey": panel.isKeyWindow, "appActive": NSApp.isActive,
            "targetVisible": routed.isVisible, "targetOcclusionVisible": routed.occlusionState.contains(.visible),
            "pendingImport": PaperManagerLibraryWindowContext.importRequestedForNextWindow]
        _ = try await request(action: "cancel", id: "")
        try await wait("The native panel did not close after its real Cancel action") { self.panels.isEmpty }
        try expect(try Data(contentsOf: store.persistenceURL) == baseline, "Cancelling guide import changed library bytes")
        stages.append(stage)
        print("PASS: Guide import with \(existingMainCount) existing main windows opens one correctly attached native panel; Cancel preserves the shared library")
    }

    private func focus(_ window: NSWindow) async throws {
        window.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait("Owned library window did not become a visible active key window") {
            window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible)
        }
        try expect(PaperManagerLibraryWindowContext.currentWindow === window, "The active library window was not the current import target")
    }
    private func request(action: String, id: String) async throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_SETTINGS_INTERACTION_CONTROL"] else {
            throw Failure(description: "Missing owned AX helper control directory")
        }
        let root = URL(fileURLWithPath: path)
        sequence += 1
        let command: [String: Any] = ["sequence": sequence, "action": action, "identifier": id]
        try JSONSerialization.data(withJSONObject: command).write(to: root.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("ack.json")),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any], ack["sequence"] as? Int == sequence {
                guard ack["ok"] as? Bool == true else { throw Failure(description: "Welcome external AX action failed: \(ack)") }
                return ack
            }
            await settle(0.025)
        }
        throw Failure(description: "Welcome AX action \(action):\(id) timed out")
    }
    private func wait(_ message: String, until predicate: () -> Bool) async throws {
        for _ in 0..<40 {
            if predicate() { return }
            await settle(0.05)
        }
        throw Failure(description: message)
    }
    private func finish() {
        for panel in panels { panel.cancel(nil) }
        for window in NSApp.windows { window.close() }
        if let previousWelcome { UserDefaults.standard.set(previousWelcome, forKey: "PaperManager.hasShownWelcome") }
        else { UserDefaults.standard.removeObject(forKey: "PaperManager.hasShownWelcome") }
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_WELCOME_ROUTE_REPORT"] {
            do {
                try JSONSerialization.data(withJSONObject: ["ok": failures.isEmpty, "stages": stages, "failures": failures,
                    "bundleID": Bundle.main.bundleIdentifier ?? "", "library": store.persistenceURL.path], options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { failures.append("Cannot write welcome route report: \(error)") }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("Welcome routing: \(stages.count) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
    private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    private func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
}
