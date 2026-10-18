import AppKit
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var plan: ImportPlan
    let targetFilter: LibraryFilter?
    var onOpenExisting: (UUID) -> Void = { _ in }
    @State private var duplicateAction: ImportDuplicateAction = .skip
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var result: ImportSummary?
    @State private var preparationError: String?

    private var selectedCount: Int { plan.candidates.filter(\.isSelected).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入预览").font(.title2.bold())
                    Text("已选择 \(selectedCount) / \(plan.candidates.count) 篇文献")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isImporting { ProgressView().controlSize(.small) }
                Button(PMLocalization.text(selectedCount == plan.candidates.count ? "取消全选" : "全选")) {
                    let select = selectedCount != plan.candidates.count
                    for index in plan.candidates.indices { plan.candidates[index].isSelected = select }
                }
                .disabled(isImporting || result != nil)
            }

            HStack {
                Picker("遇到重复", selection: $duplicateAction) {
                    ForEach(ImportDuplicateAction.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 235)
                Button("应用到全部") {
                    for index in plan.candidates.indices { plan.candidates[index].duplicateAction = duplicateAction }
                }
                Text("替换保留已有评分、备注、附件和标注。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(isImporting || result != nil)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($plan.candidates) { $candidate in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("选择 \(candidate.paper.displayTitle)", isOn: $candidate.isSelected)
                                .labelsHidden().padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.paper.displayTitle).font(.headline).textSelection(.enabled)
                                Text([candidate.paper.authorsDisplay, candidate.paper.year.map(String.init) ?? "", candidate.paper.sourceDisplay]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let source = candidate.sourceURL {
                                    Label(source.lastPathComponent, systemImage: "doc.richtext")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let id = candidate.duplicateID {
                                    HStack {
                                        Label("文库中已存在", systemImage: "doc.on.doc")
                                            .foregroundStyle(.orange)
                                        Picker("重复处理", selection: $candidate.duplicateAction) {
                                            ForEach(ImportDuplicateAction.allCases) { Text($0.label).tag($0) }
                                        }.labelsHidden().frame(width: 160)
                                        Button("打开已有") { dismiss(); onOpenExisting(id) }
                                    }.font(.caption)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        Divider()
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .disabled(isImporting || result != nil)

            if !plan.failures.isEmpty {
                DisclosureGroup("\(plan.failures.count) 个文件无法导入") {
                    ScrollView {
                        Text(plan.failures.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 80)
                }
            }
            if let result {
                Text(result.text).foregroundStyle(result.failed == 0 ? Color.secondary : Color.red)
                if !result.messages.isEmpty {
                    ScrollView { Text(result.messages.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                        .frame(maxHeight: 75)
                }
            }
            if let preparationError { Text(preparationError).font(.caption).foregroundStyle(.red) }

            HStack {
                Text(isImporting ? (store.statusMessage ?? PMLocalization.text("正在导入…")) : PMLocalization.text("确认导入前，文库和文件不会改变。"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(PMLocalization.text(result == nil ? (isImporting ? "停止导入" : "取消") : "完成")) {
                    if isImporting { importTask?.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                if result == nil {
                    Button(PMLocalization.text(isImporting ? "正在导入…" : "导入选中项")) { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCount == 0 || isImporting)
                        .accessibilityIdentifier("import-preview-confirm")
                }
            }
        }
        .padding(22)
        .frame(width: 740, height: 570)
        .interactiveDismissDisabled(isImporting)
        .onDisappear { importTask?.cancel() }
    }

    private func startImport() {
        guard !isImporting else { return }
        preparationError = nil
        if plan.candidates.contains(where: { $0.isSelected && $0.sourceURL != nil }),
           FileLibraryService.status(for: store.settings).availability == .notAsked {
            let alert = NSAlert()
            alert.messageText = PMLocalization.text("将导入的文件保存在哪里？")
            alert.informativeText = PMLocalization.text("设置文件库可将新文件复制到统一位置，也可以保留文件原位置。")
            alert.addButton(withTitle: PMLocalization.text("设置文件库…"))
            alert.addButton(withTitle: PMLocalization.text("保留原位置"))
            alert.addButton(withTitle: PMLocalization.text("取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let folder = DialogService.chooseFolder(title: PMLocalization.text("选择文件库文件夹")) else { return }
                do {
                    let preferences = try FileLibraryService.authorizedPreferences(root: folder)
                    var settings = store.settings
                    settings.fileLibrary = preferences
                    settings.pdfOrganizationFolder = folder.path
                    settings.browserUploadFolder = folder.path
                    settings.pdfOrganizationMode = .copy
                    store.updateSettings(settings)
                } catch { preparationError = error.localizedDescription; return }
            case .alertSecondButtonReturn:
                var settings = store.settings
                settings.fileLibrary = FileLibraryPreferences(decision: .declined)
                settings.pdfOrganizationMode = .none
                store.updateSettings(settings)
            default: return
            }
        }
        isImporting = true
        importTask = Task { @MainActor in
            let summary = await ImportService.commit(plan, into: store, targetFilter: targetFilter)
            isImporting = false
            result = summary
            if summary.failed == 0 && summary.messages.isEmpty { dismiss() }
        }
    }
}
