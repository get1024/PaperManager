import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum InspectorTab {
    case metadata
    case annotations

    var title: String {
        switch self {
        case .metadata: return PMLocalization.text("元数据")
        case .annotations: return PMLocalization.text("标注")
        }
    }
}

struct PaperDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: Set<UUID>
    @StateObject private var editing = PaperDraftSession()

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
                    message: PMLocalization.format("当前选择了 %lld 篇文献。可从右上角导出或删除。", selection.count)
                )
            } else if let id = selectedID {
                PaperEditorView(paper: editing.binding(for: id),
                                isCurrentPaper: { editing.loadedID == id },
                                onCommitDraft: { editing.flush() })
                    .id(id)
            }
        }
        .accessibilityIdentifier("inspector-root")
        .onAppear { editing.select(selectedID, in: store) }
        .onChange(of: selectedID) { _, id in editing.select(id, in: store) }
        .onDisappear { editing.flush() }
        .onChange(of: selectedID.flatMap { store.paper(with: $0) }) { _, latest in
            editing.receive(latest)
        }
    }
}

/// Own the draft outside SwiftUI's deferred change callbacks. A binding write is
/// immediately visible to selection changes and the synchronous quit flush.
@MainActor
final class PaperDraftSession: ObservableObject {
    @Published private(set) var draft = Paper()
    private(set) var loadedID: UUID?
    private var baseline = Paper()
    private var store: LibraryStore?
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private let autosaveDelay: UInt64
    private static let sessions = NSHashTable<PaperDraftSession>.weakObjects()
    // A failed write must survive the owning window disappearing. The session
    // is released again as soon as all of its drafts have reached disk.
    private static var failedSessions: [ObjectIdentifier: PaperDraftSession] = [:]
    private struct DraftKey: Hashable {
        let store: ObjectIdentifier
        let paper: UUID
    }
    private struct DeferredDraft {
        let store: LibraryStore
        let draft: Paper
        let baseline: Paper
    }
    private var deferredDrafts: [DraftKey: DeferredDraft] = [:]
    private(set) var saveError: String?

    init(autosaveDelayNanoseconds: UInt64 = 450_000_000) {
        autosaveDelay = autosaveDelayNanoseconds
        Self.sessions.add(self)
    }

    func binding(for id: UUID) -> Binding<Paper> {
        Binding {
            self.loadedID == id ? self.draft : (self.store?.paper(with: id) ?? Paper(id: id))
        } set: { paper in
            guard self.loadedID == id, paper.id == id else { return }
            self.edit(paper)
        }
    }

    func select(_ id: UUID?, in store: LibraryStore) {
        guard self.store !== store || loadedID != id else {
            receive(id.flatMap { store.paper(with: $0) })
            return
        }
        if !flush(), let previousStore = self.store, let loadedID,
           !draft.hasSameEditableContent(as: baseline) {
            let key = DraftKey(store: ObjectIdentifier(previousStore), paper: loadedID)
            deferredDrafts[key] = DeferredDraft(store: previousStore, draft: draft, baseline: baseline)
        }
        self.store = store
        let paper = id.flatMap { store.paper(with: $0) }
        loadedID = paper?.id
        baseline = paper ?? Paper()
        if let id, let paper,
           let pending = deferredDrafts.removeValue(forKey: DraftKey(store: ObjectIdentifier(store), paper: id)) {
            draft = pending.draft.applyingEdits(to: paper, from: pending.baseline)
        } else {
            draft = baseline
        }
    }

    func edit(_ paper: Paper) {
        // A binding from a disappearing editor can still deliver its last write.
        guard loadedID == paper.id else { return }
        draft = paper
        saveTask?.cancel()
        revision &+= 1
        let scheduledRevision = revision
        saveTask = Task { [weak self, autosaveDelay] in
            do { try await Task.sleep(nanoseconds: autosaveDelay) }
            catch { return }
            guard let self, !Task.isCancelled, self.revision == scheduledRevision,
                  self.loadedID == paper.id else { return }
            self.flush()
        }
    }

