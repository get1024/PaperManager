import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PaperDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: Set<UUID>
    @State private var draft = Paper()
    @State private var loadedID: UUID?
    @State private var isLoadingDraft = false

    private var selectedID: UUID? {
        selection.count == 1 ? selection.first : nil
    }

    var body: some View {
        Group {
            if selection.isEmpty {
                LatticeEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "选择文献",
                    message: "文献元数据将在此处显示。"
                )
            } else if selection.count > 1 {
                LatticeEmptyState(
                    systemImage: "checklist",
                    title: "已选择多篇文献",
                    message: "当前选择了 \(selection.count) 篇文献。可从右上角导出或删除。"
                )
            } else if selectedID != nil {
                PaperEditorView(paper: $draft)
                    .onAppear { loadDraftIfNeeded() }
                    .onChange(of: selectedID) { _, _ in loadDraftIfNeeded(force: true) }
                    .onChange(of: draft) { _, newValue in
                        guard !isLoadingDraft else { return }
                        store.updatePaper(newValue)
                    }
            }
        }
        .background(LatticeStyle.contentBackground)
    }

    private func loadDraftIfNeeded(force: Bool = false) {
        guard let id = selectedID, (force || loadedID != id), let paper = store.paper(with: id) else { return }
        isLoadingDraft = true
        draft = paper
        loadedID = id
        DispatchQueue.main.async {
            isLoadingDraft = false
        }
    }
}

