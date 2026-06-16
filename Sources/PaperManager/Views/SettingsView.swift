import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    Text("PaperManager")
                        .font(PMTypography.latinFont(size: 22, weight: .bold))
                    Text(" 设置")
                        .font(PMTypography.largeTitle)
                }
                    .padding(.top, 24)

                selectedContent
                    .font(PMTypography.body)
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(PMTypography.body)
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
    }

    private var settingsSidebar: some View {
        List(selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .font(PMTypography.sidebarRow)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 46)
        }
        .frame(width: 204)
        .background(Color(nsColor: .controlBackgroundColor))
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
                Picker("语言", selection: binding(\.languageIdentifier)) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
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

            Section("PDF 整理") {
                Picker("操作", selection: binding(\.pdfOrganizationMode)) {
                    ForEach(PDFOrganizationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("子文件夹分组", selection: binding(\.pdfSubfolderGrouping)) {
                    ForEach(PDFSubfolderGrouping.allCases) { grouping in
                        Text(grouping.label).tag(grouping)
                    }
                }

                LabeledContent("位置") {
                    HStack {
                        Text(store.settings.pdfOrganizationFolder.nilIfBlank ?? "未选择文件夹")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("选择") {
                            if let folder = DialogService.chooseFolder(title: "选择 PDF 整理文件夹") {
                                store.updateSetting(\.pdfOrganizationFolder, value: folder.path)
                            }
                        }
                        Button("重置") {
                            store.updateSetting(\.pdfOrganizationFolder, value: "")
                        }
                        .disabled(store.settings.pdfOrganizationFolder.trimmed.isEmpty)
                    }
                }

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
            Section("Citekey") {
                TextField("格式", text: binding(\.citekeyFormat))
                    .font(PMTypography.monospacedBody)

                LabeledContent("预览") {
                    Text(CitekeyGenerator.render(format: store.settings.citekeyFormat, paper: samplePaper))
                        .font(PMTypography.monospacedBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("应用到全部文献") {
                    store.regenerateCitekeys()
                }
            }

            Section {
                Text("可用变量：{{author}}, {{authorLower}}, {{authorInitial}}, {{year}}, {{year2}}, {{title}}, {{titleWord}}, {{journal}}, {{doi}}。模板导出还可使用 subtitle、editors、translators、booktitle、urlDate、eprint 等字段。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var templates: some View {
        Form {
            Section("模板正文") {
                Button {
                    store.updateSetting(\.metadataTemplate, value: AppSettings.defaultMetadataTemplate)
                } label: {
                    Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                }

                TextEditor(text: binding(\.metadataTemplate))
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

    private var localAPISettings: some View {
        Form {
            Section("服务") {
                Toggle("启用", isOn: binding(\.localAPIEnabled))
                Toggle("只读模式", isOn: binding(\.localAPIReadOnly))
                Toggle("浏览器扩展", isOn: binding(\.browserExtensionEnabled))
                TextField("端口", text: Binding(
                    get: { String(store.settings.localAPIPort) },
                    set: { store.updateSetting(\.localAPIPort, value: Int($0.trimmed) ?? 29467) }
                ))

                LabeledContent("浏览器上传文件夹") {
                    HStack {
                        Text(store.settings.browserUploadFolder.nilIfBlank ?? "未选择文件夹")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("选择") {
                            if let folder = DialogService.chooseFolder(title: "选择浏览器 PDF 上传文件夹") {
                                store.updateSetting(\.browserUploadFolder, value: folder.path)
                            }
                        }
                    }
                }
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
        }
    }

    private var backup: some View {
        Form {
            Section("备份与恢复") {
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
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedReaderName: String {
        guard let path = store.settings.defaultPDFReaderPath.nilIfBlank else {
            return "系统默认"
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
        do {
            try BackupService.writeBackup(snapshot: store.snapshot, to: url)
            store.statusMessage = "备份完成。"
        } catch {
            store.statusMessage = "备份失败：\(error.localizedDescription)"
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = "恢复文库备份"
        panel.allowedContentTypes = [.paperManagerBackup, .json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try BackupService.readBackup(from: url)
            store.replaceSnapshot(snapshot)
            store.statusMessage = "恢复完成。"
        } catch {
            store.statusMessage = "恢复失败：\(error.localizedDescription)"
        }
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
        case .general: return "通用"
        case .citation: return "引用"
        case .localAPI: return "本地 API"
        case .backup: return "备份"
        case .templates: return "模板"
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
