import Foundation

enum PaperType: String, Codable, CaseIterable, Identifiable {
    case article
    case book
    case inBook
    case inCollection
    case inProceedings
    case proceedings
    case thesis
    case preprint
    case report
    case patent
    case dataset
    case software
    case online
    case manuscript
    case misc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .article: return PMLocalization.text("期刊论文")
        case .book: return PMLocalization.text("图书")
        case .inBook: return PMLocalization.text("图书章节")
        case .inCollection: return PMLocalization.text("论文集章节")
        case .inProceedings: return PMLocalization.text("会议论文")
        case .proceedings: return PMLocalization.text("会议论文集")
        case .thesis: return PMLocalization.text("学位论文")
        case .preprint: return PMLocalization.text("预印本")
        case .report: return PMLocalization.text("报告")
        case .patent: return PMLocalization.text("专利")
        case .dataset: return PMLocalization.text("数据集")
        case .software: return PMLocalization.text("软件")
        case .online: return PMLocalization.text("在线资源")
        case .manuscript: return PMLocalization.text("手稿")
        case .misc: return PMLocalization.text("其他")
        }
    }

    var bibTeXType: String {
        switch self {
        case .article: return "article"
        case .book: return "book"
        case .inBook: return "inbook"
        case .inCollection: return "incollection"
        case .inProceedings: return "inproceedings"
        case .proceedings: return "proceedings"
        case .thesis: return "phdthesis"
        case .preprint: return "misc"
        case .report: return "techreport"
        case .patent: return "patent"
        case .dataset: return "dataset"
        case .software: return "software"
        case .online: return "online"
        case .manuscript: return "unpublished"
        case .misc: return "misc"
        }
    }

    var risType: String {
        switch self {
        case .article: return "JOUR"
        case .book: return "BOOK"
        case .inBook, .inCollection: return "CHAP"
        case .inProceedings: return "CPAPER"
        case .proceedings: return "CONF"
        case .thesis: return "THES"
        case .preprint: return "PREPRINT"
        case .report: return "RPRT"
        case .patent: return "PAT"
        case .dataset: return "DATA"
        case .software: return "COMP"
        case .online: return "WEB"
        case .manuscript: return "UNPB"
        case .misc: return "GEN"
        }
    }

    static func fromBibTeX(_ value: String) -> PaperType {
        switch value.lowercased() {
        case "article": return .article
        case "book": return .book
        case "inbook": return .inBook
        case "incollection": return .inCollection
        case "inproceedings", "conference": return .inProceedings
        case "proceedings": return .proceedings
        case "thesis", "phdthesis", "mastersthesis": return .thesis
        case "preprint": return .preprint
        case "techreport", "report": return .report
        case "patent": return .patent
        case "dataset": return .dataset
        case "software": return .software
        case "online", "webpage": return .online
        case "unpublished": return .manuscript
        default: return .misc
        }
    }
}

enum AttachmentKind: String, Codable, CaseIterable {
    case pdf
    case file
}

struct Attachment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: AttachmentKind = .file
    var filePath: String
    var displayName: String
    var bookmarkData: Data?
    var fileSize: Int64?
    var missing: Bool = false
    var isReadOnlyReference: Bool = false
    var addedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case filePath
        case displayName
        case bookmarkData
        case fileSize
        case missing
        case isReadOnlyReference
        case addedAt
    }

    init(
        id: UUID = UUID(),
        kind: AttachmentKind = .file,
        filePath: String,
        displayName: String,
        bookmarkData: Data? = nil,
        fileSize: Int64? = nil,
        missing: Bool = false,
        isReadOnlyReference: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.filePath = filePath
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.fileSize = fileSize
        self.missing = missing
        self.isReadOnlyReference = isReadOnlyReference
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(AttachmentKind.self, forKey: .kind) ?? .file
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? URL(fileURLWithPath: filePath).lastPathComponent
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        isReadOnlyReference = try container.decodeIfPresent(Bool.self, forKey: .isReadOnlyReference) ?? false
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    var url: URL {
        (try? resolvedURL()) ?? URL(fileURLWithPath: filePath)
    }

    func resolvedURL() throws -> URL {
        if let bookmarkData {
            var isStale = false
            let resolved = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return resolved
        }
        return URL(fileURLWithPath: filePath)
    }

    func withResolvedURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let resolved = try resolvedURL()
        let didAccess = resolved.startAccessingSecurityScopedResource()
        defer {
            if didAccess { resolved.stopAccessingSecurityScopedResource() }
        }
        return try body(resolved)
    }
}

