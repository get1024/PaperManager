import AppKit
import SwiftUI

@main
struct PaperManagerApp: App {
    @NSApplicationDelegateAdaptor(PaperManagerAppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var localAPI = LocalAPIServer()

    var body: some Scene {
        let uiLocale = PMLocalization.locale(for: store.settings.languageIdentifier)
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(localAPI)
                .environment(\.locale, uiLocale)
                .frame(minWidth: 1080, minHeight: 680)
                .modifier(PaperManagerWelcomeLauncher())
        }
        .defaultSize(width: 1420, height: 860)
        .commands {
            PaperManagerCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(localAPI)
                .environment(\.locale, uiLocale)
                .frame(width: 780, height: 640)
        }

        Window(PMLocalization.text("PaperManager 帮助"), id: PaperManagerAuxiliaryWindow.help) {
            PaperManagerHelpView()
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 820, height: 660)

        Window(PMLocalization.text("欢迎使用 PaperManager"), id: PaperManagerAuxiliaryWindow.welcome) {
            PaperManagerWelcomeView()
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 660, height: 520)
        .windowResizability(.contentSize)

        Window(PMLocalization.text("PaperManager 更新说明"), id: PaperManagerAuxiliaryWindow.whatsNew) {
            PaperManagerWhatsNewView()
                .environment(\.locale, uiLocale)
        }
        .defaultSize(width: 660, height: 560)
    }
}

@MainActor
final class PaperManagerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidResignActive(_ notification: Notification) {
        PaperDraftSession.flushAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish a field editor before flushing the debounced inspector drafts.
        for window in sender.windows { window.makeFirstResponder(nil) }
        guard PaperDraftSession.flushAll() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = PMLocalization.text("草稿尚未保存")
            alert.informativeText = PMLocalization.text("文库写入失败。待保存的编辑已保留，请检查磁盘空间和文库位置后重试退出。")
            alert.addButton(withTitle: PMLocalization.text("继续编辑"))
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}

struct PaperManagerCommands: Commands {
    @FocusedValue(\.paperManagerWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(PMLocalization.text("导入文件…")) { actions?.importFiles() }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(actions == nil)

            Button(PMLocalization.text("通过标识符添加…")) { actions?.addIdentifier() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button(PMLocalization.text("手动添加…")) { actions?.addManually() }
            .disabled(actions == nil)
        }

        CommandMenu(PMLocalization.text("文库")) {
            Button(PMLocalization.text("搜索文献")) { actions?.focusSearch() }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button(PMLocalization.text("打开选中 PDF")) { actions?.openSelected() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("快速预览")) { actions?.quickLook() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("在 Finder 中显示")) { actions?.revealSelected() }
            .disabled(actions?.hasSelection != true)

            Button(PMLocalization.text("删除记录")) { actions?.deleteSelected() }
            .disabled(actions?.hasSelection != true)

            Divider()

            Button(PMLocalization.text("导出 BibTeX…")) { actions?.exportBibTeX() }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(actions?.hasSelection != true)
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
            Button(PMLocalization.text("PaperManager 帮助")) { openWindow(id: PaperManagerAuxiliaryWindow.help) }
                .keyboardShortcut("?", modifiers: [.command])
            Button(PMLocalization.text("新手导览")) { openWindow(id: PaperManagerAuxiliaryWindow.welcome) }
            Button(PMLocalization.text("更新说明")) { openWindow(id: PaperManagerAuxiliaryWindow.whatsNew) }
        }
    }
}

struct PaperManagerWindowActions {
    var importFiles: () -> Void
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

extension Notification.Name {
    static let paperManagerImportRequested = Notification.Name("PaperManagerImportRequested")
    static let paperManagerDOIRequested = Notification.Name("PaperManagerDOIRequested")
    static let paperManagerManualAddRequested = Notification.Name("PaperManagerManualAddRequested")
    static let paperManagerExportBibTeXRequested = Notification.Name("PaperManagerExportBibTeXRequested")
    static let paperManagerOpenSelectedRequested = Notification.Name("PaperManagerOpenSelectedRequested")
    static let paperManagerQuickLookRequested = Notification.Name("PaperManagerQuickLookRequested")
    static let paperManagerRevealSelectedRequested = Notification.Name("PaperManagerRevealSelectedRequested")
    static let paperManagerDeleteSelectedRequested = Notification.Name("PaperManagerDeleteSelectedRequested")
    static let paperManagerFocusSearchRequested = Notification.Name("PaperManagerFocusSearchRequested")
}
