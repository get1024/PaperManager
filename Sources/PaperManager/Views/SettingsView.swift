import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCoordinator()
    static let windowSize = NSSize(width: 780, height: 572)
    private static let diagnosticPath = ProcessInfo.processInfo.environment["PAPERMANAGER_UI_DIAGNOSTICS"]
        ?? UserDefaults.standard.string(forKey: "PaperManager.UIDiagnosticsPath")
    static var needsGeometryMarker: Bool {
#if SETTINGS_WINDOW_GEOMETRY_TEST
        true
#else
        diagnosticPath != nil
#endif
    }

    private var store: LibraryStore?
    private var localAPI: LocalAPIServer?
    private var onOpenHelp: (() -> Void)?
    private var controller: NSWindowController?

    var window: NSWindow? { controller?.window }

    func configure(store: LibraryStore, localAPI: LocalAPIServer, onOpenHelp: (() -> Void)? = nil) {
        self.store = store
        self.localAPI = localAPI
        if let onOpenHelp { self.onOpenHelp = onOpenHelp }
    }

    func show(pane: String? = nil) {
        guard let store, let localAPI else { return }
        if let pane, SettingsPane(rawValue: pane) != nil {
            UserDefaults.standard.set(pane, forKey: "PaperManager.Settings.selectedPane")
        }
        if controller == nil {
            let root = AnyView(SettingsView(onOpenHelp: { [weak self] in self?.onOpenHelp?() })
                .environmentObject(store)
                .environmentObject(localAPI)
                .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
                .frame(width: Self.windowSize.width, height: Self.windowSize.height))
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            hosting.sceneBridgingOptions = []
            // A root NSHostingView participates in SwiftUI App window sizing
            // even with sizing/scene bridging disabled. Keep AppKit ownership
            // of this auxiliary window by embedding the host in a native root.
            let content = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: content.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = PMLocalization.text("PaperManager 设置")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.toolbar = nil
            window.delegate = self
            window.contentView = content
            // The measured reference size includes the titlebar. Set the frame,
            // not a content size which AppKit may expand by the titlebar height.
            window.setFrame(NSRect(origin: window.frame.origin, size: Self.windowSize), display: false)
            window.minSize = Self.windowSize
            window.maxSize = Self.windowSize
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recordGeometry(event: "show")
        if Self.diagnosticPath != nil {
            for delay in [0.35, 1.0, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.recordGeometry(event: "show+\(delay)")
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    func windowDidResize(_ notification: Notification) {
        guard Self.diagnosticPath != nil else { return }
        let stack = window.map { abs($0.frame.height - 604) < 0.5 } == true ? Thread.callStackSymbols : nil
        recordGeometry(event: "resize", callStack: stack)
    }

    private func recordGeometry(event: String, callStack: [String]? = nil) {
        guard let path = Self.diagnosticPath, path.hasPrefix("/"), let window,
              let content = window.contentView else { return }
        func rect(_ value: NSRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        func size(_ value: NSSize) -> [String: CGFloat] { ["width": value.width, "height": value.height] }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content).filter { view in
            view === content || view is NSSplitView || view is NSTableView ||
                String(describing: type(of: view)).contains("HostingView") ||
                view.identifier?.rawValue == "settings-window-heading-layout"
        }.map { view -> [String: Any] in
            let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
            let insets = view.safeAreaInsets
            var entry: [String: Any] = ["type": String(describing: type(of: view)), "identifier": view.identifier?.rawValue ?? "",
                "frame": rect(view.frame), "bounds": rect(view.bounds),
                "windowTop": window.frame.maxY - screenRect.maxY,
                "windowLeft": screenRect.minX - window.frame.minX,
                "safeAreaInsets": ["top": insets.top, "bottom": insets.bottom, "left": insets.left, "right": insets.right],
                "intrinsicSize": size(view.intrinsicContentSize)]
            if let hosting = view as? NSHostingView<AnyView> {
                entry["hostingSizingOptions"] = hosting.sizingOptions.rawValue
                entry["hostingSceneBridgingOptions"] = hosting.sceneBridgingOptions.rawValue
            }
            return entry
        }
        var payload: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier, "bundle": Bundle.main.bundlePath,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "windowNumber": window.windowNumber, "windowFrame": rect(window.frame),
            "contentLayoutRect": rect(window.contentLayoutRect), "styleMask": window.styleMask.rawValue,
            "minSize": size(window.minSize), "maxSize": size(window.maxSize),
            "contentMinSize": size(window.contentMinSize), "contentMaxSize": size(window.contentMaxSize),
            "scale": window.backingScaleFactor, "views": views,
            "allWindows": NSApp.windows.map { ["number": $0.windowNumber, "title": $0.title, "frame": rect($0.frame)] }]
        if let callStack { payload["resizeCallStack"] = callStack }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }
}

/// Keeps the Picker's native selection/checkmarks inside a standard Menu, with
/// the compact value-and-indicator presentation used by grouped macOS forms.
private struct SettingsMenuPicker<PickerContent: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: () -> PickerContent

    var body: some View {
        Menu {
            content().labelsHidden().pickerStyle(.inline)
        } label: {
            HStack(spacing: 12.5) {
                Text(verbatim: value)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.09), in: Circle())
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13)).foregroundStyle(.primary)
            .padding(.trailing, 3.5)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
        .accessibilityLabel(Text(PMLocalization.text(title)))
        .accessibilityValue(Text(verbatim: value))
    }
}

private struct SettingsHeadingGeometryMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("settings-window-heading-layout")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPane: SettingsPane = .general
    @AppStorage("PaperManager.Settings.selectedPane") private var requestedPane = SettingsPane.general.rawValue
    @State private var includeBackupFiles = true
    @State private var showZoteroImport = false
    @State private var showMCPConfiguration = false
    @State private var apiPortDraft: String?
    @State private var apiPortError: String?
    @FocusState private var isAPIPortFocused: Bool
    var onOpenHelp: (() -> Void)? = nil

    var body: some View {
        NativeSettingsContainer(selection: $selectedPane, detail: AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Text("PaperManager 设置")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityIdentifier("settings-window-heading")
                    .background {
                        if SettingsWindowCoordinator.needsGeometryMarker { SettingsHeadingGeometryMarker() }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .topLeading)

                ScrollView {
                    selectedContent
                        .padding(.horizontal, selectedPane == .templates ? 24 : 20)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(selectedPane)
                .scrollContentBackground(.hidden)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(settingsBackground)
            .environmentObject(store)
            .environmentObject(localAPI)
            .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        ))
        .font(.system(size: 13))
        .background(settingsBackground)
        .onAppear { selectedPane = SettingsPane(rawValue: requestedPane) ?? .general }
        .onChange(of: requestedPane) { _, value in selectedPane = SettingsPane(rawValue: value) ?? .general }
        .onChange(of: selectedPane) { _, value in requestedPane = value.rawValue }
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        .sheet(isPresented: $showZoteroImport) { ZoteroImportView(store: store) }
        .sheet(isPresented: $showMCPConfiguration) {
            SettingsMCPConfigurationSheet(instructions: mcpInstructions)
        }
        .overlay(alignment: .bottomTrailing) {
            if selectedPane == .localAPI {
                Button("了解更多…") {
                    if let onOpenHelp { onOpenHelp() }
                    else { openWindow(id: PaperManagerAuxiliaryWindow.help) }
                }
                    .buttonStyle(.link)
                    .padding(.trailing, 20)
                    .padding(.bottom, 17)
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedPane {
        case .general:
            general
        case .citation:
            citation
        case .localAPI:
            localAPISettings
        case .backup:
            backup
        case .templates:
            templates
        }
    }

    private var settingsBackground: Color {
        colorScheme == .dark ? Color(red: 35 / 255, green: 36 / 255, blue: 40 / 255) : .white
    }

    private var settingsCardBackground: Color {
        colorScheme == .dark ? Color(red: 42 / 255, green: 43 / 255, blue: 45 / 255) : Color(white: 0.965)
    }

    private func settingsHeading(_ title: String, weight: Font.Weight = .bold) -> some View {
        Text(PMLocalization.text(title))
            .font(.system(size: 13, weight: weight))
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .padding(.leading, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(settingsCardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func settingsRow<Content: View>(height: CGFloat = 38, divider: Bool = true, contentOffset: CGFloat = 0,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .offset(y: contentOffset)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                if divider {
                    Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 10)
                }
            }
    }

    private func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(PMLocalization.text(title))
            Spacer(minLength: 8)
            Toggle(PMLocalization.text(title), isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private var languageSelection: Binding<String> {
        Binding(get: { store.settings.languageIdentifier }, set: { language in
            guard store.updateSetting(\.languageIdentifier, value: language) else { return }
            PMLocalization.configure(language)
            if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
            store.statusMessage = PMLocalization.text("语言已更改。系统菜单将在重新打开应用后更新。")
        })
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsCard {
                settingsRow {
                    Text("语言")
                    Spacer()
                    SettingsMenuPicker(title: "语言", value: languageSelectionLabel) {
                        Picker("语言", selection: languageSelection) {
                            Text("跟随系统").tag("system")
                            Text(verbatim: "简体中文").tag("zh-Hans")
                            Text(verbatim: "English").tag("en")
                        }
                    }
                    .accessibilityIdentifier("settings-language")
                }
                settingsRow(divider: false) {
                    Text("外观")
                    Spacer()
                    SettingsMenuPicker(title: "外观", value: store.settings.appearance.label) {
                        Picker("外观", selection: binding(\.appearance)) {
                            ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
            }

            settingsHeading("阅读器").offset(y: -3).padding(.top, 32).padding(.bottom, 6)
            settingsCard {
                settingsRow(height: 40, contentOffset: -2) {
                    Text("默认 PDF 阅读器")
                    Spacer()
                    Button("选择") {
                        if let app = DialogService.chooseApplication(title: "选择默认 PDF 阅读器") {
                            store.updateSetting(\.defaultPDFReaderPath, value: app.path)
                        }
                    }
                    Button("重置") { store.updateSetting(\.defaultPDFReaderPath, value: "") }
                        .disabled(store.settings.defaultPDFReaderPath.trimmed.isEmpty)
                }
                settingsRow(height: 41, divider: false) {
                    Image(nsImage: selectedReaderIcon).resizable().frame(width: 17, height: 17)
                    Text(selectedReaderName)
                }
            }

            settingsHeading("PaperManager 文件库").padding(.top, 32).padding(.bottom, 6)
            settingsCard {
                settingsRow(contentOffset: -1) {
                    Text("本地文件操作")
                    Spacer()
                    SettingsMenuPicker(title: "本地文件操作", value: fileOperationSelectionLabel) {
                        Picker("本地文件操作", selection: binding(\.pdfOrganizationMode)) {
                            ForEach(PDFOrganizationMode.allCases) { mode in
                                Text(PMLocalization.text(mode == .none ? "不做任何处理" : (mode == .copy ? "复制" : "移动")))
                                    .tag(mode).disabled(mode != .none && !fileLibraryStatus.isAvailable)
                            }
                        }
                    }
                }
                settingsRow(contentOffset: -0.5) {
                    Text("子文件夹分组")
                    Spacer()
                    SettingsMenuPicker(title: "子文件夹分组", value: store.settings.pdfSubfolderGrouping.label) {
                        Picker("子文件夹分组", selection: binding(\.pdfSubfolderGrouping)) {
                            ForEach(PDFSubfolderGrouping.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                settingsRow(height: 40, contentOffset: -1.5) {
                    Text("文件布局")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(PMLocalization.text("PDF 与附件分开，或每篇文献一个文件夹。新布局用于今后的文件操作。"))
                    Spacer()
                    SettingsMenuPicker(title: "文件布局", value: PMLocalization.text(fileLayoutSelection.wrappedValue == .separate ? "分开" : "按文献")) {
                        Picker("文件布局", selection: fileLayoutSelection) {
                            Text("分开").tag(FileLibraryLayout.separate)
                            Text("按文献").tag(FileLibraryLayout.byPaper)
                        }
                    }
                }
                settingsRow(height: 42, contentOffset: -2) {
                    Text("位置")
                    Spacer()
                    Button(PMLocalization.text(fileLibraryStatus.availability == .unavailable ? "重新授权" : "更改")) { chooseFileLibrary() }
                    Button("重置") { resetFileLibrary(declined: false) }
                }
                settingsRow(height: 40, divider: false) {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(fileLibraryStatus.rootURL?.path ?? PMLocalization.text("未选择文件夹"))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(fileLibraryStatus.rootURL?.path ?? fileLibraryStatus.availability.label)
                }
            }
            settingsCard {
                settingsRow {
                    settingsSwitch("移除文献时，将关联文件移到废纸篓", isOn: binding(\.deleteAttachmentsToTrash))
                }
                settingsRow {
                    settingsSwitch("自动重命名 PDF", isOn: binding(\.autoRenamePDFs))
                }
                settingsRow(divider: false) {
                    Text("格式")
                    TextField("格式", text: binding(\.pdfRenameTemplate))
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-pdf-rename-format")
                }
            }
            .padding(.top, 10)
            Text(verbatim: samplePDFFilename)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
                .accessibilityIdentifier("settings-pdf-rename-preview")

            advancedGeneralSettings.padding(.top, 24)
        }
        .buttonStyle(.bordered)
    }

    private var languageSelectionLabel: String {
        switch store.settings.languageIdentifier {
        case "zh-Hans": return "简体中文"
        case "en": return "English"
        default: return PMLocalization.text("跟随系统")
        }
    }

    private var fileOperationSelectionLabel: String {
        let mode = store.settings.pdfOrganizationMode
        return PMLocalization.text(mode == .none ? "不做任何处理" : (mode == .copy ? "复制" : "移动"))
    }

    private var fileLayoutSelection: Binding<FileLibraryLayout> {
        Binding(get: { FileLibraryService.preferences(for: store.settings).layout }, set: { layout in
            var settings = store.settings
            var preferences = FileLibraryService.preferences(for: settings)
            preferences.layout = layout
            settings.fileLibrary = preferences
            store.updateSettings(settings)
        })
    }

    private var selectedReaderIcon: NSImage {
        if let path = store.settings.defaultPDFReaderPath.nilIfBlank {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .pdf)
    }

    private var advancedGeneralSettings: some View {
        DisclosureGroup("更多选项") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("表格密度", selection: binding(\.tableDensity)) {
                    ForEach(TableDensity.allCases) { Text($0.label).tag($0) }
                }
                Toggle("默认显示检查器", isOn: binding(\.showInspectorByDefault))
                Toggle("移动或复制 PDF 前确认", isOn: binding(\.confirmBeforeMovingFiles))
                LabeledContent("文件库状态", value: fileLibraryStatus.availability.label)
                if fileLibraryStatus.availability == .legacyConflict {
                    Text("两个旧位置都已保留。请选择今后使用的单个文件库，现有文件不会移动。")
                    ForEach(FileLibraryService.preferences(for: store.settings).legacyConflictPaths, id: \.self) { path in
                        Button("选择 \(path)…") { chooseFileLibrary(suggestedRoot: URL(fileURLWithPath: path)) }
                    }
                }
                if fileLibraryStatus.availability == .notAsked {
                    Button("将本地文件保留在原位置") { resetFileLibrary(declined: true) }
                }
                Text("新位置和布局用于今后的文件操作。已关联文件会保留原位置，放入文件库的文件不会自动导入。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("应用到现有文献的文件…") { applyFileLibraryToExistingPapers() }
                    .disabled(!fileLibraryStatus.isAvailable || store.papers.isEmpty || store.isFileOperationRunning)
                if let progress = store.fileOperationProgress {
                    HStack {
                        if progress.isRunning { ProgressView().controlSize(.small) }
                        Text("\(progress.processed) / \(progress.total)")
                            .monospacedDigit()
                        if progress.failed > 0 {
                            Text(PMLocalization.format("失败 %d", progress.failed)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if progress.isRunning {
                            Button("取消") { store.cancelFileOperation() }
                        }
                    }
                }
                Divider()
                Text("自动处理").fontWeight(.semibold)
                Toggle("导入后自动补全元数据", isOn: binding(\.autoExtractMetadataAfterImport))
                Toggle("导入后自动提取标注", isOn: binding(\.autoExtractAnnotationsAfterImport))
                Toggle("打开 PDF 后自动刷新标注", isOn: binding(\.autoExtractAnnotationsAfterOpeningPDF))
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 10)
    }

    private var citation: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHeading("引用键格式", weight: .semibold).offset(y: -0.5).padding(.bottom, 8)
            settingsCard {
                settingsRow(height: 36, divider: false) {
                    Text("格式")
                    TextField("格式", text: binding(\.citekeyFormat))
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .offset(y: 0.5)
                    Text(CitekeyGenerator.render(format: store.settings.citekeyFormat, paper: sampleCitationPaper))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .offset(y: 0.5)
                }
            }
            settingsHeading("导出字段", weight: .semibold).offset(y: -1.5).padding(.top, 31).padding(.bottom, 7.5)
            settingsCard {
                ForEach(CitationExportField.allCases) { field in
                    settingsRow(height: 37.5, divider: field != CitationExportField.allCases.last, contentOffset: -0.5) {
                        Toggle(field.label, isOn: Binding(
                            get: { store.settings.includesCitationExport(field) },
                            set: { included in
                                var settings = store.settings
                                settings.setCitationExport(field, included: included)
                                store.updateSettings(settings)
                            }
                        ))
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text("其他所有非空字段都会始终导出。要从某篇文献的导出中移除某个值，请编辑该文献的元数据。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 10)
            DisclosureGroup("格式变量") {
                Text("可用变量：{auth}、{year}、{year2}、{title}、{titleWord}、{journal}、{doi}；同时支持旧版 {{author}}、{{authorLower}}、{{authorInitial}} 等双花括号格式。修改格式后，文库的 citekey 会自动更新。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
            }
            .padding(.horizontal, 10).padding(.top, 24)
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("模板正文").font(.system(size: 13, weight: .bold))
                .offset(y: -1.5)
                .frame(height: 24, alignment: .topLeading)
                .accessibilityAddTraits(.isHeader)
            templateEditor(text: Binding(
                get: { store.snapshot.selectedMetadataTemplate.content },
                set: { content in editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, content: content) } }
            ), height: 280) {
                editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, content: AppSettings.defaultMetadataTemplate) }
            }
            Text("标注正文").font(.system(size: 13, weight: .bold))
                .offset(y: -1.5)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .topLeading)
                .padding(.top, 52)
                .accessibilityAddTraits(.isHeader)
            templateEditor(text: binding(\.annotationTemplate), height: 96) {
                store.updateSetting(\.annotationTemplate, value: AppSettings.defaultAnnotationTemplate)
            }
            templateManagement.padding(.top, 24)
        }
        .padding(.top, 6)
    }

    private func templateEditor(text: Binding<String>, height: CGFloat, reset: @escaping () -> Void) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 28))
            .frame(height: height)
            .background(colorScheme == .dark ? Color(red: 44 / 255, green: 45 / 255, blue: 49 / 255) : Color(white: 244 / 255),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.background.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(0.04), lineWidth: 0.5))
                }
                .buttonStyle(.plain).padding(10)
                .help(PMLocalization.text("恢复默认模板"))
                .accessibilityLabel(Text("恢复默认模板"))
            }
            .offset(y: 0.5)
    }

    private var templateManagement: some View {
        DisclosureGroup("模板管理与预览") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("模板", selection: Binding(
                    get: { store.snapshot.selectedMetadataTemplate.id },
                    set: { id in editTemplates { try $0.selectMetadataTemplate(id: id) } }
                )) {
                    ForEach(store.snapshot.availableMetadataTemplates) { Text($0.name).tag($0.id) }
                }
                TextField("模板名称", text: Binding(
                    get: { store.snapshot.selectedMetadataTemplate.name },
                    set: { name in editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, name: name) } }
                ))
                HStack {
                    Button("新建模板") { editTemplates { _ = try $0.addMetadataTemplate(name: PMLocalization.text("新建模板")) } }
                    Button("复制模板") {
                        editTemplates { snapshot in
                            let selected = snapshot.selectedMetadataTemplate
                            _ = try snapshot.addMetadataTemplate(name: selected.name + " 2", content: selected.content)
                        }
                    }
                    Button("删除模板", role: .destructive) {
                        editTemplates { try $0.deleteMetadataTemplate(id: $0.selectedMetadataTemplate.id) }
                    }
                    .disabled(store.snapshot.availableMetadataTemplates.count < 2)
                }
                Text(TemplateRenderer.renderMetadata(paper: samplePaperForTemplate, snapshot: previewSnapshot))
                    .font(PMTypography.monospacedBody).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 10)
        }
    }

    private func editTemplates(_ edit: (inout LibrarySnapshot) throws -> Void) {
        do { try MetadataTemplateService.update(in: store, edit) }
        catch { store.statusMessage = error.localizedDescription }
    }

    private var localAPISettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHeading("本地 API").offset(y: -0.5).padding(.bottom, 8)
            settingsCard {
                settingsRow(height: 37.5, contentOffset: -0.25) {
                    settingsSwitch("启用", isOn: binding(\.localAPIEnabled))
                }
                settingsRow(height: 37.5, contentOffset: -0.25) {
                    settingsSwitch("只读模式", isOn: binding(\.localAPIReadOnly))
                }
                settingsRow(height: 36, divider: false, contentOffset: 0.5) {
                    Text("端口")
                    Spacer()
                    TextField("端口", text: Binding(
                        get: { apiPortDraft ?? String(store.settings.localAPIPort) },
                        set: { apiPortDraft = $0; apiPortError = nil }
                    ))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 80)
                    .accessibilityIdentifier("settings-api-port")
                    .focused($isAPIPortFocused)
                    .onSubmit { if commitAPIPort() { isAPIPortFocused = false } }
                    .onChange(of: isAPIPortFocused) { _, focused in
                        if !focused { _ = commitAPIPort() }
                    }
                }
            }
            Text(verbatim: "Base URL: http://127.0.0.1:\(store.settings.localAPIPort)")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.leading, 10).padding(.top, 11)
                .offset(y: -0.5)
            if let apiPortError {
                Text(apiPortError).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.top, 6)
                    .accessibilityIdentifier("settings-api-port-error")
            }
            settingsHeading("AI 集成").offset(y: -3.5).padding(.top, 32).padding(.bottom, 6)
            settingsCard {
                settingsRow(height: 41, contentOffset: -2.5) {
                    Text(verbatim: "MCP")
                    Spacer()
                    Button("配置…") { showMCPConfiguration = true }
                        .disabled(bundledCLI == nil)
                }
                settingsRow(height: 41, divider: false, contentOffset: -2.5) {
                    Text(verbatim: "Skill")
                    Spacer()
                    Button("导出…") {
                        exportAgentResource(command: "export-skill", name: "SKILL.md", title: "导出 Agent Skill…", types: [.plainText])
                    }
                    .disabled(bundledCLI == nil)
                }
            }
            .offset(y: -0.5)
            Text("请保持 PaperManager 运行并启用本地 API。只读模式会限制写入。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 10)
            DisclosureGroup("更多集成选项") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("状态", value: localAPI.statusText)
                    LabeledContent("文件库", value: fileLibraryStatus.availability.label)
                    Text("浏览器、命令行和迁移的文件位置统一由“通用 → 文件库”管理。启用本地 API 后即可使用浏览器集成。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("导出 MCP 配置…") {
                        exportAgentResource(command: "export-mcp-config", name: "papermanager-mcp.json", title: "导出 MCP 配置…", types: [.json])
                    }
                    .disabled(bundledCLI == nil)
                    Button("显示浏览器扩展…") {
                        if let folder = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    .disabled(Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) == nil)
                    Text("导出的配置默认只读，并使用当前端口。浏览器扩展需要在浏览器中自行载入和授权。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 32)
        }
        .buttonStyle(.bordered)
    }

    @discardableResult
    private func commitAPIPort() -> Bool {
        guard let draft = apiPortDraft else { return true }
        guard store.updateLocalAPIPort(from: draft) else {
            apiPortError = store.statusMessage
            return false
        }
        apiPortDraft = nil
        apiPortError = nil
        return true
    }

    private var mcpInstructions: String {
        let executable = bundledCLI?.path ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PaperManagerCLI").path
        return PMLocalization.format("""
        请为当前 AI 客户端配置 PaperManager MCP。
        名称: papermanager
        可执行文件: %@
        参数: --port %@ --read-only mcp
        先检查现有配置，修改前征求同意。不要更改 PaperManager 的本地 API 或只读设置。
        """, executable, String(store.settings.localAPIPort))
    }

    private var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PaperManagerCLI")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func exportAgentResource(command: String, name: String, title: String, types: [UTType]) {
        guard let cli = bundledCLI,
              let destination = DialogService.saveURL(title: title, name: name, types: types) else { return }
        do {
            let process = Process()
            let output = Pipe(), errors = Pipe()
            process.executableURL = cli
            process.arguments = ["--port", String(store.settings.localAPIPort), "--read-only", command]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PaperManagerError.message(String(decoding: diagnostics, as: UTF8.self))
            }
            try data.write(to: destination, options: .atomic)
            store.statusMessage = PMLocalization.format("已导出到 %@", destination.lastPathComponent)
        } catch { store.statusMessage = error.localizedDescription }
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHeading("文库", weight: .semibold).offset(y: -0.5).padding(.bottom, 8)
            settingsCard {
                settingsRow(height: 38, contentOffset: -0.5) {
                    settingsSwitch("包含已链接的 PDF 和附件", isOn: $includeBackupFiles)
                }
                settingsRow(height: 40, divider: false, contentOffset: -2) {
                    Text("备份与恢复")
                    Spacer()
                    Button("备份") { createBackup() }
                    Button("恢复") { restoreBackup() }
                }
            }
            .disabled(store.isBusy)
            settingsHeading("从外部导入", weight: .semibold).offset(y: -4).padding(.top, 33).padding(.bottom, 6)
            settingsCard {
                settingsRow(height: 40, divider: false, contentOffset: -2) {
                    Text("Zotero 迁移")
                    Spacer()
                    Button("导入") { showZoteroImport = true }.disabled(store.isBusy)
                }
            }
            .offset(y: -1)
            Text("选择包含 zotero.sqlite 的文件夹。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
            DisclosureGroup("更多备份选项与文库信息") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("恢复 Lattice 备份…") { restoreLatticeArchive() }.disabled(store.isBusy)
                    metricRow("文献", value: "\(store.snapshot.papers.count)")
                    metricRow("文集", value: "\(store.snapshot.collections.count)")
                    metricRow("标签", value: "\(store.snapshot.tags.count)")
                    metricRow("附件文件", value: "\(store.snapshot.papers.flatMap(\.attachments).count)")
                    Text(store.persistenceURL.path).textSelection(.enabled).lineLimit(2)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 10).padding(.top, 28)
        }
        .buttonStyle(.bordered)
    }

    private func metricRow(_ title: String, value: String) -> some View {
        LabeledContent(PMLocalization.text(title)) {
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var fileLibraryStatus: FileLibraryStatus { FileLibraryService.status(for: store.settings) }

    private func chooseFileLibrary(suggestedRoot: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = PMLocalization.text("授权 PaperManager 文件库")
        panel.prompt = PMLocalization.text("使用此文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedRoot ?? fileLibraryStatus.rootURL
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            var settings = store.settings
            let layout = FileLibraryService.preferences(for: settings).layout
            let preferences = try FileLibraryService.authorizedPreferences(root: folder, layout: layout)
            settings.fileLibrary = preferences
            // Keep pre-3.0 callers and old backups aligned with the one root.
            settings.pdfOrganizationFolder = preferences.rootPath
            settings.browserUploadFolder = preferences.rootPath
            guard store.updateSettings(settings) else { return }
            store.statusMessage = PMLocalization.text("文件库已授权，现有文件保留原位置。")
        } catch { store.statusMessage = error.localizedDescription }
    }

    private func resetFileLibrary(declined: Bool) {
        var settings = store.settings
        settings.fileLibrary = FileLibraryPreferences(decision: declined ? .declined : .notAsked,
                                                       layout: FileLibraryService.preferences(for: settings).layout)
        settings.pdfOrganizationFolder = ""
        settings.browserUploadFolder = ""
        settings.pdfOrganizationMode = .none
        guard store.updateSettings(settings) else { return }
        store.statusMessage = PMLocalization.text("现有文件保留原位置。")
    }

    private func applyFileLibraryToExistingPapers() {
        _ = store.enqueueFileOperation(paperIDs: Set(store.papers.map(\.id)))
    }

    private var selectedReaderName: String {
        guard let path = store.settings.defaultPDFReaderPath.nilIfBlank else {
            return PMLocalization.text("系统默认")
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            store.settings[keyPath: keyPath]
        } set: { value in
            store.updateSetting(keyPath, value: value)
        }
    }

    private var samplePaper: Paper {
        var paper = Paper()
        paper.title = "Attention Is All You Need"
        paper.authors = ["Vaswani, Ashish"]
        paper.year = 2017
        paper.journal = "NeurIPS"
        paper.doi = "10.48550/arXiv.1706.03762"
        return paper
    }

    private var sampleCitationPaper: Paper {
        Paper(title: "Relativity", authors: ["Einstein, Albert"], year: 1905)
    }

    private var samplePDFFilename: String {
        var paper = sampleCitationPaper
        paper.title = "On the Electrodynamics of Moving Bodies"
        paper.citekey = CitekeyGenerator.render(format: store.settings.citekeyFormat, paper: paper)
        let stem = FileLibraryService.filenameStem(paper: paper, template: store.settings.pdfRenameTemplate,
                                                   fallback: paper.title)
        return stem.sanitizedFileName() + ".pdf"
    }

    private var samplePaperForTemplate: Paper {
        var paper = samplePaper
        paper.abstract = "A compact sample abstract for previewing metadata templates."
        paper.notes = "Reader notes appear here."
        paper.annotations = [
            ResearchAnnotation(page: 3, kind: .highlight, selectedText: "Scaled dot-product attention is efficient.", note: "Key method.")
        ]
        return paper
    }

    private var previewSnapshot: LibrarySnapshot {
        var snapshot = store.snapshot
        snapshot.settings = store.settings
        return snapshot
    }

    private func createBackup() {
        let name = "PaperManager Backup \(ISO8601DateFormatter().string(from: Date()).prefix(10)).papermanager"
        guard let url = DialogService.saveURL(title: "选择文库备份位置", name: String(name), types: [.paperManagerBackup]) else { return }
        guard PaperDraftSession.flushAll() else {
            store.statusMessage = PMLocalization.text("草稿未能保存，已停止备份。请解决保存问题后重试。")
            return
        }
        let snapshot = store.snapshot, includeFiles = includeBackupFiles
        store.isBusy = true
        store.statusMessage = PMLocalization.text("正在创建文库备份…")
        Task {
            defer { store.isBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try BackupService.writeBackup(snapshot: snapshot, to: url, includeFiles: includeFiles)
                }.value
                store.statusMessage = PMLocalization.text("备份完成。")
            } catch { store.statusMessage = PMLocalization.format("备份失败：%@", error.localizedDescription) }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = PMLocalization.text("恢复文库备份")
        panel.allowedContentTypes = [.paperManagerBackup, .json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirm = NSAlert()
        confirm.messageText = PMLocalization.text("用备份替换当前文库？")
        confirm.informativeText = PMLocalization.text("恢复前会另存当前文库。PDF 和附件将提取到独立目录，现有文件保留。")
        confirm.addButton(withTitle: PMLocalization.text("恢复"))
        confirm.addButton(withTitle: PMLocalization.text("取消"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        guard PaperDraftSession.flushAll() else {
            store.statusMessage = PMLocalization.text("草稿未能保存，已停止恢复。请解决保存问题后重试。")
            return
        }
        let previous = store.snapshot
        let revision: Data
        do { revision = try store.snapshotRevisionToken() }
        catch { store.statusMessage = error.localizedDescription; return }
        let directory = store.persistenceURL.deletingLastPathComponent()
        let preserved = directory.appendingPathComponent("BeforeRestore-\(UUID().uuidString).papermanager")
        let restoredFiles = directory.appendingPathComponent("RestoredBackups", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        store.isBusy = true
        store.statusMessage = PMLocalization.text("正在验证并恢复文库…")
        Task {
            var committed = false
            defer {
                store.isBusy = false
                if !committed { try? FileManager.default.removeItem(at: restoredFiles) }
            }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try BackupService.writeBackup(snapshot: previous, to: preserved, includeFiles: false)
                    return try BackupService.readBackup(from: url, filesDirectory: restoredFiles)
                }.value
                guard PaperDraftSession.flushAll() else {
                    throw PaperManagerError.message(PMLocalization.text("草稿未能保存，已停止恢复。请解决保存问题后重试。"))
                }
                try store.replaceSnapshotDurably(snapshot, expectedRevision: revision)
                committed = true
                store.statusMessage = PMLocalization.text("恢复完成，原文库备份已另存。")
            } catch { store.statusMessage = PMLocalization.format("恢复失败：%@", error.localizedDescription) }
        }
    }

    private func restoreLatticeArchive() {
        guard let url = DialogService.chooseFiles(title: "选择 Lattice 文库备份", types: [.latticeBackup, .zip], multiple: false).first else { return }
        guard PaperDraftSession.flushAll() else {
            store.statusMessage = PMLocalization.text("草稿未能保存，已停止恢复。请解决保存问题后重试。")
            return
        }
        let fallback = store.snapshot
        let revision: Data
        do { revision = try store.snapshotRevisionToken() }
        catch { store.statusMessage = error.localizedDescription; return }
        let importedDirectory = store.persistenceURL.deletingLastPathComponent()
            .appendingPathComponent("ImportedLattice", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store.isBusy = true
        store.statusMessage = PMLocalization.text("正在读取 Lattice 备份并复制 PDF…")
        Task {
            var committed = false
            defer {
                store.isBusy = false
                if !committed { try? FileManager.default.removeItem(at: importedDirectory) }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LatticeArchiveService.readArchive(at: url, fallbackSnapshot: fallback, materializePDFsTo: importedDirectory)
                }.value
                guard PaperDraftSession.flushAll() else {
                    throw PaperManagerError.message(PMLocalization.text("草稿未能保存，已停止恢复。请解决保存问题后重试。"))
                }
                try LatticeArchiveService.persist(result, into: store, expectedRevision: revision)
                committed = true
                store.statusMessage = PMLocalization.format("已恢复 %lld 篇文献、%lld 条标注。", result.snapshot.papers.count, result.snapshot.papers.reduce(0) { $0 + $1.annotations.count }) + result.warnings.joined(separator: " ")
            } catch {
                store.statusMessage = PMLocalization.format("Lattice 备份恢复失败：%@", error.localizedDescription)
            }
        }
    }
}

private struct SettingsMCPConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("配置 MCP")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 14)
            Text("将以下内容发送给你的 AI agent:")
                .font(.system(size: 13))
                .padding(.bottom, 12)
            ScrollView {
                Text(instructions)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Spacer()
                Button("复制指令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instructions, forType: .string)
                }
                .keyboardShortcut(.defaultAction)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 470, height: 267)
    }
}

