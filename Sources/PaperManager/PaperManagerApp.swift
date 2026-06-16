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
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
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

            Button("通过 DOI 添加...") {
                NotificationCenter.default.post(name: .paperManagerDOIRequested, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("手动添加...") {
                NotificationCenter.default.post(name: .paperManagerManualAddRequested, object: nil)
            }
        }

        CommandMenu("文库") {
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
}
