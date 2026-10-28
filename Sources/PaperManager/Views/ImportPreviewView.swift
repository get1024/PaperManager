import AppKit
import SwiftUI

extension Paper {
    var importAuthorsSummary: String {
        guard let first = authors.first else { return "" }
        if authors.count == 1 { return first }
        if authors.count == 2 { return "\(first) & \(authors[1])" }
        return "\(first) et al."
    }
}

struct ImportPreviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var plan: ImportPlan
    let targetFilter: LibraryFilter?
    var onOpenExisting: (UUID) -> Void = { _ in }
    var sourceKind: String? = nil
    @State private var duplicateAction: ImportDuplicateAction = .skip
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var result: ImportSummary?
    @State private var preparationError: String?
    @State private var showDuplicateOptions = true

    private var selectedCount: Int { plan.candidates.filter(\.isSelected).count }

    private var importTitle: String {
        let kind = sourceKind ?? (plan.candidates.allSatisfy { $0.sourceURL?.isPDF == true } && !plan.candidates.isEmpty ? "PDF" : nil)
        if let kind { return PMLocalization.format("导入 %@（%lld 条）", kind, plan.candidates.count) }
        return PMLocalization.format("导入文献（%lld 条）", plan.candidates.count)
    }

    private var duplicateCount: Int { plan.candidates.filter(\.hasDuplicate).count }

    var body: some View {
        VStack(spacing: 0) {
            Text(importTitle).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .overlay(alignment: .trailing) {
                    if isImporting { ProgressView().controlSize(.small).padding(.trailing, 16) }
                }
            Divider()
            List {
                ForEach($plan.candidates) { $candidate in
                    HStack(alignment: .top, spacing: 6) {
                        Toggle("选择", isOn: $candidate.isSelected)
                            .labelsHidden().toggleStyle(.checkbox)
                            .frame(width: 15).padding(.top, 1)
                            .accessibilityLabel([candidate.paper.displayTitle, candidate.paper.importAuthorsSummary].filter { !$0.isEmpty }.joined(separator: "、"))
                            .accessibilityIdentifier("import-candidate-select-\(candidate.id)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.paper.displayTitle).font(.system(size: 13)).lineLimit(1)
                            if !candidate.paper.importAuthorsSummary.isEmpty {
                                Text(candidate.paper.importAuthorsSummary).font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            if candidate.hasDuplicate {
                                Text(PMLocalization.text(candidate.duplicateID != nil ? "文库中已存在" : "本批次重复"))
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 40)
            .scrollContentBackground(.hidden)
            .padding(.top, 9)
            .padding(.trailing, 16)
            .disabled(isImporting || result != nil)
            .contextMenu {
                Button(PMLocalization.text(selectedCount == plan.candidates.count ? "取消全选" : "全选")) { toggleAll() }
                    .disabled(isImporting || result != nil)
            }

            if duplicateCount > 0, result == nil {
                DisclosureGroup("遇到重复", isExpanded: $showDuplicateOptions) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Picker("遇到重复", selection: $duplicateAction) {
                                    ForEach(ImportDuplicateAction.allCases) { Text($0.label).tag($0) }
                                }.labelsHidden().frame(width: 150)
                                Button("应用到全部") {
                                    // A replacement may make a later row a
                                    // duplicate. Carry the chosen batch policy
                                    // into those newly revealed relationships.
                                    for index in plan.candidates.indices {
                                        plan.candidates[index].duplicateAction = duplicateAction
                                    }
                                }.accessibilityIdentifier("import-duplicate-apply-all")
                                Spacer(minLength: 0)
                            }
                            Text("替换保留已有评分、备注、附件和标注。")
                                .foregroundStyle(.secondary)
                            ForEach($plan.candidates) { $candidate in
                                if candidate.hasDuplicate {
                                    HStack(spacing: 8) {
                                        Text(candidate.paper.displayTitle).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Picker("重复处理", selection: $candidate.duplicateAction) {
                                            ForEach(ImportDuplicateAction.allCases) { Text($0.label).tag($0) }
                                        }.labelsHidden().frame(width: 140)
                                        if let id = candidate.duplicateID {
                                            Button("打开已有") { dismiss(); onOpenExisting(id) }
                                        }
                                    }
                                }
                            }
                        }.font(.system(size: 11))
                    }.frame(maxHeight: 110)
                }
                .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 6)
                .disabled(isImporting)
            }
            if !plan.failures.isEmpty {
                DisclosureGroup("\(plan.failures.count) 个文件无法导入") {
                    ScrollView {
                        Text(plan.failures.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 70)
                }
                .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.text).foregroundStyle(result.failed == 0 ? Color.secondary : Color.red)
                    if !result.messages.isEmpty {
                        ScrollView { Text(result.messages.joined(separator: "\n")).textSelection(.enabled) }
                            .frame(maxHeight: 70)
                    }
                }
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let preparationError {
                Text(preparationError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Text(isImporting ? (store.statusMessage ?? PMLocalization.text("正在导入…")) :
                        PMLocalization.format("已选择 %lld / %lld", selectedCount, plan.candidates.count))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button(PMLocalization.text(result == nil ? (isImporting ? "停止导入" : "取消") : "完成")) {
                    if isImporting { importTask?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button(PMLocalization.text(isImporting ? "正在导入…" : "导入"), action: startImport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCount == 0 || isImporting)
                        .accessibilityIdentifier("import-preview-confirm")
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
        .frame(width: 500, height: 400)
        .interactiveDismissDisabled(isImporting)
        .onChange(of: plan.candidates.map(\.isSelected)) { _, _ in refreshDuplicateMatches() }
        .onChange(of: plan.candidates.map(\.duplicateAction)) { _, _ in refreshDuplicateMatches() }
        .onChange(of: store.papers) { _, _ in refreshDuplicateMatches() }
        .onDisappear { importTask?.cancel() }
    }

    private func toggleAll() {
        let select = selectedCount != plan.candidates.count
        for index in plan.candidates.indices { plan.candidates[index].isSelected = select }
    }

    private func refreshDuplicateMatches() {
        guard !isImporting, result == nil else { return }
        ImportService.refreshDuplicateMatches(in: &plan, store: store)
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
                    guard store.updateSettings(settings) else {
                        preparationError = store.statusMessage
                        return
                    }
                } catch { preparationError = error.localizedDescription; return }
            case .alertSecondButtonReturn:
                var settings = store.settings
                settings.fileLibrary = FileLibraryPreferences(decision: .declined)
                settings.pdfOrganizationMode = .none
                guard store.updateSettings(settings) else {
                    preparationError = store.statusMessage
                    return
                }
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