private struct NativeSettingsContainer: NSViewControllerRepresentable {
    @Binding var selection: SettingsPane
    var detail: AnyView

    func makeNSViewController(context: Context) -> NativeSettingsSplitController {
        NativeSettingsSplitController(selection: $selection, detail: detail)
    }

    func updateNSViewController(_ controller: NativeSettingsSplitController, context: Context) {
        controller.update(selection: $selection, detail: detail)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeSettingsSplitController, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }

    static func dismantleNSViewController(_ controller: NativeSettingsSplitController, coordinator: ()) {
        controller.view.window?.makeFirstResponder(nil)
    }
}

private final class NativeSettingsSplitController: NSSplitViewController {
    private let navigation = NativeSettingsSidebarController()
    private let detail: NSHostingController<AnyView>

    init(selection: Binding<SettingsPane>, detail: AnyView) {
        self.detail = NSHostingController(rootView: detail)
        // The split controller owns pane sizes; a SwiftUI content max size must
        // not constrain the surrounding native window to the current form.
        self.detail.sizingOptions = []
        self.detail.safeAreaRegions = []
        self.detail.sceneBridgingOptions = []
        if let view = self.detail.view as? NSHostingView<AnyView> {
            view.sizingOptions = []
            view.safeAreaRegions = []
            view.sceneBridgingOptions = []
        }
        super.init(nibName: nil, bundle: nil)
        navigation.selection = selection
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = nil
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigation)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 200
        sidebar.canCollapse = false
        addSplitViewItem(sidebar)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
    }

    func update(selection: Binding<SettingsPane>, detail: AnyView) {
        navigation.selection = selection
        navigation.reloadLocalizedTitles()
        self.detail.rootView = detail
    }
}