enum AnnotationKind: String, Codable, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikeout
    case note
    case freeText
    case square
    case circle

    var id: String { rawValue }
}

struct ResearchAnnotation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var page: Int = 1
    var pageLabel: String = ""
    var kind: AnnotationKind = .highlight
    var colorHex: String = "#FFD166"
    var selectedText: String = ""
    var note: String = ""
    var bounds: CGRectCodable?
    var imageFilePath: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case page
        case pageLabel
        case kind
        case colorHex
        case selectedText
        case note
        case bounds
        case imageFilePath
        case createdAt
    }

    init(
        id: UUID = UUID(),
        page: Int = 1,
        pageLabel: String = "",
        kind: AnnotationKind = .highlight,
        colorHex: String = "#FFD166",
        selectedText: String = "",
        note: String = "",
        bounds: CGRectCodable? = nil,
        imageFilePath: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.page = page
        self.pageLabel = pageLabel
        self.kind = kind
        self.colorHex = colorHex
        self.selectedText = selectedText
        self.note = note
        self.bounds = bounds
        self.imageFilePath = imageFilePath
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pageLabel = try container.decodeIfPresent(String.self, forKey: .pageLabel) ?? ""
        kind = try container.decodeIfPresent(AnnotationKind.self, forKey: .kind) ?? .highlight
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFD166"
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        bounds = try container.decodeIfPresent(CGRectCodable.self, forKey: .bounds)
        imageFilePath = try container.decodeIfPresent(String.self, forKey: .imageFilePath)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

struct CGRectCodable: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CustomField: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var key: String
    var value: String
    var pinned: Bool = false
}

