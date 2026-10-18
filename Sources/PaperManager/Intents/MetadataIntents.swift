import AppIntents
import Foundation

enum MetadataOutputMode: String, AppEnum {
    case returnText
    case copyToClipboard

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "输出" }
    static var caseDisplayRepresentations: [MetadataOutputMode: DisplayRepresentation] {
        [.returnText: "返回文本", .copyToClipboard: "复制到剪贴板"]
    }
}

struct PaperEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "文献" }
    static var defaultQuery = PaperEntityQuery()

    var id: String
    @Property(title: "标题") var title: String
    @Property(title: "作者") var authors: String
    @Property(title: "年份") var year: String
    @Property(title: "引用键") var citekey: String

    init(paper: Paper) {
        id = paper.id.uuidString
        title = paper.displayTitle
        authors = paper.authorsDisplay
        year = paper.year.map(String.init) ?? ""
        citekey = paper.citekey
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(authors)", image: .init(systemName: "doc.text"))
    }
}

struct PaperEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PaperEntity] {
        let snapshot = try MetadataIntentLibrary.loadSnapshot()
        return identifiers.compactMap { value in
            guard let id = UUID(uuidString: value), let paper = snapshot.papers.first(where: { $0.id == id }) else { return nil }
            return PaperEntity(paper: paper)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PaperEntity] {
        let snapshot = try MetadataIntentLibrary.loadSnapshot()
        let query = string.trimmed
        return snapshot.papers.filter { paper in
            query.isEmpty || [paper.displayTitle, paper.authorsDisplay, paper.citekey, paper.doi, paper.isbn,
                              paper.eprint, paper.journal, paper.bookTitle].contains { $0.localizedCaseInsensitiveContains(query) }
        }.map(PaperEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PaperEntity] {
        try MetadataIntentLibrary.loadSnapshot().papers.sorted { $0.dateAdded > $1.dateAdded }
            .prefix(50).map(PaperEntity.init)
    }
}

struct TemplateEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "元数据模板" }
    static var defaultQuery = TemplateEntityQuery()

    var id: String
    @Property(title: "名称") var name: String
    @Property(title: "模板内容") var body: String

    init(snapshot: LibrarySnapshot) {
        self.init(template: snapshot.selectedMetadataTemplate)
    }

    init(template: MetadataTemplate) {
        id = template.id.uuidString
        name = template.name
        body = template.content
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "text.alignleft"))
    }
}

struct TemplateEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TemplateEntity] {
        let snapshot = try MetadataIntentLibrary.loadSnapshot()
        return identifiers.compactMap { value in
            guard let id = UUID(uuidString: value), let template = snapshot.metadataTemplate(withID: id) else { return nil }
            return TemplateEntity(template: template)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TemplateEntity] {
        let templates = try MetadataIntentLibrary.loadSnapshot().availableMetadataTemplates
        return templates.filter { string.trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(string) }
            .map(TemplateEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TemplateEntity] {
        try MetadataIntentLibrary.loadSnapshot().availableMetadataTemplates.map(TemplateEntity.init)
    }
}

struct ExportPaperMetadataIntent: AppIntent {
    static var title: LocalizedStringResource { "导出文献元数据" }
    static var description: IntentDescription? { "使用设置中的元数据模板导出文献，可包含 PDF 标注。" }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "文献") var paper: PaperEntity
    @Parameter(title: "模板") var template: TemplateEntity?
    @Parameter(title: "包含标注", default: false) var includeAnnotations: Bool
    @Parameter(title: "输出", default: .copyToClipboard) var output: MetadataOutputMode

    static var parameterSummary: some ParameterSummary {
        Summary("导出 \(\.$paper) 的元数据") {
            \.$template
            \.$includeAnnotations
            \.$output
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let snapshot = try MetadataIntentLibrary.loadSnapshot()
        let text = try MetadataIntentLibrary.export(
            paperID: paper.id, templateID: template?.id, includeAnnotations: includeAnnotations,
            output: output, snapshot: snapshot, copyToClipboard: ExportService.copyToPasteboard
        )
        return .result(value: text)
    }
}

struct PaperManagerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportPaperMetadataIntent(),
            phrases: ["使用 \(.applicationName) 导出文献", "Export paper metadata from \(.applicationName)"],
            shortTitle: "导出文献", systemImageName: "doc.text"
        )
    }
}

@MainActor
enum MetadataIntentLibrary {
    static func loadSnapshot() throws -> LibrarySnapshot {
        let store = LibraryStore()
        if let error = store.loadError { throw PaperManagerError.message(error) }
        return store.snapshot
    }

    static func export(
        paperID: String,
        templateID: String?,
        includeAnnotations: Bool,
        output: MetadataOutputMode,
        snapshot: LibrarySnapshot,
        copyToClipboard: (String) -> Void
    ) throws -> String {
        guard let id = UUID(uuidString: paperID), let paper = snapshot.papers.first(where: { $0.id == id }) else {
            throw PaperManagerError.message("文献已删除或不存在，请重新选择文献。")
        }
        var selectedTemplateID: UUID?
        if let templateID {
            guard let parsed = UUID(uuidString: templateID), snapshot.metadataTemplate(withID: parsed) != nil else {
                throw PaperManagerError.message("模板已不可用，请重新选择元数据模板。")
            }
            selectedTemplateID = parsed
        }
        let text = TemplateRenderer.renderMetadata(paper: paper, snapshot: snapshot,
                                                   includeAnnotations: includeAnnotations, templateID: selectedTemplateID)
        if output == .copyToClipboard { copyToClipboard(text) }
        return text
    }
}
