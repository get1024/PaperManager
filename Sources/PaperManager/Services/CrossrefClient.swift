import Foundation

struct PaperMetadata: Codable, Hashable {
    var title: String = ""
    var authors: [String] = []
    var year: Int?
    var paperType: PaperType = .article
    var journal: String = ""
    var publisher: String = ""
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var doi: String = ""
    var isbn: String = ""
    var url: String = ""
    var abstract: String = ""

    func merged(into paper: Paper) -> Paper {
        var result = paper
        if result.title.trimmed.isEmpty, !title.isEmpty { result.title = title }
        if result.authors.isEmpty, !authors.isEmpty { result.authors = authors }
        if result.year == nil { result.year = year }
        if result.journal.trimmed.isEmpty { result.journal = journal }
        if result.publisher.trimmed.isEmpty { result.publisher = publisher }
        if result.volume.trimmed.isEmpty { result.volume = volume }
        if result.issue.trimmed.isEmpty { result.issue = issue }
        if result.pages.trimmed.isEmpty { result.pages = pages }
        if result.doi.trimmed.isEmpty { result.doi = doi }
        if result.isbn.trimmed.isEmpty { result.isbn = isbn }
        if result.url.trimmed.isEmpty { result.url = url }
        if result.abstract.trimmed.isEmpty { result.abstract = abstract }
        result.paperType = paperType
        return result
    }

    var asPaper: Paper {
        var paper = Paper()
        paper.title = title
        paper.authors = authors
        paper.year = year
        paper.paperType = paperType
        paper.journal = journal
        paper.publisher = publisher
        paper.volume = volume
        paper.issue = issue
        paper.pages = pages
        paper.doi = doi
        paper.isbn = isbn
        paper.url = url
        paper.abstract = abstract
        return paper
    }
}

enum CrossrefClient {
    static func fetch(doi: String) async throws -> PaperMetadata {
        let cleaned = doi
            .trimmed
            .replacingOccurrences(of: "https://doi.org/", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "http://doi.org/", with: "", options: [.caseInsensitive])
        guard !cleaned.isEmpty,
              let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)") else {
            throw PaperManagerError.message("Enter a DOI.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("PaperManager/1.0 (mailto:unknown@example.com)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PaperManagerError.message("No paper found for this DOI.")
        }
        return try JSONDecoder().decode(CrossrefResponse.self, from: data).message.metadata
    }
}

private struct CrossrefResponse: Decodable {
    let message: CrossrefWork
}

private struct CrossrefWork: Decodable {
    struct Author: Decodable {
        var given: String?
        var family: String?
        var name: String?
    }

    struct DateParts: Decodable {
        var dateParts: [[Int]]

        enum CodingKeys: String, CodingKey {
            case dateParts = "date-parts"
        }
    }

    var title: [String]?
    var author: [Author]?
    var issued: DateParts?
    var publishedPrint: DateParts?
    var publishedOnline: DateParts?
    var containerTitle: [String]?
    var publisher: String?
    var volume: String?
    var issue: String?
    var page: String?
    var DOI: String?
    var ISBN: [String]?
    var ISSN: [String]?
    var URL: String?
    var abstract: String?
    var type: String?

    enum CodingKeys: String, CodingKey {
        case title
        case author
        case issued
        case publishedPrint = "published-print"
        case publishedOnline = "published-online"
        case containerTitle = "container-title"
        case publisher
        case volume
        case issue
        case page
        case DOI
        case ISBN
        case ISSN
        case URL
        case abstract
        case type
    }

    var metadata: PaperMetadata {
        var metadata = PaperMetadata()
        metadata.title = title?.first?.strippingSimpleHTML() ?? ""
        metadata.authors = author?.compactMap { author in
            if let name = author.name?.trimmed, !name.isEmpty { return name }
            let given = author.given?.trimmed ?? ""
            let family = author.family?.trimmed ?? ""
            return [family, given].filter { !$0.isEmpty }.joined(separator: ", ")
        }.filter { !$0.isEmpty } ?? []
        metadata.year = issued?.dateParts.first?.first ?? publishedPrint?.dateParts.first?.first ?? publishedOnline?.dateParts.first?.first
        metadata.journal = containerTitle?.first ?? ""
        metadata.publisher = publisher ?? ""
        metadata.volume = volume ?? ""
        metadata.issue = issue ?? ""
        metadata.pages = page ?? ""
        metadata.doi = DOI ?? ""
        metadata.isbn = ISBN?.first ?? ISSN?.first ?? ""
        metadata.url = URL ?? ""
        metadata.abstract = abstract?.strippingSimpleHTML() ?? ""
        metadata.paperType = paperType
        return metadata
    }

    private var paperType: PaperType {
        switch type?.lowercased() {
        case "journal-article": return .article
        case "book": return .book
        case "book-chapter": return .inBook
        case "proceedings-article": return .inProceedings
        case "proceedings": return .proceedings
        case "posted-content": return .preprint
        case "report": return .report
        case "dataset": return .dataset
        default: return .misc
        }
    }
}