private final class NativeSettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var selection: Binding<SettingsPane>?
    private let table = NSTableView()

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        let column = NSTableColumn(identifier: .init("settings"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        material.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 52),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12)
        ])
        view = material
        selectCurrentPane()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsPane.allCases.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsNavigationRowView()
    }


    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard SettingsPane.allCases.indices.contains(row) else { return nil }
        let pane = SettingsPane.allCases[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: pane.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = sidebarFont(selected: tableView.isRowSelected(row))
        image.contentTintColor = .systemBlue
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: pane == .general ? 0.5 : 0),
            image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionFonts()
        guard SettingsPane.allCases.indices.contains(table.selectedRow), let selection else { return }
        let pane = SettingsPane.allCases[table.selectedRow]
        if selection.wrappedValue != pane { selection.wrappedValue = pane }
    }

    func selectCurrentPane() {
        guard isViewLoaded, let selection, let row = SettingsPane.allCases.firstIndex(of: selection.wrappedValue) else { return }
        if row != table.selectedRow { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateSelectionFonts()
    }

    private func sidebarFont(selected: Bool) -> NSFont {
        .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }

    private func updateSelectionFonts() {
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let label = cell.textField else { continue }
            let font = sidebarFont(selected: table.isRowSelected(row))
            if label.font != font { label.font = font }
        }
    }

    func reloadLocalizedTitles() {
        guard isViewLoaded else { return }
        let pane = selection?.wrappedValue
        table.reloadData()
        if let pane, let row = SettingsPane.allCases.firstIndex(of: pane) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        selectCurrentPane()
    }
}

private final class SettingsNavigationRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case citation
    case localAPI
    case backup
    case templates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return PMLocalization.text("通用")
        case .citation: return PMLocalization.text("引用")
        case .localAPI: return PMLocalization.text("集成")
        case .backup: return PMLocalization.text("备份")
        case .templates: return PMLocalization.text("模板")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gear"
        case .citation: return "text.quote"
        case .localAPI: return "globe"
        case .backup: return "externaldrive.badge.timemachine"
        case .templates: return "doc.text"
        }
    }
}
