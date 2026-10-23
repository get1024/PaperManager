import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PMTypography {
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
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
    static let detailTitle = Font.system(size: 16.5, weight: .bold, design: .serif)
    static let detailAbstract = Font.system(size: 12, design: .serif)
    static let paperTitle = font(size: 16, weight: .bold)
    static let paperBody = font(size: 13, weight: .semibold)
    static let paperBodyRegular = font(size: 13)
    static let paperCallout = font(size: 12.5, weight: .semibold)
    static let paperCaption = font(size: 11.5, weight: .semibold)
    static let monospacedBody = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    static let monospacedCaption = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

extension UTType {
    static let bibTeX = UTType(filenameExtension: "bib") ?? .plainText
    static let ris = UTType(filenameExtension: "ris") ?? .plainText
    static let paperManagerBackup = UTType(filenameExtension: "papermanager") ?? .zip
    static let latticeBackup = UTType(filenameExtension: "lattice") ?? .zip
}

enum DialogService {
    static func requestText(title: String, message: String = "", defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = PMLocalization.text(title)
        alert.informativeText = PMLocalization.text(message)
        alert.addButton(withTitle: PMLocalization.text("确定"))
        alert.addButton(withTitle: PMLocalization.text("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue.trimmed : nil
    }

    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = PMLocalization.text(title)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseApplication(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = PMLocalization.text(title)
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles(title: String, types: [UTType], multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = PMLocalization.text(title)
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveURL(title: String, name: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.title = PMLocalization.text(title)
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
enum PaperReaderActions {
    static func openPDF(_ paper: Paper, attachment suppliedAttachment: Attachment? = nil, store: LibraryStore) {
        guard let attachment = suppliedAttachment ?? paper.primaryPDF else {
            store.statusMessage = PMLocalization.text("这篇文献尚未关联 PDF。")
            return
        }
        let token = store.libraryIdentityToken
        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message(PMLocalization.text("PDF 文件不存在，可能已在 Finder 中移动或删除。"))
                }
                if let path = store.settings.defaultPDFReaderPath.nilIfBlank {
                    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: .init()) { _, error in
                        Task { @MainActor in
                            guard store.libraryIdentityToken == token else { return }
                            if let error {
                                store.statusMessage = PMLocalization.format("无法使用所选阅读器打开 PDF：%@", error.localizedDescription)
                            } else { didOpen(paper.id, attachment: attachment, store: store) }
                        }
                    }
                } else if NSWorkspace.shared.open(url) {
                    didOpen(paper.id, attachment: attachment, store: store)
                } else {
                    throw PaperManagerError.message(PMLocalization.text("无法打开 PDF。"))
                }
            }
        } catch {
            store.statusMessage = PMLocalization.format("无法打开 PDF：%@", error.localizedDescription)
        }
    }

    private static func didOpen(_ id: UUID, attachment: Attachment, store: LibraryStore) {
        guard let paper = store.paper(with: id), paper.attachments.contains(attachment) else { return }
        store.markOpened(id)
        guard paper.primaryPDF == attachment, store.settings.autoExtractAnnotationsAfterOpeningPDF else { return }
        Task { await refreshAnnotationsAfterOpening(id, attachment: attachment, store: store) }
    }

    @discardableResult
    static func refreshAnnotationsAfterOpening(
        _ id: UUID, attachment: Attachment, store: LibraryStore,
        extractor: (Attachment, UUID) async throws -> [ResearchAnnotation] = {
            try await ImportService.extractAnnotations(from: $0, paperID: $1)
        }
    ) async -> Bool {
        guard let paper = store.paper(with: id), paper.primaryPDF == attachment else { return false }
        let token = store.libraryIdentityToken
        let baseline = paper.annotations
        do {
            let annotations = try await extractor(attachment, id)
            guard store.libraryIdentityToken == token,
                  var latest = store.paper(with: id), latest.primaryPDF == attachment,
                  latest.annotations == baseline else { return false }
            latest.annotations = annotations
            try store.updatePaperDurably(latest)
            store.statusMessage = PMLocalization.text("标注已刷新。")
            return true
        } catch {
            guard store.libraryIdentityToken == token else { return false }
            store.statusMessage = PMLocalization.format("标注提取失败：%@", error.localizedDescription)
            return false
        }
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
            Label(PMLocalization.text(title), systemImage: systemImage)
        } description: {
            Text(PMLocalization.text(message))
        }
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowChromeView(configure: configure)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowChromeView)?.configureIfNeeded()
    }
}

private final class WindowChromeView: NSView {
    private let configure: (NSWindow) -> Void
    private weak var configuredWindow: NSWindow?

    init(configure: @escaping (NSWindow) -> Void) {
        self.configure = configure
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureIfNeeded()
    }

    func configureIfNeeded() {
        guard let window, configuredWindow !== window else { return }
        // Setting window chrome invalidates SwiftUI layout. Reapplying it from
        // every representable update schedules another update indefinitely.
        configuredWindow = window
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.configure(window)
        }
    }
}
