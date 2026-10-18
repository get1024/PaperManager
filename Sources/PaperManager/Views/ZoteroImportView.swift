import AppKit
import SwiftUI

struct ZoteroImportView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceFolder: URL?
    @State private var copyFiles = false
    @State private var includeExternalFiles = false
    @State private var prepared: ZoteroImportResult?
    @State private var operation: Task<Void, Never>?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?

    private var fileLibrary: FileLibraryStatus { FileLibraryService.status(for: store.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("从 Zotero 导入").font(.title2.weight(.semibold))
            if let completionMessage {
                Label(completionMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            } else {
                Text("选择包含 zotero.sqlite 的数据文件夹。文献、文集、标签、笔记和标注会先读取为迁移预览。")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(sourceFolder?.path ?? "尚未选择 Zotero 数据文件夹")
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("选择文件夹…", action: chooseFolder).disabled(isBusy)
                }
                if prepared == nil {
                    Toggle("拷贝 PDF 和附件到文件库", isOn: $copyFiles)
                        .disabled(isBusy || !fileLibrary.isAvailable)
                    if copyFiles {
                        Text("使用当前文件库的整理、布局和重命名规则。源文件会保留；取消预览会移除本批次副本。")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("同时拷贝 Zotero 文件夹外的已链接文件", isOn: $includeExternalFiles)
                            .disabled(isBusy)
                    } else {
                        Text("不导入文件：保留笔记和标注，不访问外部已链接文件。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !fileLibrary.isAvailable {
                        Text("如需拷贝 PDF，请先在“设置 → 通用”授权文件库文件夹。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let prepared {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow { Text("文献"); Text("\(prepared.snapshot.papers.count)")
                            Text("文集"); Text("\(prepared.snapshot.collections.count)") }
                        GridRow { Text("标签"); Text("\(prepared.snapshot.tags.count)")
                            Text("标注"); Text("\(prepared.snapshot.papers.reduce(0) { $0 + $1.annotations.count })") }
                        GridRow { Text("含笔记文献"); Text("\(prepared.snapshot.papers.filter { !$0.notes.isEmpty }.count)")
                            Text("已拷贝附件"); Text("\(prepared.copiedAttachments)") }
                    }
                    if !prepared.warnings.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(prepared.warnings.enumerated()), id: \.offset) { _, warning in
                                    Label(warning, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .font(.callout).textSelection(.enabled)
                        }.frame(maxHeight: 170)
                    }
                    Text("确认后合并到当前文库。已迁移的同一 Zotero 项目会跳过，现有本地记录会保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if isBusy { ProgressView("正在读取 Zotero 文库…").controlSize(.small) }
            HStack {
                Spacer()
                if completionMessage != nil {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { cancelAndDismiss() }.keyboardShortcut(.cancelAction)
                    if prepared != nil {
                        Button("重新选择") { discardPreview(); sourceFolder = nil; errorMessage = nil }.disabled(isBusy)
                        Button("确认导入", action: commit).keyboardShortcut(.defaultAction).disabled(isBusy)
                    } else {
                        Button("读取文库", action: prepare).keyboardShortcut(.defaultAction)
                            .disabled(sourceFolder == nil || isBusy)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isBusy || prepared != nil)
        .onDisappear {
            operation?.cancel()
            discardPreview()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 zotero.sqlite 的 Zotero 数据文件夹。"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        sourceFolder = selected
        errorMessage = nil
    }

    private func prepare() {
        guard let sourceFolder else { return }
        let settings = store.settings
        let shouldCopy = copyFiles
        let allowExternal = includeExternalFiles
        isBusy = true
        errorMessage = nil
        operation = Task { @MainActor in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    if shouldCopy {
                        return try FileLibraryService.withRoot(settings: settings) { root in
                            guard !FileLibraryService.isWithin(root, root: sourceFolder) else {
                                throw PaperManagerError.message("文件库位于 Zotero 数据文件夹内。请更换文件库，或选择不导入文件。")
                            }
                            let owned = root.appendingPathComponent("ZoteroImport-\(UUID().uuidString)", isDirectory: true)
                            return try ZoteroImportService.prepare(from: sourceFolder,
                                attachmentMode: .copy(to: owned, includeExternalLinkedFiles: allowExternal), settings: settings)
                        }
                    }
                    return try ZoteroImportService.prepare(from: sourceFolder, settings: settings)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                if Task.isCancelled {
                    try ZoteroImportService.cleanupPreparedFiles(result, keepingReferencedBy: store.snapshot)
                } else { prepared = result }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isBusy = false
            operation = nil
        }
    }

    private func commit() {
        guard let prepared else { return }
        do {
            let imported = try ZoteroImportService.persist(prepared, into: store)
            try ZoteroImportService.cleanupPreparedFiles(prepared, keepingReferencedBy: store.snapshot)
            // Ownership transfers to the library. onDisappear must not remove it.
            self.prepared = nil
            completionMessage = "已导入 \(imported) 篇文献，跳过已有 \(prepared.snapshot.papers.count - imported) 篇。"
        } catch { errorMessage = error.localizedDescription }
    }

    private func discardPreview() {
        if let prepared { try? ZoteroImportService.cleanupPreparedFiles(prepared, keepingReferencedBy: store.snapshot) }
        prepared = nil
    }

    private func cancelAndDismiss() {
        operation?.cancel()
        discardPreview()
        dismiss()
    }
}
