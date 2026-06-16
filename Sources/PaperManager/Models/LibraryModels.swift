import Foundation

enum PaperType: String, Codable, CaseIterable, Identifiable {
    case article
    case book
    case inBook
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
        case .article: return "Journal Article"
        case .book: return "Book"
        case .inBook: return "Book Section"
        case .inProceedings: return "Conference Paper"
        case .proceedings: return "Proceedings"
        case .thesis: return "Thesis"
        case .preprint: return "Preprint"
        case .report: return "Report"
        case .patent: return "Patent"
        case .dataset: return "Dataset"
        case .software: return "Software"
        case .online: return "Online Resource"
        case .manuscript: return "Manuscript"
        case .misc: return "Misc"
        }
    }

    var bibTeXType: String {
        switch self {
        case .article: return "article"
        case .book: return "book"
        case .inBook: return "inbook"
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
        case .inBook: return "CHAP"
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
        case "inbook", "incollection": return .inBook
        case "inproceedings", "conference": return .inProceedings
        case "proceedings": return .proceedings
        case "phdthesis", "mastersthesis": return .thesis
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
    var addedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case filePath
        case displayName
        case bookmarkData
        case fileSize
        case missing
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
        addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.filePath = filePath
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.fileSize = fileSize
        self.missing = missing
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
    case unfiled
    case missingPDF
    case missingIDs
    case noTags
    case collection(UUID)
    case tag(UUID)

    var title: String {
        switch self {
        case .all: return "全部文献"
        case .unfiled: return "未归类"
        case .missingPDF: return "缺少 PDF"
        case .missingIDs: return "缺少 DOI"
        case .noTags: return "无标签"
        case .collection: return "文集"
        case .tag: return "标签"
        }
    }
}

struct LibrarySnapshot: Codable {
    var schemaVersion: Int = 1
    var papers: [Paper] = []
    var collections: [PaperCollection] = []
    var tags: [PaperTag] = []
    var settings: AppSettings = .defaults

    static let empty = LibrarySnapshot()
}
