import SwiftUI

struct ManualPaperSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?
    var onOpenExisting: (UUID) -> Void = { _ in }

    @State private var draft = Paper()
    @State private var importPlan: ImportPlan?
    @State private var errorMessage: String?

    var body: some View {
        if let importPlan {
            ImportPreviewView(plan: importPlan, targetFilter: targetFilter, onOpenExisting: onOpenExisting)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                AddPaperSheetHeading(title: "手动添加", fontSize: 13)
                VStack(alignment: .leading, spacing: 0) {
                    Text("类型").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(height: 15, alignment: .topLeading)
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                        Menu {
                            Picker("类型", selection: $draft.paperType) {
                                ForEach(PaperType.allCases) { type in Text(type.label).tag(type) }
                            }
                        } label: { Text(draft.paperType.label).font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .offset(x: -1, y: -1)
                        .accessibilityIdentifier("manual-paper-type")
                    }
                    .frame(height: 22, alignment: .leading)
                }
                .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 12) {
                    AddPaperLabeledField(title: "标题", placeholder: "文献标题（必填）", text: $draft.title, identifier: "manual-paper-title")
                    AddPaperLabeledField(title: "作者", placeholder: "使用分号分隔", text: Binding(
                        get: { draft.authorsText }, set: { draft.authorsText = $0 }
                    ), identifier: "manual-paper-authors")
                    AddPaperLabeledField(title: "来源", placeholder: "期刊", text: $draft.journal, identifier: "manual-paper-source")
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("添加", action: addPaper)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.title.trimmed.isEmpty)
                        .accessibilityIdentifier("manual-paper-confirm")
                }
                .controlSize(.regular)
                .frame(height: 24)
                .padding(.top, 16)
            }
            .padding(16)
            .frame(width: 450)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addPaper() {
        guard !draft.title.trimmed.isEmpty else { return }
        if store.duplicatePaperID(for: draft) != nil {
            importPlan = ImportService.prepare(papers: [draft], store: store)
        } else {
            do {
                _ = try store.addPaperDurably(draft, targetFilter: targetFilter)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Lookup is a read-only stage. A query edit or dismissal invalidates late
/// provider responses, including providers that do not honor task cancellation.
@MainActor
final class IdentifierLookupSession: ObservableObject {
    typealias Provider = (String) async throws -> Paper
    @Published var query = "" {
        didSet { if query != oldValue { cancel(); paper = nil; errorMessage = nil } }
    }
    @Published private(set) var paper: Paper?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let provider: Provider
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(provider: @escaping Provider = { try await ImportService.lookupPaper($0) }) {
        self.provider = provider
    }

    func lookup() {
        let query = query.trimmed
        guard !query.isEmpty, !isLoading else { return }
        generation &+= 1
        let generation = generation
        let provider = provider
        paper = nil; errorMessage = nil; isLoading = true
        task = Task { @MainActor [weak self] in
            do {
                let paper = try await provider(query)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.paper = paper
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil; isLoading = false
    }

    deinit { task?.cancel() }
}

struct DOISheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?
    var onOpenExisting: (UUID) -> Void = { _ in }
    @StateObject private var lookup: IdentifierLookupSession
    @State private var importPlan: ImportPlan?
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?

    @MainActor
    init(targetFilter: LibraryFilter?, onOpenExisting: @escaping (UUID) -> Void = { _ in },
         lookupSession: IdentifierLookupSession? = nil) {
        self.targetFilter = targetFilter
        self.onOpenExisting = onOpenExisting
        _lookup = StateObject(wrappedValue: lookupSession ?? IdentifierLookupSession())
    }

    var body: some View {
        Group {
            if let importPlan {
                ImportPreviewView(plan: importPlan, targetFilter: targetFilter, onOpenExisting: onOpenExisting)
            } else { lookupForm }
        }
        .interactiveDismissDisabled(isImporting)
        .onChange(of: lookup.query) { _, _ in importError = nil }
        .onDisappear { lookup.cancel(); importTask?.cancel() }
    }

    private var lookupForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            AddPaperSheetHeading(title: "通过 DOI 导入", fontSize: 13)
            HStack(spacing: 8) {
                AddPaperInputField(placeholder: "输入 DOI（例如 10.1000/xyz123）", text: $lookup.query,
                                   identifier: "identifier-query", onSubmit: {
                    if lookup.paper == nil { lookup.lookup() } else { importPaper() }
                })
                    .help(PMLocalization.text("也支持 arXiv ID、ISBN 或标题"))
                Button {
                    importError = nil
                    lookup.lookup()
                } label: {
                    if lookup.isLoading { ProgressView().controlSize(.small).frame(width: 24) }
                    else { Text("查找") }
                }
                .controlSize(.regular)
                .frame(width: 50, height: 24)
                .disabled(lookup.query.trimmed.isEmpty || lookup.isLoading || isImporting)
                .accessibilityIdentifier("identifier-lookup")
            }
            .disabled(isImporting)
            if let paper = lookup.paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(paper.importAuthorsSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text([paper.sourceDisplay, paper.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 16)
                .accessibilityIdentifier("identifier-preview")
            }
            if let error = importError ?? lookup.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { lookup.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入", action: importPaper)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lookup.paper == nil || lookup.isLoading || isImporting)
                    .accessibilityIdentifier("identifier-import")
            }
            .controlSize(.regular)
            .frame(height: 24)
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func importPaper() {
        guard let paper = lookup.paper, !isImporting, !lookup.isLoading else { return }
        let plan = ImportService.prepare(papers: [paper], store: store)
        if plan.candidates.contains(where: { $0.duplicateID != nil }) {
            importPlan = plan
            return
        }
        importError = nil
        isImporting = true
        importTask = Task { @MainActor in
            let summary = await ImportService.commit(plan, into: store, targetFilter: targetFilter)
            guard !Task.isCancelled else { return }
            isImporting = false
            if summary.failed > 0 { importError = summary.messages.isEmpty ? summary.text : summary.messages.joined(separator: "\n") }
            else if summary.imported + summary.replaced == 0, store.duplicatePaperID(for: paper) != nil {
                importPlan = ImportService.prepare(papers: [paper], store: store)
            } else { dismiss() }
        }
    }
}

private struct AddPaperSheetHeading: View {
    let title: String
    var fontSize: CGFloat = 14
    var body: some View {
        Text(PMLocalization.text(title))
            .font(.system(size: fontSize, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
    }
}

private struct AddPaperLabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PMLocalization.text(title)).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(height: 15, alignment: .topLeading)
                .offset(y: -2)
            AddPaperInputField(placeholder: placeholder, text: $text, identifier: identifier)
        }
    }
}

private struct AddPaperInputField: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    var onSubmit: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        input
            .focused($isFocused)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder private var input: some View {
        if let onSubmit { field.onSubmit(onSubmit) }
        else { field }
    }

    private var field: some View {
        TextField(PMLocalization.text(placeholder), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .accessibilityIdentifier(identifier)
    }
}