private struct PaperEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var paper: Paper
    @State private var showMoreFields = false
    @State private var showExportPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                LatticeSection("基础信息") {
                    LatticeEditableRow("标题") {
                        TextField("标题", text: $paper.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                    }
                    LatticeDivider()
                    LatticeEditableRow("作者") {
                        TextField("作者以分号分隔", text: Binding(
                            get: { paper.authorsText },
                            set: { paper.authorsText = $0 }
                        ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                    }
                    LatticeDivider()
                    LatticeEditableRow("年份") {
                        TextField("年份", text: Binding(
                            get: { paper.year.map(String.init) ?? "" },
                            set: { paper.year = Int($0.trimmed) }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                    LatticeDivider()
                    LatticeEditableRow("类型") {
                        Picker("", selection: $paper.paperType) {
                            ForEach(PaperType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    LatticeDivider()
                    LatticeEditableRow("Citekey") {
                        TextField("citekey", text: $paper.citekey)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                }

                LatticeSection("来源") {
                    detailField("期刊", text: $paper.journal)
                    LatticeDivider()
                    detailField("书名/会议", text: $paper.bookTitle)
                    LatticeDivider()
                    detailField("出版社", text: $paper.publisher)
                    LatticeDivider()
                    detailField("卷", text: $paper.volume)
                    LatticeDivider()
                    detailField("期", text: $paper.issue)
                    LatticeDivider()
                    detailField("页码", text: $paper.pages)
                    LatticeDivider()
                    detailField("DOI", text: $paper.doi)
                    LatticeDivider()
                    detailField("ISBN", text: $paper.isbn)
                    LatticeDivider()
                    detailField("URL", text: $paper.url)
                }

                organizationSection
                attachmentSection
                annotationSection
                textSection
                moreFieldsSection
                exportPreviewSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(paper.hasPDF ? Color.accentColor : Color.secondary)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 5) {
                    Text(paper.displayTitle)
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(3)
                    Text(paper.authorsDisplay)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack {
                StarRatingView(rating: $paper.rating)
                Spacer()
                if paper.primaryPDF != nil {
                    Button {
                        openPrimaryPDF()
                    } label: {
                        Label("打开 PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        revealPrimaryPDF()
                    } label: {
                        Label("访达", systemImage: "folder")
                    }
                }
            }
            .font(.caption)
        }
    }

    private var organizationSection: some View {
        LatticeSection("组织") {
            if store.collections.isEmpty && store.tags.isEmpty {
                Text("暂无文集或标签")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ForEach(flattenedCollections) { item in
                    Toggle(isOn: containsBinding(id: item.collection.id, keyPath: \.collectionIDs)) {
                        Label(item.collection.name, systemImage: "folder")
                            .padding(.leading, CGFloat(item.depth * 12))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    LatticeDivider()
                }

                ForEach(store.tags) { tag in
                    Toggle(isOn: containsBinding(id: tag.id, keyPath: \.tagIDs)) {
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.colorHex))
                                .frame(width: 9, height: 9)
                            Text(tag.name)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if tag.id != store.tags.last?.id {
                        LatticeDivider()
                    }
                }
            }
        }
    }

    private var attachmentSection: some View {
        LatticeSection("附件") {
            HStack(spacing: 10) {
                Button {
                    attach(types: [UTType.pdf], kind: AttachmentKind.pdf)
                } label: {
                    Label(paper.hasPDF ? "替换 PDF" : "添加 PDF", systemImage: "doc.badge.plus")
                }

                Button {
                    attach(types: [.data], kind: .file)
                } label: {
                    Label("添加文件", systemImage: "paperclip")
                }
            }
            .padding(14)

            if paper.attachments.isEmpty {
                LatticeDivider()
                Text("尚未关联 PDF 或附件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                LatticeDivider()
                ForEach(paper.attachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "paperclip")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            Text(attachment.filePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(attachment.url)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            paper.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                }
            }
        }
    }

    private var annotationSection: some View {
        LatticeSection("标注") {
            HStack {
                Text("共 \(paper.annotations.count) 条")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refreshAnnotations()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(paper.primaryPDF == nil)
            }
            .font(.callout)
            .padding(14)

            if paper.annotations.isEmpty {
                LatticeDivider()
                Text("从已关联 PDF 中提取高亮、批注和形状标注。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                LatticeDivider()
                ForEach($paper.annotations) { $annotation in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("p. \(annotation.page)")
                                .fontWeight(.semibold)
                            Text(annotation.kind.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(Color(hex: annotation.colorHex))
                                .frame(width: 10, height: 10)
                            Button(role: .destructive) {
                                paper.annotations.removeAll { $0.id == annotation.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("标注内容", text: $annotation.selectedText, axis: .vertical)
                            .textFieldStyle(.plain)
                        TextField("备注", text: $annotation.note, axis: .vertical)
                            .textFieldStyle(.plain)
                    }
                    .padding(14)
                    LatticeDivider()
                }
            }
        }
    }

    private var textSection: some View {
        LatticeSection("摘要与笔记") {
            VStack(alignment: .leading, spacing: 8) {
                Text("摘要")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $paper.abstract)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            }
            .padding(14)

            LatticeDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("笔记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $paper.notes)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            }
            .padding(14)
        }
    }

    private var moreFieldsSection: some View {
        LatticeSection("更多字段") {
            DisclosureGroup("展开 BibTeX / RIS 字段", isExpanded: $showMoreFields) {
                VStack(spacing: 0) {
                    detailField("机构", text: $paper.institution)
                    LatticeDivider()
                    detailField("学校", text: $paper.school)
                    LatticeDivider()
                    detailField("系列", text: $paper.series)
                    LatticeDivider()
                    detailField("版次", text: $paper.edition)
                    LatticeDivider()
                    detailField("章节", text: $paper.chapter)
                    LatticeDivider()
                    detailField("事件", text: $paper.event)
                    LatticeDivider()
                    detailField("事件日期", text: $paper.eventDate)
                    LatticeDivider()
                    detailField("地点", text: $paper.venue)
                    LatticeDivider()
                    detailField("语言", text: $paper.language)
                    LatticeDivider()
                    detailField("Eprint", text: $paper.eprint)
                    LatticeDivider()
                    detailField("Eprint Type", text: $paper.eprintType)
                    LatticeDivider()
                    detailField("Eprint Class", text: $paper.eprintClass)
                    LatticeDivider()
                    detailField("出版状态", text: $paper.publicationState)
                    LatticeDivider()
                    detailField("How Published", text: $paper.howPublished)

                    LatticeDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("自定义字段")
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            Button {
                                paper.customFields.append(CustomField(key: "", value: ""))
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach($paper.customFields) { $field in
                            HStack {
                                TextField("Key", text: $field.key)
                                    .textFieldStyle(.plain)
                                TextField("Value", text: $field.value)
                                    .textFieldStyle(.plain)
                                Toggle("置顶", isOn: $field.pinned)
                                    .labelsHidden()
                                Button(role: .destructive) {
                                    paper.customFields.removeAll { $0.id == field.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .padding(14)
        }
    }

    private var exportPreviewSection: some View {
        LatticeSection("输出预览") {
            DisclosureGroup("Markdown 元数据", isExpanded: $showExportPreview) {
                ScrollView(.horizontal) {
                    Text(TemplateRenderer.renderMetadata(paper: paper, snapshot: store.snapshot))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding(14)
        }
    }

    private func detailField(_ title: String, text: Binding<String>) -> some View {
        LatticeEditableRow(title) {
            TextField(title, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .lineLimit(1...3)
        }
    }

    private var flattenedCollections: [DetailCollectionRow] {
        flatten(parentID: nil, depth: 0)
    }

    private func flatten(parentID: UUID?, depth: Int) -> [DetailCollectionRow] {
        store.collections.children(of: parentID).flatMap { collection -> [DetailCollectionRow] in
            [DetailCollectionRow(collection: collection, depth: depth)] + flatten(parentID: collection.id, depth: depth + 1)
        }
    }

    private func containsBinding(id: UUID, keyPath: WritableKeyPath<Paper, [UUID]>) -> Binding<Bool> {
        Binding {
            paper[keyPath: keyPath].contains(id)
        } set: { isOn in
            if isOn {
                if !paper[keyPath: keyPath].contains(id) {
                    paper[keyPath: keyPath].append(id)
                }
            } else {
                paper[keyPath: keyPath].removeAll { $0 == id }
            }
        }
    }

    private func attach(types: [UTType], kind: AttachmentKind) {
        guard let url = DialogService.chooseFiles(title: "选择要关联的文件", types: types, multiple: false).first else { return }
        do {
            try store.attachFile(url, to: paper.id, kind: kind)
            if let updated = store.paper(with: paper.id) {
                paper = updated
            }
        } catch {
            store.statusMessage = "无法关联 \(url.lastPathComponent)：\(error.localizedDescription)"
        }
    }

    private func refreshAnnotations() {
        guard let pdf = paper.primaryPDF, let document = PDFDocument(url: pdf.url) else { return }
        paper.annotations = PDFMetadataExtractor.extractAnnotations(from: document)
    }

    private func openPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        if let readerPath = store.settings.defaultPDFReaderPath.nilIfBlank {
            let appURL = URL(fileURLWithPath: readerPath)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([pdf.url], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    Task { @MainActor in
                        store.statusMessage = "无法使用所选阅读器打开 PDF：\(error.localizedDescription)"
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(pdf.url)
        }
    }

    private func revealPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pdf.url])
    }
}

private struct LatticeEditableRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .frame(width: 78, alignment: .leading)
            content
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DetailCollectionRow: Identifiable {
    let collection: PaperCollection
    let depth: Int
    var id: UUID { collection.id }
}
