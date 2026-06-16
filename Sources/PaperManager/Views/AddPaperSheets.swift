import SwiftUI

struct ManualPaperSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?

    @State private var draft = Paper()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("手动添加文献")
                .font(.title2)
                .fontWeight(.bold)

            LatticeSection("元数据") {
                LatticeSettingsRow("标题") {
                    TextField("必填", text: $draft.title)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                }
                LatticeDivider()
                LatticeSettingsRow("作者", subtitle: "多个作者用分号分隔") {
                    TextField("Einstein, Albert", text: Binding(
                        get: { draft.authorsText },
                        set: { draft.authorsText = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .frame(width: 280)
                }
                LatticeDivider()
                LatticeSettingsRow("年份") {
                    TextField("1905", text: Binding(
                        get: { draft.year.map(String.init) ?? "" },
                        set: { draft.year = Int($0.trimmed) }
                    ))
                    .textFieldStyle(.plain)
                    .frame(width: 120)
                }
                LatticeDivider()
                LatticeSettingsRow("类型") {
                    Picker("", selection: $draft.paperType) {
                        ForEach(PaperType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                LatticeDivider()
                LatticeSettingsRow("来源") {
                    TextField("期刊、会议或出版社", text: $draft.journal)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                }
                LatticeDivider()
                LatticeSettingsRow("DOI") {
                    TextField("10.1000/xyz123", text: $draft.doi)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                }
                LatticeDivider()
                LatticeSettingsRow("URL") {
                    TextField("https://", text: $draft.url)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                }
            }

            LatticeSection("摘要") {
                TextEditor(text: $draft.abstract)
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .padding(10)
            }

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
        .padding(22)
        .frame(width: 560)
        .background(LatticeStyle.contentBackground)
    }
}

struct DOISheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let targetFilter: LibraryFilter?

    @State private var doi = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通过 DOI 添加")
                .font(.title2)
                .fontWeight(.bold)

            LatticeSection("Crossref 元数据") {
                LatticeSettingsRow("DOI", subtitle: "PaperManager 会拉取标题、作者、来源和年份。") {
                    TextField("10.1000/xyz123", text: $doi)
                        .textFieldStyle(.plain)
                        .frame(width: 260)
                        .onSubmit { add() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(isLoading ? "正在获取" : "添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(doi.trimmed.isEmpty || isLoading)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(LatticeStyle.contentBackground)
    }

    private func add() {
        guard !doi.trimmed.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await ImportService.addViaDOI(doi, into: store, targetFilter: targetFilter)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
