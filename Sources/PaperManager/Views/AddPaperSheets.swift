import SwiftUI

struct ManualPaperSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?

    @State private var draft = Paper()

    var body: some View {
        Form {
            Section("元数据") {
                TextField("标题", text: $draft.title)
                TextField("副标题", text: Binding(
                    get: { draft.subtitle ?? "" },
                    set: { draft.subtitle = $0.nilIfBlank }
                ))
                TextField("作者", text: Binding(
                    get: { draft.authorsText },
                    set: { draft.authorsText = $0 }
                ))
                TextField("编辑", text: Binding(
                    get: { draft.editorsText },
                    set: { draft.editorsText = $0 }
                ))
                TextField("年份", text: Binding(
                    get: { draft.year.map(String.init) ?? "" },
                    set: { draft.year = Int($0.trimmed) }
                ))
                Picker("类型", selection: $draft.paperType) {
                    ForEach(PaperType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                TextField("来源", text: $draft.journal)
                TextField("书名/会议", text: $draft.bookTitle)
                TextField("DOI", text: $draft.doi)
                TextField("ISBN", text: $draft.isbn)
                TextField("URL", text: $draft.url)
            }

            Section("摘要") {
                TextEditor(text: $draft.abstract)
                    .frame(height: 100)
            }

            Section {
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("添加") {
                        store.addPaper(draft, targetFilter: targetFilter)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmed.isEmpty)
                }
            }
        }
        .navigationTitle("手动添加文献")
        .padding()
        .frame(width: 560)
    }
}

struct DOISheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?

    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("元数据查找") {
                TextField("DOI、arXiv ID、ISBN 或标题", text: $query)
                    .onSubmit { add() }
                Text("PaperManager 会从 Crossref、arXiv 或 OpenLibrary 拉取标题、作者、来源和年份。")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button(isLoading ? "正在获取" : "添加") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.trimmed.isEmpty || isLoading)
                }
            }
        }
        .navigationTitle("通过标识符添加")
        .padding()
        .frame(width: 480)
    }

    private func add() {
        guard !query.trimmed.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await ImportService.addViaLookup(query, into: store, targetFilter: targetFilter)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
