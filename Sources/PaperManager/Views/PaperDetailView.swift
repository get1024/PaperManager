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
                                rating: Binding(get: { store.paper(with: id)?.rating ?? 0 },
                                                set: { store.updateRating($0, for: id) }),
                                isCurrentPaper: { editing.loadedID == id },
                                onCommitDraft: { editing.flush() })
                    .id(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                   "url",
                   paper.paperType == .preprint || !paper.eprint.isEmpty ? "eprint" : nil,
                   paper.paperType == .preprint || !paper.eprintClass.isEmpty ? "eprintClass" : nil].compactMap { $0 }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    static func additional(for paper: Paper, including pinnedIDs: Set<String> = []) -> [InspectorMetadataField] {
        let primaryIDs = Set(primary(for: paper).map(\.id))
        if paper.paperType == .preprint {
            // The preprint sheet has a small ordered default schema. Keep
            // nondefault data and pinned fields reachable after those defaults.
            let defaults = ["subtitle", "eprintType", "howpublished", "urlDate", "month", "language", "pubState"]
            let defaultIDs = Set(defaults)
            return defaults.compactMap { id in all.first { $0.id == id } } + all.filter {
                !primaryIDs.contains($0.id) && !defaultIDs.contains($0.id) &&
                    (pinnedIDs.contains($0.id) || !$0.value(in: paper).trimmed.isEmpty)
            }
        }
        return all.filter {
            !primaryIDs.contains($0.id) &&
            ($0.types.contains(paper.paperType) || pinnedIDs.contains($0.id) || !$0.value(in: paper).trimmed.isEmpty ||
             ($0.id.hasPrefix("eprint") && !paper.eprint.trimmed.isEmpty))
        }
    }
}

