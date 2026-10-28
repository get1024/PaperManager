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

/// A single control keeps list and inspector hover, keyboard and AX behavior in sync.
struct StarRatingView: View {
    @Binding var rating: Int
    var starSize: CGFloat = 12
    var spacing: CGFloat = 3
    var identity: UUID?
    var identifier = "star-rating"

    var body: some View {
        NativeStarRatingView(rating: $rating, starSize: starSize, spacing: spacing,
                             identity: identity, identifier: identifier)
            .frame(width: (starSize + spacing) * 5, height: max(24, starSize + 8))
    }
}

private struct NativeStarRatingView: NSViewRepresentable {
    @Binding var rating: Int
    @Environment(\.isEnabled) private var isEnabled
    let starSize: CGFloat
    let spacing: CGFloat
    let identity: UUID?
    let identifier: String

    func makeNSView(context: Context) -> NativeStarRatingControl { NativeStarRatingControl() }

    func updateNSView(_ control: NativeStarRatingControl, context: Context) {
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.isEnabled = isEnabled
        control.setStarGeometry(size: starSize, spacing: spacing)
        let binding = $rating
        control.configure(rating: rating, identity: identity) { [weak control] value in
            binding.wrappedValue = value
            // A durable write can fail. Reflect the committed binding immediately,
            // even when no store notification (and hence no SwiftUI update) occurs.
            control?.restoreRating(binding.wrappedValue)
        }
    }
}

