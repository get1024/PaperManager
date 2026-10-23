import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct SettingsWindowGroupSmoke: App {
    @NSApplicationDelegateAdaptor(SettingsSmokeDelegate.self) private var delegate
    @StateObject private var fixture = SettingsSmokeState()

    var body: some Scene {
        WindowGroup {
            SettingsView()
                .environmentObject(fixture.store)
                .environmentObject(fixture.api)
                .frame(width: 780, height: 572)
                .onAppear { fixture.start() }
        }
    }
}

@MainActor
final class SettingsSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("Settings fixture exceeded 20 seconds\n", stderr)
            _exit(3)
        }
    }
}

@MainActor
final class SettingsSmokeState: ObservableObject {
    let store: LibraryStore
    let api = LocalAPIServer()
    private var started = false
    private var failures: [String] = []
    private var stages: [[String: Any]] = []

    init() {
        guard let path = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"], path.hasPrefix("/") else {
            fatalError("An explicit owned library is required")
        }
        store = LibraryStore(persistenceURL: URL(fileURLWithPath: path))
        try! store.replaceSnapshotDurably(.empty)
    }

    func start() {
        guard !started else { return }; started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.runStep(0) }
    }

    private func runStep(_ index: Int) {
        guard index < 5 else { finish(); return }
        guard let window = NSApp.windows.first(where: { $0.frame.width >= 780 }),
              let content = window.contentView,
              let table = descendants(content).compactMap({ $0 as? NSTableView }).first,
              let split = descendants(content).compactMap({ $0 as? NSSplitView }).first else {
            failures.append("No settings WindowGroup, navigation table or native split"); finish(); return
        }
        window.level = NSWindow.Level(rawValue: -1000)
        window.orderBack(nil)
        if table.numberOfRows != 5 { failures.append("Settings navigation does not contain five panes") }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let expectedHeight = content.bounds.height
            let panes = split.arrangedSubviews.filter { !split.isSubviewCollapsed($0) }
            if abs(split.bounds.height - expectedHeight) > 1 || panes.count != 2 ||
                panes.contains(where: { abs($0.frame.height - expectedHeight) > 1 }) {
                self.failures.append("Pane \(index): content \(expectedHeight), split \(split.bounds.height), panes \(panes.map { $0.frame.height })")
            }
            self.stages.append(["pane": index, "selectedRow": table.selectedRow,
                "contentHeight": expectedHeight, "splitHeight": split.bounds.height,
                "paneHeights": panes.map { $0.frame.height }])
            self.runStep(index + 1)
        }
    }

    private func finish() {
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_SETTINGS_REPORT"] {
            let payload: [String: Any] = ["ok": failures.isEmpty, "failures": failures, "stages": stages]
            try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        failures.forEach { print("FAIL: \($0)") }
        print("Settings WindowGroup fixture: \(stages.count) panes, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
