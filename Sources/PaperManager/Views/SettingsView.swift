import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var localAPI: LocalAPIServer
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 210)

            Rectangle()
                .fill(LatticeStyle.separator)
                .frame(width: 0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("PaperManager 设置")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.top, 22)

                    selectedContent
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LatticeStyle.contentBackground)
        }
        .background(LatticeStyle.sidebarBackground)
        .preferredColorScheme(store.settings.appearance.preferredColorScheme)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
                .frame(height: 36)

            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: pane.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 22)
                        Text(pane.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundStyle(selectedPane == pane ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedPane == pane ? LatticeStyle.selectedFill : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .background(LatticeStyle.sidebarBackground)
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
        VStack(alignment: .leading, spacing: 22) {
            LatticeSection("界面") {
                LatticeSettingsRow("语言") {
                    Picker("", selection: binding(\.languageIdentifier)) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                LatticeDivider()
                LatticeSettingsRow("外观") {
                    Picker("", selection: binding(\.appearance)) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            LatticeSection("阅读器") {
                LatticeSettingsRow("默认 PDF 阅读器", subtitle: selectedReaderName) {
                    HStack {
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

            LatticeSection("PDF 整理") {
                LatticeSettingsRow("操作") {
                    Picker("", selection: binding(\.pdfOrganizationMode)) {
                        ForEach(PDFOrganizationMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                LatticeDivider()
                LatticeSettingsRow("子文件夹分组") {
                    Picker("", selection: binding(\.pdfSubfolderGrouping)) {
                        ForEach(PDFSubfolderGrouping.allCases) { grouping in
                            Text(grouping.label).tag(grouping)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                LatticeDivider()
                LatticeSettingsRow("位置", subtitle: store.settings.pdfOrganizationFolder.nilIfBlank ?? "未选择文件夹") {
                    HStack {
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
                LatticeDivider()
                LatticeSettingsRow("移除文献时，将关联文件移到废纸篓") {
                    Toggle("", isOn: binding(\.deleteAttachmentsToTrash))
                        .labelsHidden()
                }
                LatticeDivider()
                LatticeSettingsRow("自动重命名 PDF") {
                    Toggle("", isOn: binding(\.autoRenamePDFs))
                        .labelsHidden()
                }
                LatticeDivider()
                LatticeSettingsRow("格式") {
                    TextField("{{year}} - {{author}} - {{title}}", text: binding(\.pdfRenameTemplate))
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 290)
                }
                Text("示例：1905 - Einstein - On the Electrodynamics of Moving Bodies.pdf")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var citation: some View {
        VStack(alignment: .leading, spacing: 22) {
            LatticeSection("Citekey") {
                LatticeSettingsRow("格式") {
                    TextField("{{authorLower}}{{year}}{{titleWord}}", text: binding(\.citekeyFormat))
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 300)
                }
                LatticeDivider()
                LatticeSettingsRow("预览") {
                    Text(CitekeyGenerator.render(format: store.settings.citekeyFormat, paper: samplePaper))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LatticeDivider()
                LatticeSettingsRow("重新生成") {
                    Button("应用到全部文献") {
                        store.regenerateCitekeys()
                    }
                }
            }

            Text("可用变量：{{author}}, {{authorLower}}, {{authorInitial}}, {{year}}, {{year2}}, {{title}}, {{titleWord}}, {{journal}}, {{doi}}。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("模板正文")
                        .font(.headline)
                    Spacer()
                    Button {
                        store.updateSetting(\.metadataTemplate, value: AppSettings.defaultMetadataTemplate)
                    } label: {
                        Label("恢复", systemImage: "arrow.counterclockwise")
                    }
                }
                LatticeCard {
                    TextEditor(text: binding(\.metadataTemplate))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("标注正文")
                        .font(.headline)
                    Spacer()
                    Button {
                        store.updateSetting(\.annotationTemplate, value: AppSettings.defaultAnnotationTemplate)
                    } label: {
                        Label("恢复", systemImage: "arrow.counterclockwise")
                    }
                }
                LatticeCard {
                    TextEditor(text: binding(\.annotationTemplate))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(14)
                }
            }
        }
    }

    private var localAPISettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            LatticeSection("服务") {
                LatticeSettingsRow("启用") {
                    Toggle("", isOn: binding(\.localAPIEnabled))
                        .labelsHidden()
                }
                LatticeDivider()
                LatticeSettingsRow("只读模式") {
                    Toggle("", isOn: binding(\.localAPIReadOnly))
                        .labelsHidden()
                }
                LatticeDivider()
                LatticeSettingsRow("浏览器扩展") {
                    Toggle("", isOn: binding(\.browserExtensionEnabled))
                        .labelsHidden()
                }
                LatticeDivider()
                LatticeSettingsRow("端口") {
                    TextField("29467", text: Binding(
                        get: { String(store.settings.localAPIPort) },
                        set: { store.updateSetting(\.localAPIPort, value: Int($0.trimmed) ?? 29467) }
                    ))
                    .textFieldStyle(.plain)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                }
                LatticeDivider()
                LatticeSettingsRow("浏览器上传文件夹", subtitle: store.settings.browserUploadFolder.nilIfBlank ?? "未选择文件夹") {
                    Button("选择") {
                        if let folder = DialogService.chooseFolder(title: "选择浏览器 PDF 上传文件夹") {
                            store.updateSetting(\.browserUploadFolder, value: folder.path)
                        }
                    }
                }
            }

            LatticeSection("连接信息") {
                LatticeSettingsRow("Base URL") {
                    Text("http://127.0.0.1:\(store.settings.localAPIPort)")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LatticeDivider()
                LatticeSettingsRow("状态") {
                    Text(localAPI.statusText)
                        .foregroundStyle(localAPI.isRunning ? .green : .secondary)
                }
            }
        }
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 22) {
            LatticeSection("备份与恢复") {
                LatticeSettingsRow("备份当前文库") {
                    Button {
                        createBackup()
                    } label: {
                        Label("备份", systemImage: "archivebox")
                    }
                }
                LatticeDivider()
                LatticeSettingsRow("恢复文库") {
                    Button {
                        restoreBackup()
                    } label: {
                        Label("恢复", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            LatticeSection("当前文库") {
                metricRow("文献", value: "\(store.snapshot.papers.count)")
                LatticeDivider()
                metricRow("文集", value: "\(store.snapshot.collections.count)")
                LatticeDivider()
                metricRow("标签", value: "\(store.snapshot.tags.count)")
                LatticeDivider()
                metricRow("附件文件", value: "\(store.snapshot.papers.flatMap(\.attachments).count)")
                LatticeDivider()
                LatticeSettingsRow("文库文件") {
                    Text(store.persistenceURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        LatticeSettingsRow(title) {
            Text(value)
                .fontWeight(.semibold)
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

private enum SettingsPane: String, CaseIterable, Identifiable {
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