/// Five stars, one native hit target and one AX slider. Hover is presentation
/// state only; every editing route commits through the same callback. Keeping
/// NSButtons out of table cells also avoids their macOS 27 sizing bridge during AX reads.
final class NativeStarRatingControl: NSControl {
    private(set) var rating = 0
    private(set) var hoveredRating: Int?
    var displayedRating: Int { hoveredRating ?? rating }
    private var identity: UUID?
    private var onChange: ((Int) -> Void)?
    private var starSize: CGFloat = 12
    var drawingVerticalOffset: CGFloat = 0 {
        didSet { if drawingVerticalOffset != oldValue { needsDisplay = true } }
    }
    private var spacing: CGFloat = 3
    private var hoverArea: NSTrackingArea?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var animationTimer: Timer?
    private var fills = [CGFloat](repeating: 0, count: 5)
    private var scales = [CGFloat](repeating: 1, count: 5)
    var usesSelectedColors = false {
        didSet { if usesSelectedColors != oldValue { needsDisplay = true } }
    }
    var usesTableStyle = false {
        didSet { if usesTableStyle != oldValue { needsDisplay = true } }
    }
    override var isEnabled: Bool {
        didSet { if !isEnabled { setHoveredRating(nil, animated: false) }; needsDisplay = true }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 0, dy: 3) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 25))
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 5))
    }

    deinit {
        animationTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func setStarGeometry(size: CGFloat, spacing: CGFloat) {
        guard starSize != size || self.spacing != spacing else { return }
        starSize = size; self.spacing = spacing
        needsDisplay = true
    }

    func configure(rating: Int, identity: UUID? = nil, onChange: @escaping (Int) -> Void) {
        let changedIdentity = self.identity != identity
        self.identity = identity
        self.onChange = onChange
        if changedIdentity { hoveredRating = nil }
        let value = min(5, max(0, rating))
        guard self.rating != value || changedIdentity else { return }
        self.rating = value
        updatePresentation(animated: false)
    }

    func restoreRating(_ value: Int) {
        rating = min(5, max(0, value))
        updatePresentation(animated: false)
    }

    private var step: CGFloat { min(starSize + spacing, bounds.width / 5) }
    private var hoverRect: NSRect { bounds.intersection(visibleRect) }

    private func value(at point: NSPoint, clipped: Bool = true) -> Int? {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, step > 0,
              (clipped ? hoverRect : bounds).contains(point), point.x < bounds.minX + step * 5 else { return nil }
        return min(5, max(1, Int((point.x - bounds.minX) / step) + 1))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        if !hoverRect.isEmpty {
            let area = NSTrackingArea(rect: hoverRect,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
        refreshHoverFromPointer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        setHoveredRating(nil, animated: false)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                let appNotification = name == NSApplication.didBecomeActiveNotification || name == NSApplication.didResignActiveNotification
                let object: AnyObject = appNotification ? NSApp : window
                lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        if notification.name == NSWindow.didBecomeKeyNotification || notification.name == NSApplication.didBecomeActiveNotification {
                            self?.refreshHoverFromPointer()
                        } else {
                            self?.setHoveredRating(nil, animated: false)
                        }
                    }
                })
            }
        }
        refreshHoverFromPointer()
    }

    private func refreshHoverFromPointer() {
        guard let window, window.isKeyWindow, NSApp.isActive else {
            setHoveredRating(nil, animated: false); return
        }
        setHoveredRating(value(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)), animated: false)
    }

    override func mouseEntered(with event: NSEvent) { preview(with: event) }
    override func mouseMoved(with event: NSEvent) { preview(with: event) }
    override func mouseExited(with event: NSEvent) { setHoveredRating(nil) }

    private func preview(with event: NSEvent) {
        if let window, !window.isKeyWindow || !NSApp.isActive { return }
        setHoveredRating(value(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHoveredRating(_ value: Int?, animated: Bool = true) {
        guard hoveredRating != value else { return }
        hoveredRating = value
        updatePresentation(animated: animated)
    }

    private func updatePresentation(animated: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        let targetFills = (0..<5).map { CGFloat($0 < displayedRating ? 1 : 0) }
        let targetScales = (1...5).map { CGFloat($0 == hoveredRating ? 1.12 : 1) }
        guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fills = targetFills; scales = targetScales; needsDisplay = true; return
        }
        let initialFills = fills, initialScales = scales
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.10))
                let eased = 1 - pow(1 - progress, 3)
                self.fills = zip(initialFills, targetFills).map { $0 + ($1 - $0) * eased }
                self.scales = zip(initialScales, targetScales).map { $0 + ($1 - $0) * eased }
                self.needsDisplay = true
                if progress >= 1 { timer.invalidate(); self.animationTimer = nil }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outlineColor: NSColor
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            // The table's native symbols keep a neutral tint on selected rows;
            // inspector symbols follow the surrounding secondary text instead.
            outlineColor = usesTableStyle
                ? NSColor(srgbRed: 197 / 255, green: 197 / 255, blue: 197 / 255, alpha: 1)
                : NSColor(srgbRed: 114 / 255, green: 117 / 255, blue: 123 / 255, alpha: 1)
        } else {
            outlineColor = usesSelectedColors ? NSColor.white : .secondaryLabelColor
        }
        for index in 0..<5 {
            let center = NSPoint(x: bounds.minX + step * (CGFloat(index) + 0.5), y: bounds.midY + drawingVerticalOffset)
            let alpha: CGFloat = isEnabled ? 1 : 0.45
            drawStar("star", color: outlineColor, center: center, scale: scales[index], opacity: (1 - fills[index]) * alpha)
            drawStar("star.fill", color: NSColor(Color.orange), center: center, scale: scales[index], opacity: fills[index] * alpha)
        }
    }

    private func drawStar(_ name: String, color: NSColor, center: NSPoint, scale: CGFloat, opacity: CGFloat) {
        guard opacity > 0 else { return }
        // AppKit's palette renderer also composites the supplied color alpha.
        // Keep the palette opaque and apply opacity once at the final draw.
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color.withAlphaComponent(1)])
            .applying(.init(pointSize: starSize, weight: .regular))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                             width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: opacity * color.alphaComponent, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let value = value(at: convert(event.locationInWindow, from: nil), clipped: false) else { return }
        window?.makeFirstResponder(self)
        commit(value == rating ? 0 : value)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 123, 125: commit(rating - 1, clearsHover: true)
        case 124, 126: commit(rating + 1, clearsHover: true)
        case 51, 117: commit(0, clearsHover: true)
        default:
            if let text = event.charactersIgnoringModifiers, let value = Int(text), (0...5).contains(value) { commit(value, clearsHover: true) }
            else { super.keyDown(with: event) }
        }
    }

    private func commit(_ value: Int, clearsHover: Bool = false) {
        guard isEnabled else { return }
        if clearsHover { setHoveredRating(nil, animated: false) }
        let value = min(5, max(0, value))
        guard value != rating else { return }
        rating = value
        updatePresentation(animated: false)
        onChange?(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityLabel() -> String? { PMLocalization.text("评分") }
    override func accessibilityValue() -> Any? { NSNumber(value: rating) }
    override func accessibilityValueDescription() -> String? { PMLocalization.format("%lld 星", rating) }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber else { return }
        commit(number.intValue, clearsHover: true)
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled, rating < 5 else { return false }
        commit(rating + 1, clearsHover: true); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled, rating > 0 else { return false }
        commit(rating - 1, clearsHover: true); return true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