    func receive(_ latest: Paper?) {
        guard let latest, latest.id == loadedID else { return }
        let merged = draft.applyingEdits(to: latest, from: baseline)
        baseline = latest
        draft = merged
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        revision &+= 1
        saveError = nil
        for (key, pending) in Array(deferredDrafts) {
            do {
                try persist(pending.draft, baseline: pending.baseline, in: pending.store)
                deferredDrafts.removeValue(forKey: key)
            } catch { recordSaveError(error, in: pending.store) }
        }
        if loadedID == draft.id, let store {
            do {
                if let saved = try persist(draft, baseline: baseline, in: store) {
                    baseline = saved
                    draft = saved
                }
            } catch { recordSaveError(error, in: store) }
        }
        if saveError == nil {
            Self.failedSessions.removeValue(forKey: ObjectIdentifier(self))
            return true
        }
        Self.failedSessions[ObjectIdentifier(self)] = self
        return false
    }

    @discardableResult
    private func persist(_ paper: Paper, baseline: Paper, in store: LibraryStore) throws -> Paper? {
        // A record intentionally removed elsewhere is never recreated by a draft.
        guard let latest = store.paper(with: paper.id) else { return nil }
        try store.updatePaperDurably(paper.applyingEdits(to: latest, from: baseline))
        return store.paper(with: paper.id)
    }

    private func recordSaveError(_ error: Error, in store: LibraryStore) {
        let message = PMLocalization.format("保存文库失败：%@", error.localizedDescription)
        saveError = saveError ?? message
        store.statusMessage = message
    }

    @discardableResult
    static func flushAll() -> Bool {
        let active = sessions.allObjects + Array(failedSessions.values)
        var visited = Set<ObjectIdentifier>()
        var succeeded = true
        for session in active where visited.insert(ObjectIdentifier(session)).inserted {
            if !session.flush() { succeeded = false }
        }
        return succeeded
    }
}

struct InspectorMetadataField: Identifiable {
    let id: String
    private let titleKey: String
    var title: String { PMLocalization.text(titleKey) }
    private enum Storage {
        case text(WritableKeyPath<Paper, String>)
        case optional(WritableKeyPath<Paper, String?>)
    }
    private let storage: Storage
    let types: Set<PaperType>

    init(id: String, title: String, keyPath: WritableKeyPath<Paper, String>, types: Set<PaperType>) {
        self.id = id; self.titleKey = title; storage = .text(keyPath); self.types = types
    }

    init(id: String, title: String, optionalKeyPath: WritableKeyPath<Paper, String?>, types: Set<PaperType>) {
        self.id = id; self.titleKey = title; storage = .optional(optionalKeyPath); self.types = types
    }

    func value(in paper: Paper) -> String {
        switch storage {
        case .text(let keyPath): return paper[keyPath: keyPath]
        case .optional(let keyPath): return paper[keyPath: keyPath] ?? ""
        }
    }

    func setValue(_ value: String, in paper: inout Paper) {
        switch storage {
        case .text(let keyPath): paper[keyPath: keyPath] = value
        case .optional(let keyPath): paper[keyPath: keyPath] = value.nilIfBlank
        }
    }

