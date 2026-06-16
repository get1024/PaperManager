import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            if rating == 0 {
                Text("Unrated")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(1...5, id: \.self) { value in
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .foregroundStyle(value <= rating ? .yellow : .secondary)
                        .imageScale(.small)
                }
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

enum LatticeStyle {
    static let sidebarWidth: CGFloat = 250
    static let inspectorWidth: CGFloat = 360
    static let windowPadding: CGFloat = 18
    static let rowRadius: CGFloat = 10
    static let cardRadius: CGFloat = 16

    static var sidebarBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var contentBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var selectedFill: Color {
        Color.accentColor.opacity(0.13)
    }

    static var groupedFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }

    static var separator: Color {
        Color(nsColor: .separatorColor).opacity(0.62)
    }
}

struct LatticeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.primary.opacity(0.055))
            )
    }
}

struct LatticeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: LatticeStyle.cardRadius, style: .continuous)
                .fill(LatticeStyle.groupedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LatticeStyle.cardRadius, style: .continuous)
                .stroke(LatticeStyle.separator, lineWidth: 0.6)
        )
    }
}

struct LatticeSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            LatticeCard {
                content
            }
        }
    }
}

struct LatticeDivider: View {
    var body: some View {
        Rectangle()
            .fill(LatticeStyle.separator)
            .frame(height: 0.6)
    }
}

struct LatticeSettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 18)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct LatticeEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
