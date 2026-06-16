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
                PaperManagerEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "选择文献",
                    message: "文献元数据将在此处显示。"
                )
            } else if selection.count > 1 {
                PaperManagerEmptyState(
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
        .navigationTitle("详情")
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
        Form {
            Section {
                header
            }

            Section("基础信息") {
                field("标题", text: $paper.title, axis: .vertical)
                    .lineLimit(1...3)
                optionalField("副标题", text: $paper.subtitle, axis: .vertical)
                    .lineLimit(1...2)
                field("作者", text: Binding(
                    get: { paper.authorsText },
                    set: { paper.authorsText = $0 }
                ), axis: .vertical)
                .lineLimit(1...3)
                field("编辑", text: Binding(
                    get: { paper.editorsText },
                    set: { paper.editorsText = $0 }
                ), axis: .vertical)
                .lineLimit(1...2)
                field("译者", text: Binding(
                    get: { paper.translatorsText },
                    set: { paper.translatorsText = $0 }
                ), axis: .vertical)
                .lineLimit(1...2)
                LabeledContent("年份") {
                    TextField("年份", text: Binding(
                        get: { paper.year.map(String.init) ?? "" },
                        set: { paper.year = Int($0.trimmed) }
                    ))
                    .multilineTextAlignment(.trailing)
                }
                Picker("类型", selection: $paper.paperType) {
                    ForEach(PaperType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                field("Citekey", text: $paper.citekey)
            }

            Section("来源") {
                field("期刊", text: $paper.journal)
                field("书名/会议", text: $paper.bookTitle)
                field("出版社", text: $paper.publisher)
                field("卷", text: $paper.volume)
                field("期", text: $paper.issue)
                field("页码", text: $paper.pages)
                field("DOI", text: $paper.doi)
                field("ISBN", text: $paper.isbn)
                field("URL", text: $paper.url)
                optionalField("访问日期", text: $paper.urlDate)
            }

            organizationSection
            attachmentSection
            annotationSection
            textSection
            moreFieldsSection
            exportPreviewSection
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.displayTitle)
                        .lineLimit(3)
                    Text(paper.authorsDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
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
        }
    }

    private var organizationSection: some View {
        Section("组织") {
            if store.collections.isEmpty && store.tags.isEmpty {
                Text("暂无文集或标签")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(flattenedCollections) { item in
                    Toggle(isOn: containsBinding(id: item.collection.id, keyPath: \.collectionIDs)) {
                        Label(item.collection.name, systemImage: "folder")
                            .padding(.leading, CGFloat(item.depth * 12))
                    }
                }

                ForEach(store.tags) { tag in
                    Toggle(isOn: containsBinding(id: tag.id, keyPath: \.tagIDs)) {
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.colorHex))
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                        }
                    }
                }
            }
        }
    }

    private var attachmentSection: some View {
        Section("附件") {
            HStack {
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

            if paper.attachments.isEmpty {
                Text("尚未关联 PDF 或附件。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(paper.attachments) { attachment in
                    HStack {
                        Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "paperclip")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(attachment.displayName)
                                .lineLimit(1)
                            Text(attachment.filePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            openAttachment(attachment)
                        } label: {
                            Label("打开", systemImage: "arrow.up.right")
                        }
                        Button(role: .destructive) {
                            paper.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var annotationSection: some View {
        Section("标注") {
            LabeledContent("数量") {
                Text("\(paper.annotations.count) 条")
                    .foregroundStyle(.secondary)
            }

            Button {
                refreshAnnotations()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(paper.primaryPDF == nil)

            if paper.annotations.isEmpty {
                Text("从已关联 PDF 中提取高亮、批注和形状标注。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($paper.annotations) { $annotation in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("p. \(annotation.page)")
                            Text(annotation.kind.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(Color(hex: annotation.colorHex))
                                .frame(width: 8, height: 8)
                            Button(role: .destructive) {
                                paper.annotations.removeAll { $0.id == annotation.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        TextField("标注内容", text: $annotation.selectedText, axis: .vertical)
                        TextField("备注", text: $annotation.note, axis: .vertical)
                    }
                }
            }
        }
    }

    private var textSection: some View {
        Section("摘要与笔记") {
            VStack(alignment: .leading) {
                Text("摘要")
                TextEditor(text: $paper.abstract)
                    .frame(minHeight: 80)
            }

            VStack(alignment: .leading) {
                Text("笔记")
                TextEditor(text: $paper.notes)
                    .frame(minHeight: 80)
            }
        }
    }

    private var moreFieldsSection: some View {
        Section("更多字段") {
            DisclosureGroup("展开 BibTeX / RIS 字段", isExpanded: $showMoreFields) {
                field("机构", text: $paper.institution)
                field("学校", text: $paper.school)
                optionalField("地址", text: $paper.address)
                field("系列", text: $paper.series)
                field("版次", text: $paper.edition)
                field("章节", text: $paper.chapter)
                optionalField("类型", text: $paper.type)
                optionalField("组织", text: $paper.organization)
                field("事件", text: $paper.event)
                field("事件日期", text: $paper.eventDate)
                field("地点", text: $paper.venue)
                field("语言", text: $paper.language)
                field("Eprint", text: $paper.eprint)
                field("Eprint Type", text: $paper.eprintType)
                field("Eprint Class", text: $paper.eprintClass)
                field("出版状态", text: $paper.publicationState)
                field("How Published", text: $paper.howPublished)

                LabeledContent("自定义字段") {
                    Button {
                        paper.customFields.append(CustomField(key: "", value: ""))
                    } label: {
                        Label("添加字段", systemImage: "plus")
                    }
                }

                ForEach($paper.customFields) { $field in
                    HStack {
                        TextField("Key", text: $field.key)
                        TextField("Value", text: $field.value)
                        Toggle("置顶", isOn: $field.pinned)
                        Button(role: .destructive) {
                            paper.customFields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
            }
        }
    }

    private var exportPreviewSection: some View {
        Section("输出预览") {
            DisclosureGroup("Markdown 元数据", isExpanded: $showExportPreview) {
                ScrollView(.horizontal) {
                    Text(TemplateRenderer.renderMetadata(paper: paper, snapshot: store.snapshot))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, axis: axis)
        }
    }

    private func optionalField(_ title: String, text: Binding<String?>, axis: Axis = .horizontal) -> some View {
        field(title, text: Binding(
            get: { text.wrappedValue ?? "" },
            set: { text.wrappedValue = $0.nilIfBlank }
        ), axis: axis)
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
        guard let pdf = paper.primaryPDF else { return }
        do {
            paper.annotations = try pdf.withResolvedURL { url in
                guard let document = PDFDocument(url: url) else {
                    throw PaperManagerError.message("PDFKit 无法读取这个 PDF。")
                }
                return PDFMetadataExtractor.extractAnnotations(from: document)
            }
        } catch {
            store.statusMessage = "标注提取失败：\(error.localizedDescription)"
        }
    }

    private func openPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        do {
            try pdf.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message("PDF 文件不存在，可能已在 Finder 中移动或删除。")
                }
                if let readerPath = store.settings.defaultPDFReaderPath.nilIfBlank {
                    let appURL = URL(fileURLWithPath: readerPath)
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                        if let error {
                            Task { @MainActor in
                                store.statusMessage = "无法使用所选阅读器打开 PDF：\(error.localizedDescription)"
                            }
                        }
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        } catch {
            store.statusMessage = "无法打开 PDF：\(error.localizedDescription)"
        }
    }

    private func revealPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        do {
            try pdf.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message("PDF 文件不存在，可能已在 Finder 中移动或删除。")
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            store.statusMessage = "无法在 Finder 中显示 PDF：\(error.localizedDescription)"
        }
    }

    private func openAttachment(_ attachment: Attachment) {
        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message("文件不存在，可能已在 Finder 中移动或删除。")
                }
                NSWorkspace.shared.open(url)
            }
        } catch {
            store.statusMessage = "无法打开附件：\(error.localizedDescription)"
        }
    }
}

private struct DetailCollectionRow: Identifiable {
    let collection: PaperCollection
    let depth: Int
    var id: UUID { collection.id }
}