    static let all: [InspectorMetadataField] = [
        .init(id: "subtitle", title: "副标题", optionalKeyPath: \.subtitle, types: Set(PaperType.allCases)),
        .init(id: "editors", title: "编辑", keyPath: \.editorsText, types: [.book, .inBook, .inCollection, .proceedings]),
        .init(id: "translators", title: "译者", keyPath: \.translatorsText, types: [.book, .inBook, .inCollection]),
        .init(id: "address", title: "地址", optionalKeyPath: \.address, types: Set(PaperType.allCases)),
        .init(id: "organization", title: "组织", optionalKeyPath: \.organization, types: [.report, .patent, .inProceedings, .proceedings]),
        .init(id: "type", title: "文献子类型", optionalKeyPath: \.type, types: [.thesis, .report, .patent, .misc]),
        .init(id: "urlDate", title: "访问日期", optionalKeyPath: \.urlDate, types: Set(PaperType.allCases)),
        .init(id: "journal", title: "期刊", keyPath: \.journal, types: [.article, .preprint]),
        .init(id: "bookTitle", title: "书名 / 会议录", keyPath: \.bookTitle, types: [.inBook, .inCollection, .inProceedings, .proceedings]),
        .init(id: "publisher", title: "出版社", keyPath: \.publisher, types: [.book, .inBook, .inCollection, .inProceedings, .proceedings, .report]),
        .init(id: "institution", title: "机构", keyPath: \.institution, types: [.report, .patent]),
        .init(id: "school", title: "学校", keyPath: \.school, types: [.thesis]),
        .init(id: "series", title: "系列", keyPath: \.series, types: [.book, .inBook, .inCollection, .proceedings]),
        .init(id: "volume", title: "卷", keyPath: \.volume, types: [.article, .book, .inBook, .inCollection, .inProceedings, .proceedings]),
        .init(id: "issue", title: "期", keyPath: \.issue, types: [.article]),
        .init(id: "pages", title: "页码", keyPath: \.pages, types: [.article, .inBook, .inCollection, .inProceedings]),
        .init(id: "month", title: "月份", keyPath: \.month, types: Set(PaperType.allCases)),
        .init(id: "doi", title: "DOI", keyPath: \.doi, types: Set(PaperType.allCases)),
        .init(id: "isbn", title: "ISBN", keyPath: \.isbn, types: Set(PaperType.allCases)),
        .init(id: "url", title: "URL", keyPath: \.url, types: Set(PaperType.allCases)),
        .init(id: "language", title: "语言", keyPath: \.language, types: Set(PaperType.allCases)),
        .init(id: "event", title: "会议名称", keyPath: \.event, types: [.inProceedings, .proceedings]),
        .init(id: "eventDate", title: "会议日期", keyPath: \.eventDate, types: [.inProceedings, .proceedings]),
        .init(id: "venue", title: "会议地点", keyPath: \.venue, types: [.inProceedings, .proceedings]),
        .init(id: "edition", title: "版次", keyPath: \.edition, types: [.book, .inBook, .inCollection]),
        .init(id: "chapter", title: "章节", keyPath: \.chapter, types: [.inBook, .inCollection]),
        .init(id: "eprint", title: "电子预印本", keyPath: \.eprint, types: Set(PaperType.allCases)),
        .init(id: "eprintType", title: "预印本类型", keyPath: \.eprintType, types: [.preprint]),
        .init(id: "eprintClass", title: "预印本分类", keyPath: \.eprintClass, types: [.preprint]),
        .init(id: "pubState", title: "出版状态", keyPath: \.publicationState, types: Set(PaperType.allCases)),
        .init(id: "howpublished", title: "出版方式", keyPath: \.howPublished, types: [.preprint, .online, .software, .dataset, .misc])
    ]

    static func primary(for paper: Paper) -> [InspectorMetadataField] {
        let source: String?
        switch paper.paperType {
        case .article, .preprint: source = "journal"
        case .book: source = "publisher"
        case .inBook, .inCollection, .inProceedings, .proceedings: source = "bookTitle"
        case .thesis: source = "school"
        case .report, .patent: source = "institution"
        default: source = nil
        }
        let bookTypes: Set<PaperType> = [.book, .inBook, .inCollection, .proceedings]
        let ids = [source, "doi",
                   bookTypes.contains(paper.paperType) || !paper.isbn.isEmpty ? "isbn" : nil,
                   paper.paperType == .preprint || !paper.eprint.isEmpty ? "eprint" : nil,
                   paper.paperType == .preprint || !paper.eprintClass.isEmpty ? "eprintClass" : nil,
                   "url"].compactMap { $0 }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    static func additional(for paper: Paper, including pinnedIDs: Set<String> = []) -> [InspectorMetadataField] {
        let primaryIDs = Set(primary(for: paper).map(\.id))
        return all.filter {
            !primaryIDs.contains($0.id) &&
            ($0.types.contains(paper.paperType) || pinnedIDs.contains($0.id) || !$0.value(in: paper).trimmed.isEmpty ||
             ($0.id.hasPrefix("eprint") && !paper.eprint.trimmed.isEmpty))
        }
    }
}

private struct PaperEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var paper: Paper
    var isCurrentPaper: () -> Bool
    var onCommitDraft: () -> Void
    @State private var selectedTab: InspectorTab = .metadata
    @State private var showMoreFields = false
    @State private var showAdvancedFields = false
    @AppStorage("PaperManager.Inspector.pinnedStandardFields") private var pinnedStandardFieldIDs = ""
    @State private var showExportPreview = false
    @State private var isRefreshingMetadata = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorTabBar

            Group {
                if selectedTab == .metadata {
                    metadataInspector
                } else {
                    annotationInspector
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showAdvancedFields) { advancedFieldsSheet }
    }

