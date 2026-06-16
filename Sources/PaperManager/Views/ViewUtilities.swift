import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PMTypography {
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("PingFang SC", size: size).weight(weight)
    }

    static func latinFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Times New Roman", size: size).weight(weight)
    }

    static let largeTitle = font(size: 22, weight: .bold)
    static let title = font(size: 16, weight: .bold)
    static let headline = font(size: 14, weight: .bold)
    static let body = font(size: 13, weight: .semibold)
    static let bodyRegular = font(size: 13)
    static let callout = font(size: 12.5, weight: .semibold)
    static let caption = font(size: 11.5, weight: .semibold)
    static let captionRegular = font(size: 11.5)
    static let sidebarRow = font(size: 14, weight: .semibold)
    static let sidebarCount = font(size: 13, weight: .semibold)
    static let sectionHeader = font(size: 12, weight: .bold)
    static let paperTitle = latinFont(size: 16, weight: .bold)
    static let paperBody = latinFont(size: 13, weight: .semibold)
    static let paperBodyRegular = latinFont(size: 13)
    static let paperCallout = latinFont(size: 12.5, weight: .semibold)
    static let paperCaption = latinFont(size: 11.5, weight: .semibold)
    static let monospacedBody = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    static let monospacedCaption = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

extension UTType {
    static let bibTeX = UTType(filenameExtension: "bib") ?? .plainText
    static let ris = UTType(filenameExtension: "ris") ?? .plainText
    static let paperManagerBackup = UTType(filenameExtension: "papermanager") ?? .json
}

enum DialogService {
    static func requestText(title: String, message: String = "", defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue.trimmed : nil
    }

    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseApplication(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles(title: String, types: [UTType], multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveURL(title: String, name: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

struct StarRatingView: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = rating == value ? 0 : value
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .foregroundStyle(value <= rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) / 5")
            }
        }
    }
}

struct RatingDisplay: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .foregroundStyle(value <= rating ? .yellow : .secondary)
                    .imageScale(.small)
            }
        }
    }
}

extension AppearanceChoice {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct PaperManagerEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
