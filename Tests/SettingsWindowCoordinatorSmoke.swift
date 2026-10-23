import AppKit
import Darwin
import SwiftUI

/// Exercises the production coordinator from a real SwiftUI App and Settings
/// command. A hand-started NSApplication misses SwiftUI's window integration.
@main
@MainActor
struct SettingsWindowCoordinatorSmoke: App {
    @StateObject private var fixture = SettingsCoordinatorFixture()

    var body: some Scene {
        WindowGroup {
            Text("Settings coordinator fixture")
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { fixture.start() }
        }
        .defaultSize(width: 1420, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Fixture Settings…") { fixture.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
private final class SettingsCoordinatorFixture: ObservableObject {
    private let store: LibraryStore
    private let api = LocalAPIServer()
    private let coordinator = SettingsWindowCoordinator.shared
    private let key = "PaperManager.Settings.selectedPane"
    private let previous: Any?
    private var started = false

    init() {
        setbuf(stdout, nil)
        guard let libraryPath = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"],
              libraryPath.hasPrefix("/tmp/") || libraryPath.hasPrefix("/private/tmp/") else {
            fatalError("The coordinator fixture requires an owned temporary library")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: libraryPath))
        do { try store.replaceSnapshotDurably(.empty) }
        catch { fatalError("Cannot create fixture library: \(error)") }
        previous = UserDefaults.standard.object(forKey: key)
        coordinator.configure(store: store, localAPI: api)
    }

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows {
            window.level = NSWindow.Level(rawValue: -1000)
            window.orderBack(nil)
        }
        Task { await exercise() }
    }

    func showSettings() { coordinator.show() }

    private func exercise() async {
        var failures: [String] = []
        var stages: [[String: Any]] = []
        var identity: ObjectIdentifier?
        await settle(0.5)
        if let menu = NSApp.mainMenu, let (parent, index) = findSettingsCommand(in: menu) {
            parent.performActionForItem(at: index)
        } else {
            failures.append("SwiftUI App did not install its Settings command")
            coordinator.show(pane: "general")
        }
        // Include first-display settling rather than checking only the frame
        // synchronously assigned by the coordinator.
        await settle(6.3)
        for (index, pane) in ["general", "citation", "localAPI", "backup", "templates"].enumerated() {
            coordinator.show(pane: pane)
            guard let window = coordinator.window, let content = window.contentView else {
                failures.append("Missing coordinator window"); break
            }
            window.level = NSWindow.Level(rawValue: -1000)
            window.orderBack(nil)
            await settle(0.35)
            content.layoutSubtreeIfNeeded()
            if let identity, identity != ObjectIdentifier(window) { failures.append("A second Settings window was created") }
            identity = ObjectIdentifier(window)
            let views = descendants(content)
            guard let split = views.compactMap({ $0 as? NSSplitView }).first,
                  let table = views.compactMap({ $0 as? NSTableView }).first else {
                failures.append("Missing native split or sidebar"); break
            }
            let panes = split.arrangedSubviews.filter { !split.isSubviewCollapsed($0) }
            let heading = views.first { $0.identifier?.rawValue == "settings-window-heading-layout" }
            let headingFrame = heading.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
            let headerLeft = headingFrame.map { $0.minX - window.frame.minX }
            let headerTop = headingFrame.map { window.frame.maxY - $0.maxY }
            if abs(window.frame.width - 780) > 0.5 || abs(window.frame.height - 572) > 0.5 {
                failures.append("\(pane): total window frame \(window.frame.size), expected 780×572")
            }
            if abs(content.bounds.height - 572) > 0.5 || abs(content.bounds.width - 780) > 0.5 ||
                abs(split.bounds.height - 572) > 0.5 || panes.count != 2 ||
                panes.contains(where: { abs($0.frame.height - 572) > 0.5 }) {
                failures.append("\(pane): content/split/panes do not fill the 780×572 window")
            }
            if table.numberOfRows != 5 || table.selectedRow != index { failures.append("\(pane): sidebar route did not select row \(index)") }
            if panes.first.map({ abs($0.frame.width - 200) > 0.5 }) ?? true { failures.append("\(pane): sidebar width differs from 200") }
            if let headerLeft, let headerTop {
                if abs(headerLeft - 224) > 1.5 || abs(headerTop - 16) > 1.5 {
                    failures.append("\(pane): heading at \(headerLeft),\(headerTop), expected 224,16")
                }
            } else { failures.append("\(pane): heading layout frame is absent") }
            stages.append(["pane": pane, "windowWidth": window.frame.width, "windowHeight": window.frame.height,
                "contentWidth": content.bounds.width, "contentHeight": content.bounds.height,
                "splitHeight": split.bounds.height, "paneHeights": panes.map { $0.frame.height },
                "headerLeft": headerLeft ?? -1, "headerTop": headerTop ?? -1, "selectedRow": table.selectedRow])
        }
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_SETTINGS_REPORT"] {
            do {
                try JSONSerialization.data(withJSONObject: ["ok": failures.isEmpty, "failures": failures,
                    "lifecycle": "SwiftUI.App.WindowGroup.SettingsCommand", "stages": stages],
                    options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { failures.append("Cannot write fixture report: \(error)") }
        }
        if let previous { UserDefaults.standard.set(previous, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        coordinator.window?.close()
        failures.forEach { print("FAIL: \($0)") }
        print("Settings SwiftUI App coordinator: \(stages.count) panes, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }

    private func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func findSettingsCommand(in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == "Fixture Settings…" { return (menu, index) }
            if let child = item.submenu, let result = findSettingsCommand(in: child) { return result }
        }
        return nil
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
