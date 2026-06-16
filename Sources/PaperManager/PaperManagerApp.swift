import SwiftUI

@main
struct PaperManagerApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var localAPI = LocalAPIServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(localAPI)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .commands {
            PaperManagerCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(localAPI)
                .frame(width: 780, height: 640)
        }
    }
}

struct PaperManagerCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("导入文件...") {
                NotificationCenter.default.post(name: .paperManagerImportRequested, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command])

            Button("通过标识符添加...") {
                NotificationCenter.default.post(name: .paperManagerDOIRequested, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("手动添加...") {
                NotificationCenter.default.post(name: .paperManagerManualAddRequested, object: nil)
            }
        }

        CommandMenu("文库") {
            Button("打开选中 PDF") {
                NotificationCenter.default.post(name: .paperManagerOpenSelectedRequested, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("在 Finder 中显示") {
                NotificationCenter.default.post(name: .paperManagerRevealSelectedRequested, object: nil)
            }

            Button("删除记录") {
                NotificationCenter.default.post(name: .paperManagerDeleteSelectedRequested, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: [])

            Divider()

            Button("导出 BibTeX...") {
                NotificationCenter.default.post(name: .paperManagerExportBibTeXRequested, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command])
        }
    }
}

extension Notification.Name {
    static let paperManagerImportRequested = Notification.Name("PaperManagerImportRequested")
    static let paperManagerDOIRequested = Notification.Name("PaperManagerDOIRequested")
    static let paperManagerManualAddRequested = Notification.Name("PaperManagerManualAddRequested")
    static let paperManagerExportBibTeXRequested = Notification.Name("PaperManagerExportBibTeXRequested")
    static let paperManagerOpenSelectedRequested = Notification.Name("PaperManagerOpenSelectedRequested")
    static let paperManagerRevealSelectedRequested = Notification.Name("PaperManagerRevealSelectedRequested")
    static let paperManagerDeleteSelectedRequested = Notification.Name("PaperManagerDeleteSelectedRequested")
}
