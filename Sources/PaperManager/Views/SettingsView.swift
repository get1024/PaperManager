import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer
    @State private var selectedPane: SettingsPane = .general
    @State private var includeBackupFiles = true
    @State private var showZoteroImport = false

    var body: some View {
        NativeSettingsContainer(selection: $selectedPane, detail: AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Text(selectedPane.title)
                    .font(PMTypography.title)
                    .padding(.top, 42)

                selectedContent
                    .font(PMTypography.body)
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(store)
            .environmentObject(localAPI)
            .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        ))
        .font(PMTypography.body)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowChromeConfigurator { window in
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.isMovableByWindowBackground = true
        })
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
        .environment(\.locale, PMLocalization.locale(for: store.settings.languageIdentifier))
        .sheet(isPresented: $showZoteroImport) { ZoteroImportView(store: store) }
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

    private var general: some View {
        Form {
            Section("界面") {
                Picker("界面语言", selection: Binding(
                    get: { store.settings.languageIdentifier },
                    set: { language in
                        PMLocalization.configure(language)
                        if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                        else { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
                        store.updateSetting(\.languageIdentifier, value: language)
                        store.statusMessage = PMLocalization.text("语言已更改。系统菜单将在重新打开应用后更新。")
                    }
                )) {
                    Text("跟随系统").tag("system")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                }

                Picker("外观", selection: binding(\.appearance)) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }

                Picker("表格密度", selection: binding(\.tableDensity)) {
                    ForEach(TableDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }

                Toggle("默认显示检查器", isOn: binding(\.showInspectorByDefault))
            }

            Section("阅读器") {
                LabeledContent("默认 PDF 阅读器") {
                    HStack {
                        Text(selectedReaderName)
                            .foregroundStyle(.secondary)
                        Button("选择") {
                            if let app = DialogService.chooseApplication(title: "选择默认 PDF 阅读器") {
                                store.updateSetting(\.defaultPDFReaderPath, value: app.path)
                            }
                        }
                        Button("重置") {
                            store.updateSetting(\.defaultPDFReaderPath, value: "")
                        }
                        .disabled(store.settings.defaultPDFReaderPath.trimmed.isEmpty)
                    }
                }
            }

            Section("文件库") {
                LabeledContent("状态", value: fileLibraryStatus.availability.label)
                LabeledContent("位置") {
                    HStack {
                        Text(fileLibraryStatus.rootURL?.path ?? PMLocalization.text("未选择文件夹"))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button(PMLocalization.text(fileLibraryStatus.availability == .unavailable ? "重新授权" : "更改…")) { chooseFileLibrary() }
                        Button("重置") { resetFileLibrary(declined: false) }
                    }
                }
                if fileLibraryStatus.availability == .legacyConflict {
                    Text("两个旧位置都已保留。请选择今后使用的单个文件库，现有文件不会移动。")
                        .foregroundStyle(.secondary)
                    ForEach(FileLibraryService.preferences(for: store.settings).legacyConflictPaths, id: \.self) { path in
                        Button("选择 \(path)…") { chooseFileLibrary(suggestedRoot: URL(fileURLWithPath: path)) }
                    }
                }
                if fileLibraryStatus.availability == .notAsked {
                    Button("将本地文件保留在原位置") { resetFileLibrary(declined: true) }
                }
                Picker("本地文件操作", selection: binding(\.pdfOrganizationMode)) {
                    ForEach(PDFOrganizationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                            .disabled(mode != .none && !fileLibraryStatus.isAvailable)
                    }
                }

                Picker("子文件夹分组", selection: binding(\.pdfSubfolderGrouping)) {
                    ForEach(PDFSubfolderGrouping.allCases) { grouping in
                        Text(grouping.label).tag(grouping)
                    }
                }

                Picker("文件布局", selection: Binding(
                    get: { FileLibraryService.preferences(for: store.settings).layout },
                    set: { layout in
                        var settings = store.settings
                        var preferences = FileLibraryService.preferences(for: settings)
                        preferences.layout = layout
                        settings.fileLibrary = preferences
                        store.updateSettings(settings)
                    }
                )) {
                    ForEach(FileLibraryLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                Text("新位置和布局用于今后的文件操作。已关联文件会保留原位置，放入文件库的文件不会自动导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("应用到现有文献的文件…") { applyFileLibraryToExistingPapers() }
                    .disabled(!fileLibraryStatus.isAvailable || store.papers.isEmpty)

                Toggle("移除文献时，将关联文件移到废纸篓", isOn: binding(\.deleteAttachmentsToTrash))
                Toggle("自动重命名 PDF", isOn: binding(\.autoRenamePDFs))
                Toggle("移动或复制 PDF 前确认", isOn: binding(\.confirmBeforeMovingFiles))
                TextField("格式", text: binding(\.pdfRenameTemplate))
                    .font(PMTypography.monospacedBody)
                Text("示例：1905 - Einstein - On the Electrodynamics of Moving Bodies.pdf")
                    .foregroundStyle(.secondary)
            }

            Section("自动处理") {
                Toggle("导入后自动补全元数据", isOn: binding(\.autoExtractMetadataAfterImport))
                Toggle("导入后自动提取标注", isOn: binding(\.autoExtractAnnotationsAfterImport))
                Toggle("打开 PDF 后自动刷新标注", isOn: binding(\.autoExtractAnnotationsAfterOpeningPDF))
            }
        }
    }

    private var citation: some View {
        Form {
            Section("引用键格式") {
                TextField("格式", text: binding(\.citekeyFormat))
                    .font(PMTypography.monospacedBody)

                LabeledContent("预览") {
                    Text(CitekeyGenerator.render(format: store.settings.citekeyFormat, paper: sampleCitationPaper))
                        .font(PMTypography.monospacedBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("导出字段") {
                ForEach(CitationExportField.allCases) { field in
                    Toggle(field.label, isOn: Binding(
                        get: { store.settings.includesCitationExport(field) },
                        set: { included in
                            var settings = store.settings
                            settings.setCitationExport(field, included: included)
                            store.updateSettings(settings)
                        }
                    ))
                }

                Text("其他所有非空字段都会始终导出。要从某篇文献的导出中移除某个值，请编辑该文献的元数据。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("可用变量：{auth}、{year}、{year2}、{title}、{titleWord}、{journal}、{doi}；同时支持旧版 {{author}}、{{authorLower}}、{{authorInitial}} 等双花括号格式。修改格式后，文库的 citekey 会自动更新。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var templates: some View {
        Form {
            Section("当前模板") {
                Picker("模板", selection: Binding(
                    get: { store.snapshot.selectedMetadataTemplate.id },
                    set: { id in editTemplates { try $0.selectMetadataTemplate(id: id) } }
                )) {
                    ForEach(store.snapshot.availableMetadataTemplates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                TextField("模板名称", text: Binding(
                    get: { store.snapshot.selectedMetadataTemplate.name },
                    set: { name in editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, name: name) } }
                ))
                HStack {
                    Button("新建模板") {
                        editTemplates { _ = try $0.addMetadataTemplate(name: PMLocalization.text("新建模板")) }
                    }
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
            }
            Section("模板正文") {
                Button {
                    editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, content: AppSettings.defaultMetadataTemplate) }
                } label: {
                    Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                }

                TextEditor(text: Binding(
                    get: { store.snapshot.selectedMetadataTemplate.content },
                    set: { content in editTemplates { try $0.updateMetadataTemplate(id: $0.selectedMetadataTemplate.id, content: content) } }
                ))
                    .font(PMTypography.monospacedBody)
                    .frame(minHeight: 240)
            }

            Section("标注正文") {
                Button {
                    store.updateSetting(\.annotationTemplate, value: AppSettings.defaultAnnotationTemplate)
                } label: {
                    Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                }

                TextEditor(text: binding(\.annotationTemplate))
                    .font(PMTypography.monospacedBody)
                    .frame(minHeight: 120)
            }

            Section("预览") {
                ScrollView {
                    Text(TemplateRenderer.renderMetadata(paper: samplePaperForTemplate, snapshot: previewSnapshot))
                        .font(PMTypography.monospacedBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180)
            }
        }
    }

    private func editTemplates(_ edit: (inout LibrarySnapshot) throws -> Void) {
        do { try MetadataTemplateService.update(in: store, edit) }
        catch { store.statusMessage = error.localizedDescription }
    }

    private var localAPISettings: some View {
        Form {
            Section("服务") {
                Toggle("启用", isOn: binding(\.localAPIEnabled))
                Toggle("只读模式", isOn: binding(\.localAPIReadOnly))
                TextField("端口", text: Binding(
                    get: { String(store.settings.localAPIPort) },
                    set: { store.updateSetting(\.localAPIPort, value: Int($0.trimmed) ?? 29467) }
                ))

                LabeledContent("文件库", value: fileLibraryStatus.availability.label)
                Text("浏览器、命令行和迁移的文件位置统一由“通用 → 文件库”管理。启用本地 API 后即可使用浏览器集成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接信息") {
                LabeledContent("Base URL") {
                    Text("http://127.0.0.1:\(store.settings.localAPIPort)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("状态") {
                    Text(localAPI.statusText)
                        .foregroundStyle(localAPI.isRunning ? .green : .secondary)
                }
            }

            Section("智能体与浏览器") {
                Button("导出 Agent Skill…") {
                    exportAgentResource(command: "export-skill", name: "SKILL.md", title: "导出 Agent Skill…", types: [.plainText])
                }
                .disabled(bundledCLI == nil)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
        Form {
            Section("备份与恢复") {
                Toggle("包含已链接的 PDF 和附件", isOn: $includeBackupFiles)
                Button {
                    createBackup()
                } label: {
                    Label("备份当前文库", systemImage: "archivebox")
                }

                Button {
                    restoreBackup()
                } label: {
                    Label("恢复文库", systemImage: "arrow.counterclockwise")
                }
                Button {
                    restoreLatticeArchive()
                } label: {
                    Label("恢复 Lattice 备份…", systemImage: "tray.and.arrow.down")
                }
                .disabled(store.isBusy)
            }
            .disabled(store.isBusy)
            Section("从外部导入") {
                Button("从 Zotero 导入…") { showZoteroImport = true }
                    .disabled(store.isBusy)
                Text("导入文献、文集、笔记和标注；复制 PDF 时使用已授权文件库，Zotero 原文件保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("当前文库") {
                metricRow("文献", value: "\(store.snapshot.papers.count)")
                metricRow("文集", value: "\(store.snapshot.collections.count)")
                metricRow("标签", value: "\(store.snapshot.tags.count)")
                metricRow("附件文件", value: "\(store.snapshot.papers.flatMap(\.attachments).count)")
                LabeledContent("文库文件") {
                    Text(store.persistenceURL.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
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
            settings.browserExtensionEnabled = true
            store.updateSettings(settings)
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
        store.updateSettings(settings)
        store.statusMessage = PMLocalization.text("现有文件保留原位置。")
    }

    private func applyFileLibraryToExistingPapers() {
        do {
            let summary = try store.organizeFiles(paperIDs: Set(store.papers.map(\.id)))
            store.statusMessage = summary.text
        } catch { store.statusMessage = error.localizedDescription }
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
        super.init(nibName: nil, bundle: nil)
        navigation.selection = selection
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "PaperManager.Settings.Split"
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigation)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 240
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
        material.blendingMode = .behindWindow
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 4)
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
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 48),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12)
        ])
        view = material
        selectCurrentPane()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsPane.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard SettingsPane.allCases.indices.contains(row) else { return nil }
        let pane = SettingsPane.allCases[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: pane.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard SettingsPane.allCases.indices.contains(table.selectedRow), let selection else { return }
        let pane = SettingsPane.allCases[table.selectedRow]
        if selection.wrappedValue != pane { selection.wrappedValue = pane }
    }

    func selectCurrentPane() {
        guard isViewLoaded, let selection, let row = SettingsPane.allCases.firstIndex(of: selection.wrappedValue), row != table.selectedRow else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func reloadLocalizedTitles() {
        guard isViewLoaded else { return }
        let pane = selection?.wrappedValue
        table.reloadData()
        if let pane, let row = SettingsPane.allCases.firstIndex(of: pane) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        selectCurrentPane()
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
        case .general: return "gearshape"
        case .citation: return "quote.bubble"
        case .localAPI: return "network"
        case .backup: return "externaldrive"
        case .templates: return "doc.text"
        }
    }
}
