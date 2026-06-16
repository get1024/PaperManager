import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum InspectorTab {
    case metadata
    case annotations

    var title: String {
        switch self {
        case .metadata: return "元数据"
        case .annotations: return "标注"
        }
    }
}

struct PaperDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: Set<UUID>
    @State private var draft = Paper()
    @State private var loadedID: UUID?
    @State private var isLoadingDraft = false
    @State private var saveTask: Task<Void, Never>?

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
                    .onChange(of: selectedID) { _, _ in
                        saveCurrentDraft()
                        loadDraftIfNeeded(force: true)
                    }
                    .onChange(of: draft) { _, newValue in
                        guard !isLoadingDraft else { return }
                        scheduleSave(newValue)
                    }
                    .onDisappear {
                        saveCurrentDraft()
                    }
            }
        }
        .navigationTitle("详情")
    }

    private func loadDraftIfNeeded(force: Bool = false) {
        guard let id = selectedID, (force || loadedID != id), let paper = store.paper(with: id) else { return }
        saveTask?.cancel()
        isLoadingDraft = true
        draft = paper
        loadedID = id
        DispatchQueue.main.async {
            isLoadingDraft = false
        }
    }

    private func scheduleSave(_ paper: Paper) {
        guard loadedID == paper.id else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                store.updatePaper(paper)
            }
        }
    }

    private func saveCurrentDraft() {
        saveTask?.cancel()
        guard !isLoadingDraft, loadedID == draft.id else { return }
        store.updatePaper(draft)
    }
}

