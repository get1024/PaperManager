import AppKit
import SwiftUI

@main
struct PaperManagerApp: App {
    @NSApplicationDelegateAdaptor(PaperManagerAppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var localAPI = LocalAPIServer()

    init() {
        let defaults = UserDefaults.standard
        let migrationKey = "PaperManager.Layout.nestedFloatingV2"
        if !defaults.bool(forKey: migrationKey) {
            if let previous = defaults.dictionary(forKey: "PaperManager.NativeLibraryPaneWidths") {
                defaults.set(previous, forKey: "PaperManager.Layout.beforeNestedFloatingV2")
            }
            defaults.set(["sidebar": 240, "inspector": 320], forKey: "PaperManager.NativeLibraryPaneWidths")
            defaults.set(true, forKey: migrationKey)
        }
    }

    var body: some Scene {
        let uiLocale = PMLocalization.locale(for: store.settings.languageIdentifier)
        WindowGroup(id: PaperManagerAuxiliaryWindow.library) {
            ContentView()
                .environmentObject(store)
                .environmentObject(localAPI)
                .environment(\.locale, uiLocale)
                .frame(minWidth: 1200, minHeight: 560)
        }
        .defaultSize(width: 1420, height: 860)
        .commands {
            PaperManagerCommands(store: store, localAPI: localAPI)
        }

        Window(PMLocalization.text("PaperManager手册"), id: PaperManagerAuxiliaryWindow.help) {
            PaperManagerHelpView()
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 780, height: 620)

        Window(PMLocalization.text("欢迎使用 PaperManager"), id: PaperManagerAuxiliaryWindow.welcome) {
            PaperManagerAuxiliaryWelcomeView()
                .environmentObject(store)
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 640, height: 510)
        .windowResizability(.contentSize)

        Window(PMLocalization.text("PaperManager 更新说明"), id: PaperManagerAuxiliaryWindow.whatsNew) {
            PaperManagerWhatsNewView()
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 580, height: 340)
    }
}

@MainActor
final class PaperManagerAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?

    func applicationDidBecomeActive(_ notification: Notification) {
        LibraryStore.refreshLiveAttachmentAvailability()
    }

    func applicationDidResignActive(_ notification: Notification) {
        PaperDraftSession.flushAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Repeated Quit requests share one pending reply and one rollback wait.
        guard terminationTask == nil else { return .terminateLater }
        guard flushDraftsForTermination(sender) else { return .terminateCancel }
        guard LibraryStore.hasRunningFileOperations else { return .terminateNow }
        let fileShutdown = LibraryStore.beginFileOperationShutdown()
        terminationTask = Task { [weak self] in
            await fileShutdown.value
            guard let self else {
                LibraryStore.resumeAfterCancelledFileOperationShutdown()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            // A field may have changed while AppKit kept the run loop alive.
            // Keep the same recoverable draft-save failure behavior after IO.
            let canQuit = self.flushDraftsForTermination(sender)
            if !canQuit { LibraryStore.resumeAfterCancelledFileOperationShutdown() }
            self.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    private func flushDraftsForTermination(_ sender: NSApplication) -> Bool {
        // Finish a field editor before flushing the debounced inspector drafts.
        for window in sender.windows { window.makeFirstResponder(nil) }
        guard PaperDraftSession.flushAll(), ReadingSessionService.pauseAll() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = PMLocalization.text("草稿尚未保存")
            alert.informativeText = PMLocalization.text("文库写入失败。待保存的编辑已保留，请检查磁盘空间和文库位置后重试退出。")
            alert.addButton(withTitle: PMLocalization.text("继续编辑"))
            alert.runModal()
            return false
        }
        return true
    }
}

struct PaperManagerCommands: Commands {
    let store: LibraryStore
    let localAPI: LocalAPIServer
    @FocusedValue(\.paperManagerWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(PMLocalization.text("设置") + "…") {
                SettingsWindowCoordinator.shared.configure(store: store, localAPI: localAPI,
                    onOpenHelp: { openWindow(id: PaperManagerAuxiliaryWindow.help) })
                SettingsWindowCoordinator.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button(PMLocalization.text("导入文件…")) { actions?.importFiles() }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(actions?.canImportFiles != true)

            Button(PMLocalization.text("通过标识符添加…")) { actions?.addIdentifier() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(PMLocalization.text("手动添加…")) { actions?.addManually() }
            .disabled(actions == nil)

            Button(PMLocalization.text("从 Lattice 导入…")) { actions?.importLattice() }
            .disabled(actions == nil)
        }

        CommandMenu(PMLocalization.text("文库")) {
            Button(PMLocalization.text("搜索文献")) { actions?.focusSearch() }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button(PMLocalization.text("打开")) { actions?.openSelected() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("快速预览")) { actions?.quickLook() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("在 Finder 中显示")) { actions?.revealSelected() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("删除所选项目")) { actions?.deleteSelected() }
            .disabled(actions?.hasSelection != true)

            Divider()

            Button(PMLocalization.text("导出 BibTeX…")) { actions?.exportBibTeX() }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(actions?.canExport != true)
        }

        CommandGroup(replacing: .sidebar) {
            Button(PMLocalization.text(actions?.sidebarVisible == true ? "隐藏文库侧栏" : "显示文库侧栏")) { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil)
            Button(PMLocalization.text(actions?.inspectorVisible == true ? "隐藏论文检查器" : "显示论文检查器")) { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .help) {
            Button(PMLocalization.text("PaperManager手册")) { openWindow(id: PaperManagerAuxiliaryWindow.help) }
                .keyboardShortcut("?", modifiers: [.command])
            Button(PMLocalization.text("导览")) {
                if let actions { actions.showWelcome() } else { openWindow(id: PaperManagerAuxiliaryWindow.welcome) }
            }
            Button(PMLocalization.text("更新内容")) {
                if let actions { actions.showWhatsNew() } else { openWindow(id: PaperManagerAuxiliaryWindow.whatsNew) }
            }
        }
    }
}

struct PaperManagerWindowActions {
    var importFiles: () -> Void
    var importLattice: () -> Void
    var addIdentifier: () -> Void
    var addManually: () -> Void
    var focusSearch: () -> Void
    var openSelected: () -> Void
    var quickLook: () -> Void
    var revealSelected: () -> Void
    var deleteSelected: () -> Void
    var exportBibTeX: () -> Void
    var toggleSidebar: () -> Void
    var toggleInspector: () -> Void
    var hasSelection: Bool
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var showWelcome: () -> Void = {}
    var showWhatsNew: () -> Void = {}
    var canExport = false
    var canImportFiles = true
}

private struct PaperManagerWindowActionsKey: FocusedValueKey {
    typealias Value = PaperManagerWindowActions
}

extension FocusedValues {
    var paperManagerWindowActions: PaperManagerWindowActions? {
        get { self[PaperManagerWindowActionsKey.self] }
        set { self[PaperManagerWindowActionsKey.self] = newValue }
    }
}