private struct PaperEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var paper: Paper
    @Binding var rating: Int
    var isCurrentPaper: () -> Bool
    var onCommitDraft: () -> Bool
    @State private var selectedTab: InspectorTab = .metadata
    @State private var showMoreFields = false
    @State private var showAdvancedFields = false
    @AppStorage("PaperManager.Inspector.pinnedStandardFields") private var pinnedStandardFieldIDs = ""
    @State private var showExportPreview = false
    @State private var showAbstract = true
    @State private var isEditing = false
    @State private var showNotes = true
    @State private var isRefreshingAnnotations = false

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
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 6)

                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                            .padding(.horizontal, 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 43.5, maxHeight: 43.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paper-detail-tab-picker")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 15)
    }

    private var metadataInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                citationSection.padding(.top, -2)

                if isEditing, paper.customFields.contains(where: { !$0.pinned }) {
                    InspectorSection(title: "自定义字段") { customFieldRows }
                }

                InspectorSection(title: "文库", headerGap: 5) {
                    InspectorValueRow(title: "评分", labelWidth: 22, minimumHeight: 36,
                                      verticalAlignment: .center) {
                        HStack(spacing: 6) {
                            inspectorStars
                            Text(rating == 0 ? PMLocalization.text("未评分") : "\(rating) / 5")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                        }
                    }
                    InspectorValueRow(title: "文集", labelWidth: 23, minimumHeight: 36) { collectionSelector }
                    InspectorValueRow(title: "标签", labelWidth: 23, minimumHeight: 36) { tagSelector }
                }
                .padding(.top, -1)

                if isEditing {
                    InspectorSection(title: "附件") { attachmentInspectorRows }
                }

                InspectorSection(title: "内容", headerGap: 5, headingVerticalOffset: -1) {
                    DisclosureGroup("摘要", isExpanded: $showAbstract) {
                        InspectorInlineEditor(text: $paper.abstract,
                                              font: PMTypography.detailAbstract,
                                              nativeFont: .inspectorSerif(size: 12),
                                              multiline: true, lineSpacing: 19.0 / 3, editingLineSpacing: 1,
                                              identifier: "paper-field-abstract", isBulkEditing: isEditing,
                                              isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                            .padding(.top, 13)
                    }
                    .disclosureGroupStyle(InspectorContentDisclosureStyle())
                    .padding(.bottom, 10)
                    DisclosureGroup("备注", isExpanded: $showNotes) {
                        InspectorInlineEditor(text: $paper.notes, placeholder: PMLocalization.text("添加备注"),
                                              font: PMTypography.bodyRegular, nativeFont: .systemFont(ofSize: 13),
                                              multiline: true, identifier: "paper-field-notes", isBulkEditing: isEditing,
                                              isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                            .padding(.top, 8)
                    }
                    .disclosureGroupStyle(InspectorContentDisclosureStyle())
                }
                .padding(.top, -8)

                if isEditing {
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
            }
            .padding(.horizontal, 20)
            .padding(.top, 21)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.visible)
    }

    private var citationSection: some View {
        VStack(alignment: .leading, spacing: 7.5) {
            HStack {
                Text(PMLocalization.text("引用"))
                    .font(.system(size: 10, weight: .bold))
                Spacer()
                Button { refreshMetadata() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .help("刷新元数据")
                    .disabled(store.isRefreshingMetadata(paperID: paper.id) || !canRefreshMetadata)
            }
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                inspectorField("年份", text: Binding(
                    get: { paper.year.map(String.init) ?? "" },
                    set: { paper.year = Int($0.trimmed) }
                ), editable: isEditing, identifier: "paper-field-year")
                ForEach(InspectorMetadataField.primary(for: paper).filter { !["eprint", "eprintClass"].contains($0.id) }) { field in
                    metadataField(field)
                }
                if paper.paperType == .preprint || !paper.eprint.isEmpty || !paper.eprintClass.isEmpty {
                    if isEditing {
                        ForEach(InspectorMetadataField.primary(for: paper).filter { ["eprint", "eprintClass"].contains($0.id) }) { field in
                            metadataField(field)
                        }
                    } else {
                        InspectorValueRow(title: "电子预印本") {
                            HStack(spacing: 8) {
                                InspectorInlineEditor(text: $paper.eprint, placeholder: "—",
                                                      font: .system(size: 12), nativeFont: .systemFont(ofSize: 12),
                                                      identifier: "paper-field-eprint", highlightInset: 3,
                                                      isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                                    .frame(width: 58, alignment: .leading)
                                Text(PMLocalization.text("预印本分类"))
                                    .font(.system(size: 10))
                                InspectorInlineEditor(text: $paper.eprintClass, placeholder: "—",
                                                      font: .system(size: 12), nativeFont: .systemFont(ofSize: 12),
                                                      identifier: "paper-field-eprintClass", highlightInset: 3,
                                                      isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14.5) {
                    Button { showMoreFields.toggle() } label: {
                        HStack {
                            Text(PMLocalization.format("更多字段 · %lld", moreFieldValueCount))
                            Spacer()
                            Image(systemName: showMoreFields ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    if showMoreFields {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(visibleAdditionalFields) { field in advancedMetadataField(field) }
                            ForEach(paper.customFields.filter(\.pinned)) { field in
                                customFieldRow(customFieldBinding(id: field.id))
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("高级…") { showAdvancedFields = true }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("paper-open-advanced-fields")
                    }
                }
                .font(PMTypography.callout)
                .padding(.top, 6)
            }
        }
    }

    private var inspectorStars: some View {
        StarRatingView(rating: $rating, starSize: 13, spacing: 7.5, identity: paper.id)
            .accessibilityIdentifier("inspector-rating")
    }

    private var annotationInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5.5) {
                    Text(paper.displayTitle)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(paper.authors.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Divider().padding(.top, 12.5)
                Group {
                    if paper.annotations.isEmpty {
                        Text("未找到标注")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(paper.annotations) { annotation in
                                AnnotationInspectorRow(annotation: annotation)
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 19)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.visible)
        .contextMenu {
            Button("刷新标注", systemImage: "arrow.clockwise") { refreshAnnotations() }
                .disabled(paper.primaryPDF == nil || isRefreshingAnnotations)
            Button("导出标注", systemImage: "square.and.arrow.up") { exportAnnotations() }
                .disabled(paper.annotations.isEmpty)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Picker("文献类型", selection: $paper.paperType) {
                        ForEach(PaperType.allCases) { type in Text(type.label).tag(type) }
                    }
                } label: {
                    Text(paper.paperType.label)
                        .font(.system(size: 10))
                        // The native menu label needs an explicit text color.
                        .foregroundColor(Color.secondary.opacity(colorScheme == .dark ? 0.7 : 0.86))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: -3)
                .help("更改文献类型")
                Spacer()
                Button {
                    if isEditing && !onCommitDraft() { return }
                    isEditing.toggle()
                } label: { Image(systemName: isEditing ? "checkmark" : "pencil") }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(isEditing ? "完成编辑" : "编辑元数据")
                .accessibilityIdentifier("paper-edit-metadata")
                if paper.primaryPDF != nil {
                    Button { openPrimaryPDF() } label: { Image(systemName: "doc.text") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("打开 PDF")
                        .contextMenu {
                            Button("在访达中显示") { revealPrimaryPDF() }
                        }
                }
            }
            .padding(.bottom, 4.5)

            titleEditor.padding(.top, 14)

            InspectorInlineEditor(text: Binding(get: { paper.authorsText }, set: { paper.authorsText = $0 }),
                                  font: .system(size: 12), nativeFont: .systemFont(ofSize: 12),
                                  multiline: true, lineSpacing: 5.5, editingLineSpacing: 0,
                                  identifier: "paper-field-authors",
                                  isBulkEditing: isEditing, isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                .padding(.horizontal, 8)
                .padding(.top, 16)
            Text(paper.citekey)
                        .textSelection(.enabled)
                // Never override the AX label of selectable citation text; this
                // triggered a SwiftUI/AppKit recursion in the previous build.
                .help("引用键随元数据和引用格式自动更新")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 12)

            if let attachment = paper.primaryPDF {
                PaperPDFPreview(attachment: attachment)
                    .id(attachment)
                    .padding(.top, 20)
            }
        }
    }

    private var titleEditor: some View {
        InspectorInlineEditor(text: $paper.title, placeholder: "Untitled Paper",
                              font: .system(size: 15, weight: .bold, design: .serif),
                              nativeFont: .inspectorSerif(size: 15, weight: .bold), color: .primary,
                              multiline: true, lineSpacing: 4, editingLineSpacing: 2,
                              identifier: "paper-field-title",
                              isBulkEditing: isEditing,
                              highlightInsets: EdgeInsets(top: 6.5, leading: 6.5, bottom: 5.5, trailing: 8.5),
                              isCurrent: isCurrentPaper, onCommit: onCommitDraft)
            .padding(.horizontal, 8)
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
            .menuIndicator(.hidden)
            .fixedSize()
            .help("添加到文集")
        }
        // Native popup buttons can retain their previous AppKit position when
        // a draft load inserts chips ahead of them in a custom Layout.
        .id(paper.collectionIDs)
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
            .menuIndicator(.hidden)
            .fixedSize()
            .help("添加标签")
        }
        .id(paper.tagIDs)
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

    private var visibleAdditionalFields: [InspectorMetadataField] {
        additionalFields.filter { pinnedStandardIDs.contains($0.id) || !$0.value(in: paper).trimmed.isEmpty }
    }

    private var moreFieldValueCount: Int {
        visibleAdditionalFields.filter { !$0.value(in: paper).trimmed.isEmpty }.count +
        paper.customFields.filter(\.pinned).count
    }

    private func metadataField(_ field: InspectorMetadataField, editable: Bool? = nil) -> some View {
        inspectorField(field.id == "doi" ? "标识符" : (field.id == "journal" && paper.paperType == .preprint ? "来源" : field.title), text: Binding(
            get: { field.value(in: paper) },
            set: { field.setValue($0, in: &paper) }
        ), axis: ["subtitle", "editors", "translators"].contains(field.id) ? .vertical : .horizontal,
           editable: editable ?? isEditing, isURL: field.id == "url", monospaced: ["doi", "url"].contains(field.id),
           identifier: "paper-field-\(field.id)")
    }

    private func advancedMetadataField(_ field: InspectorMetadataField, inSheet: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if inSheet {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(field.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(field.value(in: paper).trimmed.isEmpty ? .tertiary : .secondary)
                        .frame(width: 144, alignment: .leading)
                    TextField("", text: Binding(
                        get: { field.value(in: paper) },
                        set: { field.setValue($0, in: &paper) }
                    ), axis: ["subtitle", "editors", "translators"].contains(field.id) ? .vertical : .horizontal)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("paper-field-\(field.id)")
            } else {
                metadataField(field, editable: isEditing)
            }
            Button {
                var ids = pinnedStandardIDs
                if !ids.insert(field.id).inserted { ids.remove(field.id) }
                pinnedStandardFieldIDs = ids.sorted().joined(separator: ",")
            } label: {
                Image(systemName: pinnedStandardIDs.contains(field.id) ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(field.value(in: paper).trimmed.isEmpty && !pinnedStandardIDs.contains(field.id) ? .tertiary : .secondary)
            .help(pinnedStandardIDs.contains(field.id) ? "取消固定到更多字段" : "固定到更多字段")
            .accessibilityLabel(PMLocalization.text(pinnedStandardIDs.contains(field.id) ? "取消置顶" : "置顶"))
            .accessibilityIdentifier("advanced-fields-pin-typed-\(field.id)")
        }
    }

    private var advancedFieldsSheet: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.displayTitle).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    .frame(height: 17, alignment: .topLeading)
                Text("高级字段").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 11)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("标准字段").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 5)
                    ForEach(additionalFields) { field in
                        advancedMetadataField(field, inSheet: true).frame(minHeight: 32)
                    }
                    Text("自定义字段").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, 12).padding(.bottom, 12)
                    ForEach(paper.customFields) { field in
                        customFieldRow(customFieldBinding(id: field.id))
                    }
                    HStack { Spacer(); addCustomFieldButton.buttonStyle(.link) }.padding(.top, 8)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") {
                    guard onCommitDraft() else { return }
                    showAdvancedFields = false
                }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
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

    private func inspectorField(_ title: String, text: Binding<String>, axis: Axis = .horizontal,
                                editable: Bool = true, isURL: Bool = false, monospaced: Bool = false,
                                identifier: String = "") -> some View {
        InspectorValueRow(title: title) {
            HStack(spacing: 6) {
                InspectorInlineEditor(text: text, placeholder: "—",
                                      font: monospaced ? .system(size: isURL ? 11 : 11.5, design: .monospaced) : .system(size: 12),
                                      nativeFont: monospaced ? .monospacedSystemFont(ofSize: isURL ? 11 : 11.5, weight: .regular) : .systemFont(ofSize: 12),
                                      multiline: axis == .vertical, identifier: identifier,
                                      isBulkEditing: editable, highlightInset: 3,
                                      isCurrent: isCurrentPaper, onCommit: onCommitDraft)
                if isURL, let url = URL(string: text.wrappedValue), !text.wrappedValue.trimmed.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("打开网址")
                }
            }
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
        guard onCommitDraft() else { return }
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
        guard !isRefreshingAnnotations, let pdf = paper.primaryPDF else { return }
        guard onCommitDraft() else { return }
        let requestedID = paper.id
        let baseline = paper.annotations
        let libraryToken = store.libraryIdentityToken
        isRefreshingAnnotations = true
        Task {
            defer { isRefreshingAnnotations = false }
            do {
                let annotations = try await ImportService.extractAnnotations(from: pdf, paperID: requestedID)
                // A PDF can be replaced, or annotations edited, while extraction
                // is running. A result belongs only to its original attachment
                // and unchanged annotation revision.
                guard store.libraryIdentityToken == libraryToken,
                      let latest = store.paper(with: requestedID),
                      latest.primaryPDF == pdf, latest.annotations == baseline else { return }
                if isCurrentPaper(), paper.id == requestedID {
                    guard paper.primaryPDF == pdf, paper.annotations == baseline else { return }
                }
                var updated = latest
                updated.annotations = annotations
                try store.updatePaperDurably(updated)
                if isCurrentPaper(), paper.id == requestedID {
                    paper.annotations = annotations
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
        let requestedID = paper.id
        guard onCommitDraft() else { return }
        store.enqueueMetadataRefresh(paperIDs: [requestedID])
    }

    private func openPrimaryPDF() {
        guard onCommitDraft(), let latest = store.paper(with: paper.id) else { return }
        PaperReaderActions.openPDF(latest, store: store)
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
        guard onCommitDraft() else { return }
        if attachment.kind == .pdf, let latest = store.paper(with: paper.id) {
            PaperReaderActions.openPDF(latest, attachment: attachment, store: store)
            return
        }
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
    private let spacing: CGFloat = 5
    private let rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 260, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                                 proposal: ProposedViewSize(placement.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [CGRect]) {
        let availableWidth = max(0, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placements: [CGRect] = []
        for subview in subviews {
            // Long collection names must truncate within the inspector, rather
            // than force the split pane wider than its actual viewport.
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, availableWidth), height: nil))
            if x > 0 && x + size.width > availableWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            placements.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: availableWidth, height: y + rowHeight), placements)
    }
}

private struct DetailCollectionRow: Identifiable {
    let collection: PaperCollection
    let depth: Int
    var id: UUID { collection.id }
}

private struct InspectorContentDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 10)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                        .font(.system(size: 12, weight: .semibold))
                        .offset(x: -1.5, y: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            if configuration.isExpanded {
                configuration.content.padding(.horizontal, 14)
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    var headerGap: CGFloat = 8
    var headingVerticalOffset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: headerGap) {
            Text(PMLocalization.text(title))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(y: headingVerticalOffset)
            VStack(spacing: 0) {
                content
            }
        }
    }
}

private struct InspectorValueRow<Content: View>: View {
    let title: String
    var labelWidth: CGFloat = 74
    var minimumHeight: CGFloat = 0
    var verticalAlignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: verticalAlignment, spacing: labelWidth < 40 ? 6 : 12) {
                Text(PMLocalization.text(title))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: labelWidth, alignment: .leading)
                content
                    .font(.system(size: 12, weight: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.leading, 8)


        }
        .frame(minHeight: minimumHeight, alignment: .top)
    }
}

private struct ToggleChip: View {
    let title: String
    var systemImage: String? = nil
    var color: Color? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: systemImage == nil ? 5 : 6.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else if let color {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(title).lineLimit(1)
            if isOn {
                Button { isOn = false } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .foregroundStyle(Color.primary)
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