private struct PaperEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var paper: Paper
    @State private var selectedTab: InspectorTab = .metadata
    @State private var showMoreFields = false
    @State private var showExportPreview = false
    @State private var isRefreshingMetadata = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorTabBar
                .padding(.top, 12)

            Divider()

            Group {
                if selectedTab == .metadata {
                    metadataInspector
                } else {
                    annotationInspector
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inspectorTabBar: some View {
        HStack(spacing: 42) {
            ForEach([InspectorTab.metadata, InspectorTab.annotations], id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.title)
                            .font(PMTypography.headline)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(width: 84)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 2)
    }

    private var metadataInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                InspectorSection(title: "引用") {
                    inspectorField("年份", text: Binding(
                        get: { paper.year.map(String.init) ?? "" },
                        set: { paper.year = Int($0.trimmed) }
                    ))
                    inspectorField("来源", text: sourceBinding)
                    inspectorField("标识符", text: identifierBinding)
                    inspectorField("URL", text: $paper.url)
                    inspectorField("页码", text: $paper.pages)

                    DisclosureGroup("更多字段 · \(moreFieldValueCount)", isExpanded: $showMoreFields) {
                        VStack(spacing: 0) {
                            optionalInspectorField("副标题", text: $paper.subtitle, axis: .vertical)
                            inspectorField("编辑", text: Binding(
                                get: { paper.editorsText },
                                set: { paper.editorsText = $0 }
                            ), axis: .vertical)
                            inspectorField("译者", text: Binding(
                                get: { paper.translatorsText },
                                set: { paper.translatorsText = $0 }
                            ), axis: .vertical)
                            inspectorField("出版社", text: $paper.publisher)
                            inspectorField("位置", text: Binding(
                                get: { paper.address ?? "" },
                                set: { paper.address = $0.nilIfBlank }
                            ))
                            optionalInspectorField("组织", text: $paper.organization)
                            inspectorField("会议名称", text: $paper.event)
                            inspectorField("会议日期", text: $paper.eventDate)
                            optionalInspectorField("学位", text: $paper.type)
                            inspectorField("月份", text: $paper.month)
                            inspectorField("语言", text: $paper.language)
                            optionalInspectorField("访问日期", text: $paper.urlDate)
                            inspectorField("电子预印本", text: $paper.eprint)
                            inspectorField("预印本类型", text: $paper.eprintType)
                            inspectorField("预印本分类", text: $paper.eprintClass)
                            inspectorField("出版状态", text: $paper.publicationState)
                        }
                    }
                    .padding(.top, 6)
                }

                InspectorSection(title: "文库") {
                    InspectorValueRow(title: "评分") {
                        HStack(spacing: 8) {
                            StarRatingView(rating: $paper.rating)
                            Text(paper.rating == 0 ? "未评分" : "\(paper.rating) / 5")
                                .foregroundStyle(.secondary)
                        }
                    }
                    InspectorValueRow(title: "文集") {
                        collectionSelector
                    }
                    InspectorValueRow(title: "标签") {
                        tagSelector
                    }
                }

                InspectorSection(title: "附件") {
                    attachmentInspectorRows
                }

                InspectorSection(title: "内容") {
                    DisclosureGroup("摘要", isExpanded: .constant(true)) {
                        PlainInspectorTextEditor(text: $paper.abstract, minHeight: 130)
                    }
                    DisclosureGroup("备注", isExpanded: .constant(true)) {
                        PlainInspectorTextEditor(text: $paper.notes, minHeight: 86)
                    }
                }

                InspectorSection(title: "输出预览") {
                    DisclosureGroup("Markdown 元数据", isExpanded: $showExportPreview) {
                        if showExportPreview {
                            ScrollView(.horizontal) {
                                Text(TemplateRenderer.renderMetadata(paper: paper, snapshot: store.snapshot, includeAnnotations: false))
                                    .font(PMTypography.monospacedCaption)
                                    .textSelection(.enabled)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
    }

    private var annotationInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paperIdentityHeader

                if paper.annotations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂无标注")
                            .font(PMTypography.headline)
                        Text("从已关联 PDF 中提取高亮、批注和形状标注。")
                            .font(PMTypography.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    if paper.annotations.count > 80 {
                        Text("当前仅显示前 80 条标注，导出时仍会包含全部标注。")
                            .font(PMTypography.captionRegular)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(paper.annotations.prefix(80))) { annotation in
                            AnnotationInspectorRow(annotation: annotation)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.visible)
    }

    private var paperIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(paper.displayTitle)
                .font(PMTypography.paperTitle)
                .lineLimit(2...4)
                .textSelection(.enabled)

            if !paper.authorsDisplay.trimmed.isEmpty {
                Text(paper.authorsDisplay)
                    .font(PMTypography.paperCallout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)
                    .textSelection(.enabled)
            }
        }
    }

    private var basicSection: some View {
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
    }

    private var sourceSection: some View {
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("标题", text: $paper.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(PMTypography.paperTitle)
                        .lineLimit(2...4)

                    TextField("作者", text: Binding(
                        get: { paper.authorsText },
                        set: { paper.authorsText = $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PMTypography.paperCallout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)

                    TextField("Citekey", text: $paper.citekey)
                        .textFieldStyle(.plain)
                        .font(PMTypography.paperCaption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                StarRatingView(rating: $paper.rating)
                Spacer()
                if paper.primaryPDF != nil {
                    Button {
                        openPrimaryPDF()
                    } label: {
                        Label("打开", systemImage: "doc.richtext")
                    }
                    .labelStyle(.iconOnly)
                    .help("打开 PDF")
                    Button {
                        revealPrimaryPDF()
                    } label: {
                        Label("访达", systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .help("在 Finder 中显示")
                }
                Button {
                    refreshMetadata()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("刷新元数据")
                .disabled(isRefreshingMetadata || !canRefreshMetadata)
            }
        }
    }

    private var sourceBinding: Binding<String> {
        Binding {
            paper.sourceDisplay
        } set: { value in
            if !paper.bookTitle.trimmed.isEmpty && paper.journal.trimmed.isEmpty {
                paper.bookTitle = value
            } else if !paper.publisher.trimmed.isEmpty && paper.journal.trimmed.isEmpty && paper.bookTitle.trimmed.isEmpty {
                paper.publisher = value
            } else {
                paper.journal = value
            }
        }
    }

    private var identifierBinding: Binding<String> {
        Binding {
            if let doi = paper.doi.nilIfBlank { return doi }
            if let eprint = paper.eprint.nilIfBlank { return eprint }
            return paper.isbn
        } set: { value in
            let clean = value.trimmed
            if clean.looksLikeArxivID {
                paper.eprint = clean
                if paper.eprintType.trimmed.isEmpty {
                    paper.eprintType = "arXiv"
                }
            } else if clean.uppercased().contains("ISBN") {
                paper.isbn = clean.replacingOccurrences(of: "ISBN", with: "", options: .caseInsensitive).trimmed
            } else {
                paper.doi = clean
            }
        }
    }

    private var moreFieldValueCount: Int {
        [
            paper.subtitle ?? "",
            paper.editorsText,
            paper.translatorsText,
            paper.publisher,
            paper.address ?? "",
            paper.organization ?? "",
            paper.event,
            paper.eventDate,
            paper.type ?? "",
            paper.month,
            paper.language,
            paper.urlDate ?? "",
            paper.eprint,
            paper.eprintType,
            paper.eprintClass,
            paper.publicationState
        ].filter { !$0.trimmed.isEmpty }.count
    }

    private var collectionSelector: some View {
        Group {
            if flattenedCollections.isEmpty {
                Text("—")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(flattenedCollections) { item in
                            ToggleChip(
                                title: item.collection.name,
                                systemImage: "folder",
                                isOn: containsBinding(id: item.collection.id, keyPath: \.collectionIDs)
                            )
                        }
                    }
                }
            }
        }
    }

    private var tagSelector: some View {
        Group {
            if store.tags.isEmpty {
                Text("无")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tags) { tag in
                            ToggleChip(
                                title: tag.name,
                                color: Color(hex: tag.colorHex),
                                isOn: containsBinding(id: tag.id, keyPath: \.tagIDs)
                            )
                        }
                    }
                }
            }
        }
    }

    private var attachmentInspectorRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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
                    .font(PMTypography.callout)
            } else {
                ForEach(paper.attachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "paperclip")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.displayName)
                                .lineLimit(1)
                            Text(attachment.filePath)
                                .font(PMTypography.captionRegular)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            openAttachment(attachment)
                        } label: {
                            Label("打开", systemImage: "arrow.up.right")
                        }
                        .labelStyle(.iconOnly)
                        .help("打开附件")
                        Button(role: .destructive) {
                            paper.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .help("移除附件")
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func inspectorField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        InspectorValueRow(title: title) {
            TextField("—", text: text, axis: axis)
                .textFieldStyle(.plain)
                .font(PMTypography.paperCallout)
                .lineLimit(axis == .vertical ? 1...3 : 1...1)
        }
    }

    private func optionalInspectorField(_ title: String, text: Binding<String?>, axis: Axis = .horizontal) -> some View {
        inspectorField(title, text: Binding(
            get: { text.wrappedValue ?? "" },
            set: { text.wrappedValue = $0.nilIfBlank }
        ), axis: axis)
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
                                .font(PMTypography.captionRegular)
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

            Button {
                exportAnnotations()
            } label: {
                Label("导出所有标注", systemImage: "square.and.arrow.up")
            }
            .disabled(paper.annotations.isEmpty)

            if paper.annotations.isEmpty {
                Text("从已关联 PDF 中提取高亮、批注和形状标注。")
                    .foregroundStyle(.secondary)
            } else {
                if paper.annotations.count > 80 {
                    Text("为保持 Inspector 流畅，当前仅显示前 80 条标注。导出时仍会包含全部标注。")
                        .font(PMTypography.captionRegular)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(paper.annotations.prefix(80))) { annotation in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("p. \(annotation.page)")
                            Text(annotation.kind.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(Color(hex: annotation.colorHex))
                                .frame(width: 8, height: 8)
                            Button {
                                ExportService.copyToPasteboard(annotation.copyText)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                        if !annotation.selectedText.trimmed.isEmpty {
                            Text(annotation.selectedText)
                                .textSelection(.enabled)
                        }
                        if !annotation.note.trimmed.isEmpty {
                            Text(annotation.note)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let imageFilePath = annotation.imageFilePath {
                            AnnotationImagePreview(path: imageFilePath)
                        }
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
                if showExportPreview {
                    ScrollView(.horizontal) {
                        Text(TemplateRenderer.renderMetadata(paper: paper, snapshot: store.snapshot, includeAnnotations: false))
                            .font(PMTypography.monospacedCaption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        LabeledContent(title) {
            TextField("—", text: text, axis: axis)
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
        Task {
            do {
                paper.annotations = try await ImportService.extractAnnotations(from: pdf, paperID: paper.id)
                store.statusMessage = "标注已刷新。"
            } catch {
                store.statusMessage = "标注提取失败：\(error.localizedDescription)"
            }
        }
    }

    private func exportAnnotations() {
        let name = "\(paper.citekey.nilIfBlank ?? paper.displayTitle.sanitizedFileName())-annotations.md"
        guard let url = DialogService.saveURL(title: "导出标注", name: name, types: [.plainText]) else { return }
        do {
            let text = TemplateRenderer.renderAnnotations(paper.annotations, template: store.settings.annotationTemplate)
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.statusMessage = "标注导出完成。"
        } catch {
            store.statusMessage = "标注导出失败：\(error.localizedDescription)"
        }
    }

    private var canRefreshMetadata: Bool {
        paper.doi.nilIfBlank != nil ||
        paper.arxivLookupID != nil ||
        paper.isbn.nilIfBlank != nil ||
        paper.title.nilIfBlank != nil
    }

    private func refreshMetadata() {
        guard canRefreshMetadata else { return }
        isRefreshingMetadata = true
        let current = paper
        Task {
            do {
                let metadata = try await MetadataLookupClient.lookup(
                    doi: current.doi.nilIfBlank,
                    arxivID: current.arxivLookupID,
                    isbn: current.isbn.nilIfBlank,
                    title: current.title.nilIfBlank
                )
                await MainActor.run {
                    paper = metadata.merged(into: paper, replaceExisting: false)
                    isRefreshingMetadata = false
                    store.statusMessage = "元数据已刷新。"
                }
            } catch {
                await MainActor.run {
                    isRefreshingMetadata = false
                    store.statusMessage = "元数据刷新失败：\(error.localizedDescription)"
                }
            }
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

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(PMTypography.sectionHeader)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content
            }
        }
    }
}

private struct InspectorValueRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(PMTypography.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                content
                    .font(PMTypography.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)

            Divider()
                .padding(.leading, 82)
        }
    }
}

private struct ToggleChip: View {
    let title: String
    var systemImage: String? = nil
    var color: Color? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                } else if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .lineLimit(1)
                if isOn {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                }
            }
            .font(PMTypography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct AnnotationInspectorRow: View {
    let annotation: ResearchAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(Color(hex: annotation.colorHex))
                    .frame(width: 7, height: 7)
                Text(annotation.kind.displayTitle)
                    .font(PMTypography.paperCallout)
                Text("– Page \(annotation.pageLabel.nilIfBlank ?? String(annotation.page))")
                    .font(PMTypography.paperCallout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ExportService.copyToPasteboard(annotation.copyText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制标注")
            }

            if !annotation.selectedText.trimmed.isEmpty {
                Text(annotation.selectedText)
                    .font(PMTypography.paperBody)
                    .textSelection(.enabled)
            }

            if !annotation.note.trimmed.isEmpty {
                Text(annotation.note)
                    .font(PMTypography.paperBodyRegular)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let imageFilePath = annotation.imageFilePath {
                AnnotationImagePreview(path: imageFilePath)
            }
        }
        .padding(.vertical, 11)

        Divider()
    }
}

private struct PlainInspectorTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(PMTypography.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AnnotationImagePreview: View {
    let path: String

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }
}

private extension ResearchAnnotation {
    var copyText: String {
        [
            "Page \(page)",
            kind.rawValue,
            selectedText,
            note
        ]
        .map(\.trimmed)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

private extension AnnotationKind {
    var displayTitle: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikeout"
        case .note: return "Note"
        case .freeText: return "Free Text"
        case .square: return "Square"
        case .circle: return "Circle"
        }
    }
}