    private var inspectorTabBar: some View {
        HStack(spacing: 0) {
            ForEach([InspectorTab.metadata, InspectorTab.annotations], id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 0) {
                        Text(tab.title)
                            .font(PMTypography.headline)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paper-detail-tab-picker")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 0)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.75))
                .frame(height: 1)
        }
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
                    ForEach(InspectorMetadataField.primary(for: paper)) { field in
                        metadataField(field)
                    }
                    DisclosureGroup("更多字段 · \(moreFieldValueCount)", isExpanded: $showMoreFields) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(pinnedAdditionalFields) { field in
                                advancedMetadataField(field)
                            }
                            ForEach(paper.customFields.filter(\.pinned)) { field in
                                customFieldRow(customFieldBinding(id: field.id))
                            }
                            Button("高级字段…") { showAdvancedFields = true }
                                .accessibilityIdentifier("paper-open-advanced-fields")
                        }
                    }
                    .padding(.top, 6)
                }

                if paper.customFields.contains(where: { !$0.pinned }) {
                    InspectorSection(title: "自定义字段") {
                        customFieldRows
                    }
                }

                InspectorSection(title: "文库") {
                    InspectorValueRow(title: "评分") {
                        HStack(spacing: 8) {
                            StarRatingView(rating: $paper.rating)
                            Text(paper.rating == 0 ? PMLocalization.text("未评分") : "\(paper.rating) / 5")
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
                        PlainInspectorTextEditor(text: $paper.abstract, minHeight: 130, font: PMTypography.detailAbstract)
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
                HStack {
                    Button("刷新标注", systemImage: "arrow.clockwise") { refreshAnnotations() }
                        .disabled(paper.primaryPDF == nil)
                    Button("导出标注", systemImage: "square.and.arrow.up") { exportAnnotations() }
                        .disabled(paper.annotations.isEmpty)
                }

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
                .font(PMTypography.detailTitle)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Picker("文献类型", selection: $paper.paperType) {
                    ForEach(PaperType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
            } label: {
                Text(paper.paperType.label)
                    .font(PMTypography.captionRegular)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更改文献类型")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: paper.hasPDF ? "doc.richtext" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("标题", text: $paper.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(PMTypography.detailTitle)
                        .lineLimit(2...4)

                    TextField("作者", text: Binding(
                        get: { paper.authorsText },
                        set: { paper.authorsText = $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PMTypography.paperCallout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)

                    Text(paper.citekey)
                        .textSelection(.enabled)
                        // Keep AppKit's native AX value for selectable text.
                        // A SwiftUI label override here recurses after an AX-
                        // active inspector is rebuilt (see the native AX smoke).
                        .help("引用键随元数据和引用格式自动更新")
                        .font(PMTypography.paperCaption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
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

    private var collectionSelector: some View {
        InspectorChipFlowLayout {
            ForEach(flattenedCollections.filter { paper.collectionIDs.contains($0.id) }) { item in
                ToggleChip(title: item.collection.name, systemImage: "folder",
                           isOn: containsBinding(id: item.id, keyPath: \.collectionIDs))
            }
            Menu {
                ForEach(flattenedCollections) { item in
                    Toggle(item.collection.name, isOn: containsBinding(id: item.id, keyPath: \.collectionIDs))
                }
            } label: { Label("添加到文集", systemImage: "plus") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("添加到文集")
        }
    }

    private var tagSelector: some View {
        InspectorChipFlowLayout {
            ForEach(store.tags.filter { paper.tagIDs.contains($0.id) }) { tag in
                ToggleChip(title: tag.name, color: Color(hex: tag.colorHex),
                           isOn: containsBinding(id: tag.id, keyPath: \.tagIDs))
            }
            Menu {
                ForEach(store.tags) { tag in
                    Toggle(tag.name, isOn: containsBinding(id: tag.id, keyPath: \.tagIDs))
                }
            } label: { Label("添加标签", systemImage: "plus") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("添加标签")
        }
    }

    private var attachmentInspectorRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    attach(types: [UTType.pdf], kind: AttachmentKind.pdf)
                } label: {
                    Label(PMLocalization.text(paper.hasPDF ? "替换 PDF" : "添加 PDF"), systemImage: "doc.badge.plus")
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
                            if attachment.isReadOnlyReference {
                                Text("Lattice 原文件 · 只读引用")
                                    .font(PMTypography.captionRegular)
                                    .foregroundStyle(.secondary)
                            }
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

    private var pinnedStandardIDs: Set<String> {
        Set(pinnedStandardFieldIDs.split(separator: ",").map(String.init))
    }

    private var additionalFields: [InspectorMetadataField] {
        InspectorMetadataField.additional(for: paper, including: pinnedStandardIDs)
    }

    private var pinnedAdditionalFields: [InspectorMetadataField] {
        additionalFields.filter { pinnedStandardIDs.contains($0.id) }
    }

    private var moreFieldValueCount: Int {
        pinnedAdditionalFields.filter { !$0.value(in: paper).trimmed.isEmpty }.count +
        paper.customFields.filter(\.pinned).count
    }

    private func metadataField(_ field: InspectorMetadataField) -> some View {
        inspectorField(field.id == "journal" && paper.paperType == .preprint ? "来源" : field.title, text: Binding(
            get: { field.value(in: paper) },
            set: { field.setValue($0, in: &paper) }
        ), axis: ["subtitle", "editors", "translators"].contains(field.id) ? .vertical : .horizontal)
        .accessibilityIdentifier("paper-field-\(field.id)")
    }

    private func advancedMetadataField(_ field: InspectorMetadataField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            metadataField(field)
            Button {
                var ids = pinnedStandardIDs
                if !ids.insert(field.id).inserted { ids.remove(field.id) }
                pinnedStandardFieldIDs = ids.sorted().joined(separator: ",")
            } label: {
                Image(systemName: pinnedStandardIDs.contains(field.id) ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(pinnedStandardIDs.contains(field.id) ? "取消固定到更多字段" : "固定到更多字段")
            .accessibilityLabel(PMLocalization.text(pinnedStandardIDs.contains(field.id) ? "取消置顶" : "置顶"))
            .accessibilityIdentifier("advanced-fields-pin-typed-\(field.id)")
        }
    }

    private var advancedFieldsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(paper.displayTitle) 高级字段")
                .font(.headline)
                .lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("标准字段").font(PMTypography.headline)
                    ForEach(additionalFields) { field in advancedMetadataField(field) }
                    Divider()
                    Text("自定义字段").font(PMTypography.headline)
                    ForEach(paper.customFields) { field in
                        customFieldRow(customFieldBinding(id: field.id))
                    }
                    addCustomFieldButton
                }
                .padding(.horizontal, 2)
            }
            HStack {
                Spacer()
                Button("完成") { showAdvancedFields = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func customFieldBinding(id: UUID) -> Binding<CustomField> {
        Binding {
            paper.customFields.first { $0.id == id } ?? CustomField(id: id, key: "", value: "")
        } set: { value in
            guard let index = paper.customFields.firstIndex(where: { $0.id == id }) else { return }
            paper.customFields[index] = value
        }
    }

    private var customFieldRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paper.customFields.filter { !$0.pinned }) { field in
                customFieldRow(customFieldBinding(id: field.id))
            }
            addCustomFieldButton
        }
    }

    private var addCustomFieldButton: some View {
        Button {
            paper.customFields.append(CustomField(key: "", value: ""))
        } label: {
            Label("添加自定义字段", systemImage: "plus")
        }
        .accessibilityIdentifier("paper-add-custom-field")
    }

    private func customFieldRow(_ field: Binding<CustomField>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("字段名", text: field.key)
                .frame(width: 82)
            TextField("值", text: field.value, axis: .vertical)
                .lineLimit(1...3)
            Button {
                field.pinned.wrappedValue.toggle()
            } label: {
                Image(systemName: field.wrappedValue.pinned ? "pin.fill" : "pin")
            }
            .help(field.wrappedValue.pinned ? "取消置顶" : "固定到更多字段")
            .accessibilityLabel(PMLocalization.text(field.wrappedValue.pinned ? "取消置顶字段" : "置顶字段"))
            Button(role: .destructive) {
                let id = field.wrappedValue.id
                paper.customFields.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .help("删除自定义字段")
            .accessibilityLabel("删除自定义字段")
        }
        .textFieldStyle(.plain)
        .font(PMTypography.paperCallout)
        .padding(.vertical, 4)
        .accessibilityIdentifier("custom-field-\(field.wrappedValue.id.uuidString)")
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
        onCommitDraft()
        guard let url = DialogService.chooseFiles(title: "选择要关联的文件", types: types, multiple: false).first else { return }
        do {
            try store.attachFile(url, to: paper.id, kind: kind, replacePrimary: kind == .pdf && paper.hasPDF)
            if let updated = store.paper(with: paper.id) {
                paper = updated
            }
        } catch {
            store.statusMessage = PMLocalization.format("无法关联 %@：%@", url.lastPathComponent, error.localizedDescription)
        }
    }

    private func refreshAnnotations() {
        guard let pdf = paper.primaryPDF else { return }
        let requestedID = paper.id
        Task {
            do {
                let annotations = try await ImportService.extractAnnotations(from: pdf, paperID: requestedID)
                if isCurrentPaper(), paper.id == requestedID {
                    paper.annotations = annotations
                } else {
                    store.updateAnnotations(annotations, for: requestedID)
                }
                store.statusMessage = PMLocalization.text("标注已刷新。")
            } catch {
                store.statusMessage = PMLocalization.format("标注提取失败：%@", error.localizedDescription)
            }
        }
    }

    private func exportAnnotations() {
        let name = "\(paper.citekey.nilIfBlank ?? paper.displayTitle.sanitizedFileName())-annotations.md"
        guard let url = DialogService.saveURL(title: "导出标注", name: name, types: [.plainText]) else { return }
        do {
            let text = TemplateRenderer.renderAnnotations(paper.annotations, template: store.settings.annotationTemplate)
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.statusMessage = PMLocalization.text("标注导出完成。")
        } catch {
            store.statusMessage = PMLocalization.format("标注导出失败：%@", error.localizedDescription)
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
                    if isCurrentPaper(), paper.id == current.id {
                        paper = metadata.merged(into: paper, replaceExisting: false)
                    } else if let original = store.paper(with: current.id) {
                        store.updatePaper(metadata.merged(into: original, replaceExisting: false))
                    }
                    isRefreshingMetadata = false
                    store.statusMessage = PMLocalization.text("元数据已刷新。")
                }
            } catch {
                await MainActor.run {
                    isRefreshingMetadata = false
                    store.statusMessage = PMLocalization.format("元数据刷新失败：%@", error.localizedDescription)
                }
            }
        }
    }

    private func openPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        do {
            try pdf.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message(PMLocalization.text("PDF 文件不存在，可能已在 Finder 中移动或删除。"))
                }
                if let readerPath = store.settings.defaultPDFReaderPath.nilIfBlank {
                    let appURL = URL(fileURLWithPath: readerPath)
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                        if let error {
                            Task { @MainActor in
                                store.statusMessage = PMLocalization.format("无法使用所选阅读器打开 PDF：%@", error.localizedDescription)
                            }
                        }
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        } catch {
            store.statusMessage = PMLocalization.format("无法打开 PDF：%@", error.localizedDescription)
        }
    }

    private func revealPrimaryPDF() {
        guard let pdf = paper.primaryPDF else { return }
        do {
            try pdf.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message(PMLocalization.text("PDF 文件不存在，可能已在 Finder 中移动或删除。"))
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            store.statusMessage = PMLocalization.format("无法在 Finder 中显示 PDF：%@", error.localizedDescription)
        }
    }

    private func openAttachment(_ attachment: Attachment) {
        do {
            try attachment.withResolvedURL { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PaperManagerError.message(PMLocalization.text("文件不存在，可能已在 Finder 中移动或删除。"))
                }
                NSWorkspace.shared.open(url)
            }
        } catch {
            store.statusMessage = PMLocalization.format("无法打开附件：%@", error.localizedDescription)
        }
    }
}

private struct InspectorChipFlowLayout: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 260, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, point) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified)))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
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
            Text(PMLocalization.text(title))
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
                Text(PMLocalization.text(title))
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
                    Image(systemName: "xmark")
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
    var font: Font = PMTypography.callout

    var body: some View {
        TextEditor(text: $text)
            .font(font)
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
        case .highlight: return PMLocalization.text("Highlight")
        case .underline: return PMLocalization.text("Underline")
        case .strikeout: return PMLocalization.text("Strikeout")
        case .note: return PMLocalization.text("Note")
        case .freeText: return PMLocalization.text("Free Text")
        case .square: return PMLocalization.text("Square")
        case .circle: return PMLocalization.text("Circle")
        }
    }
}