struct Paper: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var citekey: String = ""
    var title: String = ""
    var subtitle: String?
    var authors: [String] = []
    var editors: [String]?
    var translators: [String]?
    var year: Int?
    var paperType: PaperType = .article

    var journal: String = ""
    var bookTitle: String = ""
    var address: String?
    var publisher: String = ""
    var institution: String = ""
    var school: String = ""
    var series: String = ""
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var month: String = ""
    var doi: String = ""
    var isbn: String = ""
    var url: String = ""
    var urlDate: String?
    var language: String = ""
    var abstract: String = ""
    var notes: String = ""
    var event: String = ""
    var eventDate: String = ""
    var venue: String = ""
    var edition: String = ""
    var chapter: String = ""
    var type: String?
    var eprint: String = ""
    var eprintType: String = ""
    var eprintClass: String = ""
    var publicationState: String = ""
    var howPublished: String = ""
    var organization: String?

    var rating: Int = 0
    var collectionIDs: [UUID] = []
    var tagIDs: [UUID] = []
    var attachments: [Attachment] = []
    var annotations: [ResearchAnnotation] = []
    var customFields: [CustomField] = []
    var dateAdded: Date = Date()
    var dateModified: Date = Date()
    var lastOpenedAt: Date?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Paper" : title
    }

    var authorsText: String {
        get { authors.joined(separator: "; ") }
        set {
            authors = newValue
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    var editorsText: String {
        get { (editors ?? []).joined(separator: "; ") }
        set {
            let values = Self.splitNameList(newValue)
            editors = values.isEmpty ? nil : values
        }
    }

    var translatorsText: String {
        get { (translators ?? []).joined(separator: "; ") }
        set {
            let values = Self.splitNameList(newValue)
            translators = values.isEmpty ? nil : values
        }
    }

    var authorsDisplay: String {
        authors.isEmpty ? "No authors" : authors.joined(separator: ", ")
    }

    var sourceDisplay: String {
        if !journal.isEmpty { return journal }
        if !bookTitle.isEmpty { return bookTitle }
        if !publisher.isEmpty { return publisher }
        if !institution.isEmpty { return institution }
        if !url.isEmpty { return url }
        return ""
    }

    var hasPDF: Bool {
        attachments.contains { $0.kind == .pdf && !$0.missing }
    }

    var primaryPDF: Attachment? {
        attachments.first { $0.kind == .pdf }
    }

    var hasIdentifier: Bool {
        !doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !isbn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !eprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var arxivLookupID: String? {
        let cleanEprint = eprint.trimmed
        if eprintType.lowercased().contains("arxiv"), !cleanEprint.isEmpty {
            return cleanEprint
        }
        if cleanEprint.looksLikeArxivID {
            return cleanEprint
        }
        let normalizedDOI = doi.trimmed.lowercased()
        let prefix = "10.48550/arxiv."
        if normalizedDOI.hasPrefix(prefix) {
            return String(doi.trimmed.dropFirst(prefix.count)).nilIfBlank
        }
        return nil
    }

    private static func splitNameList(_ value: String) -> [String] {
        value
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func hasSameEditableContent(as other: Paper) -> Bool {
        var lhs = self
        var rhs = other
        lhs.dateModified = .distantPast
        rhs.dateModified = .distantPast
        return lhs == rhs
    }

    /// Commit only fields edited in the inspector. Native table operations may
    /// have changed other fields since the draft was loaded.
    func applyingEdits(to latest: Paper, from baseline: Paper) -> Paper {
        guard id == latest.id, id == baseline.id else { return latest }
        do {
            let encoder = JSONEncoder()
            let edited = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
            let original = try JSONSerialization.jsonObject(with: encoder.encode(baseline)) as! [String: Any]
            var merged = try JSONSerialization.jsonObject(with: encoder.encode(latest)) as! [String: Any]
            for key in Set(edited.keys).union(original.keys) where key != "id" && key != "dateModified" {
                let lhs = edited[key] as? NSObject
                let rhs = original[key] as? NSObject
                if lhs != rhs { merged[key] = edited[key] }
            }
            return try JSONDecoder().decode(Paper.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            return latest
        }
    }
}

struct PaperCollection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var parentID: UUID?
    var sortIndex: Int = 0
    var createdAt: Date = Date()
}

struct PaperTag: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String = "#5B8DEF"
    var sortIndex: Int = 0
    var createdAt: Date = Date()
}

enum LibraryFilter: Hashable, Codable {
    case all
    case recentlyAdded
    case recentlyOpened
    case unfiled
    case missingPDF
    case missingIDs
    case noTags
    case rating(Int)
    case collection(UUID)
    case tag(UUID)

    var title: String {
        switch self {
        case .all: return PMLocalization.text("全部文献")
        case .recentlyAdded: return PMLocalization.text("最近添加")
        case .recentlyOpened: return PMLocalization.text("最近打开")
        case .unfiled: return PMLocalization.text("未归类")
        case .missingPDF: return PMLocalization.text("缺少 PDF")
        case .missingIDs: return PMLocalization.text("缺少标识符")
        case .noTags: return PMLocalization.text("无标签")
        case .rating(let value): return value > 0 ? PMLocalization.format("%lld 星", value) : PMLocalization.text("未评分")
        case .collection: return PMLocalization.text("文集")
        case .tag: return PMLocalization.text("标签")
        }
    }
}

enum PaperSortField: String, Codable, CaseIterable, Identifiable {
    case title
    case authors
    case year
    case source
    case rating
    case dateAdded
    case lastOpened

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return PMLocalization.text("标题")
        case .authors: return PMLocalization.text("作者")
        case .year: return PMLocalization.text("年份")
        case .source: return PMLocalization.text("来源")
        case .rating: return PMLocalization.text("评分")
        case .dateAdded: return PMLocalization.text("添加日期")
        case .lastOpened: return PMLocalization.text("最近打开")
        }
    }
}

struct PaperSortDescriptor: Codable, Hashable {
    var field: PaperSortField = .dateAdded
    var ascending: Bool = false

    static let defaultValue = PaperSortDescriptor()
}

/// Matches the five observed fields of a Lattice 3.0 archive template.
/// Annotation formatting remains a separate global setting.
struct MetadataTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var content: String
    var isDefault: Bool = false
    var dateCreated: Date = Date()

    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

struct LibrarySnapshot: Codable {
    var schemaVersion: Int = 1
    var papers: [Paper] = []
    var collections: [PaperCollection] = []
    var tags: [PaperTag] = []
    var settings: AppSettings = .defaults
    var metadataTemplates: [MetadataTemplate]? = nil

    static let empty = LibrarySnapshot()
}
