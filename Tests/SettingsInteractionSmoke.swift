import AppKit
import Darwin
import SwiftUI

/// Uses the real Settings coordinator and native field editors. The runner
/// only launches this disposable App after an explicit --run request.
@main
@MainActor
struct SettingsInteractionSmoke: App {
    @StateObject private var fixture = SettingsInteractionFixture()
    var body: some Scene {
        WindowGroup {
            Text("Disposable Settings interaction fixture")
                .frame(width: 360, height: 160)
                .onAppear { fixture.start() }
        }
    }
}

@MainActor
private final class SettingsInteractionFixture: ObservableObject {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private let store: LibraryStore
    private let api = LocalAPIServer()
    private let coordinator = SettingsWindowCoordinator.shared
    private var started = false
    private var sequence = 0
    private var passed: [String] = []
    private var failures: [String] = []
    private var stages: [[String: Any]] = []
    private var blockedURL: URL?
    private let previousLanguages: Any?
    private let previousPane: Any?

    init() {
        setbuf(stdout, nil)
        guard Bundle.main.bundleIdentifier == "tests.settings-interactions",
              let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            fatalError("Settings interactions require the runner's unique App and temporary library")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        var snapshot = LibrarySnapshot.empty
        snapshot.settings.languageIdentifier = "zh-Hans"
        snapshot.settings.localAPIEnabled = false
        do { try store.replaceSnapshotDurably(snapshot) }
        catch { fatalError("Cannot create isolated Settings fixture: \(error)") }
        previousLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        previousPane = UserDefaults.standard.object(forKey: "PaperManager.Settings.selectedPane")
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        PMLocalization.configure("zh-Hans")
        coordinator.configure(store: store, localAPI: api)
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            fputs("FAIL: Settings interaction fixture exceeded its 40-second deadline\n", stderr)
            exit(3)
        }
    }

    func start() {
        guard !started else { return }; started = true
        NSApp.setActivationPolicy(.accessory)
        Task { await exercise() }
    }

    private func exercise() async {
        await settle(0.3)
        do {
            coordinator.show(pane: "localAPI")
            guard let window = coordinator.window else { throw Failure(description: "Missing production Settings window") }
            window.level = .normal
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<40 {
                if window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible) { break }
                await settle(0.05)
            }
            try expect(window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible),
                       "Owned Settings window is not active, key and screen-visible")
            print("DETAIL: Settings owned window key=\(window.isKeyWindow) active=\(NSApp.isActive) visible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible))")
            await settle(0.15)

            let originalPort = store.settings.localAPIPort
            let originalBytes = try Data(contentsOf: store.persistenceURL)
            var field = try nativeField(id: "settings-api-port", placeholder: "端口")
            var editor = try await edit(field, text: "65536", in: window)
            try expect(store.settings.localAPIPort == originalPort && (try Data(contentsOf: store.persistenceURL)) == originalBytes,
                       "Typing a port changed the persisted setting before submission")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await settle(0.08)
            try expect(store.settings.localAPIPort == originalPort && (try Data(contentsOf: store.persistenceURL)) == originalBytes,
                       "Invalid submitted port changed committed settings")
            field = try nativeField(id: "settings-api-port", placeholder: "端口")
            try expect(field.stringValue == "65536", "Invalid submitted port discarded its visible draft")
            let error = try await request(action: "read", identifier: "settings-api-port-error")
            try expect((error["text"] as? String)?.isEmpty == false, "Invalid port has no rendered error in the integration information area")
            pass("Port typing is deferred; invalid Return submission preserves draft, disk and a rendered error", window: window)

            editor = try await edit(field, text: "30471", in: window)
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            await settle(0.1)
            try expect(try diskSettings().localAPIPort == 30471 && store.settings.localAPIPort == 30471,
                       "Tab/focus loss did not commit a valid native port edit")
            field = try nativeField(id: "settings-api-port", placeholder: "端口")
            editor = try await edit(field, text: "31472", in: window)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await settle(0.1)
            try expect(try diskSettings().localAPIPort == 31472 && store.settings.localAPIPort == 31472,
                       "Return did not commit a valid native port edit")
            try expect(!api.isRunning, "The fixture unexpectedly started a real network listener")
            pass("Valid Tab and Return submissions durably update the port without opening a listener", window: window)

            let beforeFailure = try Data(contentsOf: store.persistenceURL)
            try blockWrites()
            field = try nativeField(id: "settings-api-port", placeholder: "端口")
            editor = try await edit(field, text: "31473", in: window)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await settle(0.1)
            try expect(store.settings.localAPIPort == 31472 && (try Data(contentsOf: blockedURL!)) == beforeFailure,
                       "Failed port persistence changed committed settings or bytes")
            try expect(try nativeField(id: "settings-api-port", placeholder: "端口").stringValue == "31473",
                       "Failed port persistence discarded the native draft")
            _ = try await request(action: "read", identifier: "settings-api-port-error")
            try unblockWrites()
            editor = try await edit(try nativeField(id: "settings-api-port", placeholder: "端口"), text: "31473", in: window)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await settle(0.1)
            try expect(try diskSettings().localAPIPort == 31473,
                       "Retrying the retained port draft did not save after persistence recovered")
            pass("A failed port save retains the native draft and committed bytes, then retries after recovery", window: window)

            coordinator.show(pane: "general")
            await settle(0.15)
            field = try nativeField(id: "settings-pdf-rename-format", placeholder: "格式")
            editor = try await edit(field, text: "{year}__{{author}}", in: window)
            _ = window.makeFirstResponder(nil)
            await settle(0.1)
            let preview = try await request(action: "read", identifier: "settings-pdf-rename-preview")
            try expect(preview["text"] as? String == "1905__Einstein.pdf", "Rendered PDF naming preview did not follow the edited native format field: \(preview)")
            try expect(try diskSettings().pdfRenameTemplate == "{year}__{{author}}", "Edited filename format was not durable")
            pass("The rendered PDF filename preview follows an actual native format edit and the production naming engine", window: window)

            // Return to a newly displayed General scroll root. The filename
            // field lives below the first viewport; a real menu must be in
            // the visible viewport before the external AX client opens it.
            coordinator.show(pane: "localAPI")
            await settle(0.08)
            coordinator.show(pane: "general")
            await settle(0.15)
            let languageBaseline = try Data(contentsOf: store.persistenceURL)
            try blockWrites()
            _ = try await request(action: "select", identifier: "settings-language", title: "English")
            await settle(0.15)
            try expect(store.settings.languageIdentifier == "zh-Hans" && PMLocalization.languageIdentifier == "zh-Hans" &&
                       UserDefaults.standard.stringArray(forKey: "AppleLanguages") == ["zh-Hans"],
                       "A failed rendered language selection changed language or AppleLanguages")
            try expect((try Data(contentsOf: blockedURL!)) == languageBaseline && store.statusMessage?.contains("保存文库失败") == true,
                       "Failed language selection changed committed bytes or replaced its error with success")
            pass("A rendered language selection that cannot save keeps language, preference and durable baseline", window: window)
            try unblockWrites()
            _ = try await request(action: "select", identifier: "settings-language", title: "English")
            await settle(0.15)
            try expect(try diskSettings().languageIdentifier == "en" && store.settings.languageIdentifier == "en" &&
                       PMLocalization.languageIdentifier == "en" && UserDefaults.standard.stringArray(forKey: "AppleLanguages") == ["en"],
                       "Retrying the rendered language selection did not durably apply its post-save side effects")
            pass("Retrying the rendered language choice applies localization and preference only after durable success", window: window)
        } catch { failures.append(String(describing: error)) }
        finish()
    }

    private func nativeField(id: String, placeholder: String) throws -> NSTextField {
        guard let content = coordinator.window?.contentView else { throw Failure(description: "Missing Settings content") }
        let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        if let field = fields.first(where: { $0.accessibilityIdentifier() == id || $0.identifier?.rawValue == id }) { return field }
        let candidates = fields.filter { $0.placeholderString == placeholder }
        guard candidates.count == 1, let field = candidates.first else {
            throw Failure(description: "Cannot identify rendered native field \(id); fields=\(fields.map { "\($0.placeholderString ?? ""):\($0.stringValue)" })")
        }
        return field
    }

    private func edit(_ field: NSTextField, text: String, in window: NSWindow) async throws -> NSTextView {
        field.scrollToVisible(field.bounds)
        try expect(window.makeFirstResponder(field), "Native Settings field refused focus")
        await settle(0.025)
        guard let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
            throw Failure(description: "No real field editor for rendered Settings field")
        }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.setSelectedRange(range)
        editor.insertText(text, replacementRange: range)
        await settle(0.04)
        return editor
    }

    private func request(action: String, identifier: String, title: String? = nil) async throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_SETTINGS_INTERACTION_CONTROL"] else {
            throw Failure(description: "Missing owned external AX control directory")
        }
        let root = URL(fileURLWithPath: path)
        sequence += 1
        var command: [String: Any] = ["sequence": sequence, "action": action, "identifier": identifier]
        if let title { command["title"] = title }
        try JSONSerialization.data(withJSONObject: command).write(to: root.appendingPathComponent("command.json"), options: .atomic)
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("ack.json")),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               response["sequence"] as? Int == sequence {
                guard response["ok"] as? Bool == true else { throw Failure(description: "External Settings AX failed: \(response)") }
                return response
            }
            await settle(0.025)
        }
        throw Failure(description: "External Settings AX did not acknowledge \(action):\(identifier)")
    }

    private func blockWrites() throws {
        let saved = store.persistenceURL.appendingPathExtension("owned-preserved")
        try FileManager.default.moveItem(at: store.persistenceURL, to: saved)
        blockedURL = saved
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        try Data("Synthetic fixture sentinel".utf8).write(to: store.persistenceURL.appendingPathComponent("sentinel"))
    }
    private func unblockWrites() throws {
        guard let saved = blockedURL else { return }
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.moveItem(at: saved, to: store.persistenceURL)
        blockedURL = nil
    }
    private func diskSettings() throws -> AppSettings {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: store.persistenceURL)).settings
    }
    private func pass(_ name: String, window: NSWindow) {
        passed.append(name)
        stages.append(["name": name, "key": window.isKeyWindow, "appActive": NSApp.isActive,
                       "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
                       "level": window.level.rawValue, "windowWidth": window.frame.width, "windowHeight": window.frame.height])
        print("PASS: \(name)")
    }
    private func finish() {
        if blockedURL != nil { try? unblockWrites() }
        if let previousLanguages { UserDefaults.standard.set(previousLanguages, forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        if let previousPane { UserDefaults.standard.set(previousPane, forKey: "PaperManager.Settings.selectedPane") }
        else { UserDefaults.standard.removeObject(forKey: "PaperManager.Settings.selectedPane") }
        coordinator.window?.close()
        api.stop()
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_SETTINGS_INTERACTION_REPORT"] {
            do {
                try JSONSerialization.data(withJSONObject: ["ok": failures.isEmpty, "passed": passed, "failures": failures,
                    "stages": stages, "bundleID": Bundle.main.bundleIdentifier ?? "", "library": store.persistenceURL.path,
                    "networkListenerStarted": api.isRunning], options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { failures.append("Cannot write Settings interaction report: \(error)") }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("Settings interactions: \(passed.count) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
    private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
