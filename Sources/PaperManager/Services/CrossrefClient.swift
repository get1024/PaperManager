import Foundation

struct PaperMetadata: Codable, Hashable {
    var title: String = ""
    var subtitle: String = ""
    var authors: [String] = []
    var editors: [String] = []
    var translators: [String] = []
    var year: Int?
    var paperType: PaperType = .article
    var journal: String = ""
    var bookTitle: String = ""
    var publisher: String = ""
    var address: String = ""
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var doi: String = ""
    var isbn: String = ""
    var url: String = ""
    var urlDate: String = ""
    var abstract: String = ""
    var edition: String = ""
    var series: String = ""
    var chapter: String = ""
    var institution: String = ""
    var school: String = ""
    var type: String = ""
    var howPublished: String = ""
    var organization: String = ""
    var language: String = ""
    var month: String = ""
    var eprint: String = ""
    var eprintType: String = ""
    var eprintClass: String = ""
    var publicationState: String = ""
    var eventTitle: String = ""
    var eventDate: String = ""
    var venue: String = ""

    func merged(into paper: Paper, replaceExisting: Bool = false) -> Paper {
        var result = paper
        if shouldFill(result.title, with: title, replaceExisting: replaceExisting) { result.title = title }
        if shouldFill(result.subtitle ?? "", with: subtitle, replaceExisting: replaceExisting) { result.subtitle = subtitle.nilIfBlank }
        if (replaceExisting || result.authors.isEmpty), !authors.isEmpty { result.authors = authors }
        if (replaceExisting || (result.editors ?? []).isEmpty), !editors.isEmpty { result.editors = editors }
        if (replaceExisting || (result.translators ?? []).isEmpty), !translators.isEmpty { result.translators = translators }
        if (replaceExisting || result.year == nil), let year { result.year = year }
        if shouldFill(result.journal, with: journal, replaceExisting: replaceExisting) { result.journal = journal }
        if shouldFill(result.bookTitle, with: bookTitle, replaceExisting: replaceExisting) { result.bookTitle = bookTitle }
        if shouldFill(result.publisher, with: publisher, replaceExisting: replaceExisting) { result.publisher = publisher }
        if shouldFill(result.address ?? "", with: address, replaceExisting: replaceExisting) { result.address = address.nilIfBlank }
        if shouldFill(result.volume, with: volume, replaceExisting: replaceExisting) { result.volume = volume }
        if shouldFill(result.issue, with: issue, replaceExisting: replaceExisting) { result.issue = issue }
        if shouldFill(result.pages, with: pages, replaceExisting: replaceExisting) { result.pages = pages }
        if shouldFill(result.doi, with: doi, replaceExisting: replaceExisting) { result.doi = doi }
        if shouldFill(result.isbn, with: isbn, replaceExisting: replaceExisting) { result.isbn = isbn }
        if shouldFill(result.url, with: url, replaceExisting: replaceExisting) { result.url = url }
        if shouldFill(result.urlDate ?? "", with: urlDate, replaceExisting: replaceExisting) { result.urlDate = urlDate.nilIfBlank }
        if shouldFill(result.abstract, with: abstract, replaceExisting: replaceExisting) { result.abstract = abstract }
        if shouldFill(result.edition, with: edition, replaceExisting: replaceExisting) { result.edition = edition }
        if shouldFill(result.series, with: series, replaceExisting: replaceExisting) { result.series = series }
        if shouldFill(result.chapter, with: chapter, replaceExisting: replaceExisting) { result.chapter = chapter }
        if shouldFill(result.institution, with: institution, replaceExisting: replaceExisting) { result.institution = institution }
        if shouldFill(result.school, with: school, replaceExisting: replaceExisting) { result.school = school }
        if shouldFill(result.type ?? "", with: type, replaceExisting: replaceExisting) { result.type = type.nilIfBlank }
        if shouldFill(result.howPublished, with: howPublished, replaceExisting: replaceExisting) { result.howPublished = howPublished }
        if shouldFill(result.organization ?? "", with: organization, replaceExisting: replaceExisting) { result.organization = organization.nilIfBlank }
        if shouldFill(result.language, with: language, replaceExisting: replaceExisting) { result.language = language }
        if shouldFill(result.month, with: month, replaceExisting: replaceExisting) { result.month = month }
        if shouldFill(result.eprint, with: eprint, replaceExisting: replaceExisting) { result.eprint = eprint }
        if shouldFill(result.eprintType, with: eprintType, replaceExisting: replaceExisting) { result.eprintType = eprintType }
        if shouldFill(result.eprintClass, with: eprintClass, replaceExisting: replaceExisting) { result.eprintClass = eprintClass }
        if shouldFill(result.publicationState, with: publicationState, replaceExisting: replaceExisting) { result.publicationState = publicationState }
        if shouldFill(result.event, with: eventTitle, replaceExisting: replaceExisting) { result.event = eventTitle }
        if shouldFill(result.eventDate, with: eventDate, replaceExisting: replaceExisting) { result.eventDate = eventDate }
        if shouldFill(result.venue, with: venue, replaceExisting: replaceExisting) { result.venue = venue }
        if replaceExisting || result.paperType == .misc {
            result.paperType = paperType
        }
        return result
    }

    private func shouldFill(_ current: String, with incoming: String, replaceExisting: Bool) -> Bool {
        !incoming.trimmed.isEmpty && (replaceExisting || current.trimmed.isEmpty)
    }

    var asPaper: Paper {
        var paper = Paper()
        paper.title = title
        paper.subtitle = subtitle.nilIfBlank
        paper.authors = authors
        paper.editors = editors.isEmpty ? nil : editors
        paper.translators = translators.isEmpty ? nil : translators
        paper.year = year
        paper.paperType = paperType
        paper.journal = journal
        paper.bookTitle = bookTitle
        paper.address = address.nilIfBlank
        paper.publisher = publisher
        paper.volume = volume
        paper.issue = issue
        paper.pages = pages
        paper.doi = doi
        paper.isbn = isbn
        paper.url = url
        paper.urlDate = urlDate.nilIfBlank
        paper.abstract = abstract
        paper.edition = edition
        paper.series = series
        paper.chapter = chapter
        paper.institution = institution
        paper.school = school
        paper.type = type.nilIfBlank
        paper.howPublished = howPublished
        paper.organization = organization.nilIfBlank
        paper.language = language
        paper.month = month
        paper.eprint = eprint
        paper.eprintType = eprintType
        paper.eprintClass = eprintClass
        paper.publicationState = publicationState
        paper.event = eventTitle
        paper.eventDate = eventDate
        paper.venue = venue
        return paper
    }
}

enum MetadataLookupClient {
    static func lookup(doi: String?, arxivID: String?, isbn: String?, title: String?) async throws -> PaperMetadata {
        if let doi = doi?.nilIfBlank {
            return try await CrossrefClient.fetch(doi: doi)
        }
        if let arxivID = arxivID?.nilIfBlank {
            return try await ArxivClient.fetch(arxivID: arxivID)
        }
        if let isbn = isbn?.nilIfBlank {
            return try await OpenLibraryClient.fetch(isbn: isbn)
        }
        if let title = title?.nilIfBlank {
            return try await CrossrefClient.search(bibliographicQuery: title)
        }
        throw PaperManagerError.message("Provide at least one of DOI, arXiv ID, ISBN, or title.")
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

    static func search(bibliographicQuery query: String) async throws -> PaperMetadata {
        guard !query.trimmed.isEmpty,
              var components = URLComponents(string: "https://api.crossref.org/works") else {
            throw PaperManagerError.message("Enter a title or bibliographic query.")
        }
        components.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query.trimmed),
            URLQueryItem(name: "rows", value: "1")
        ]
        guard let url = components.url else {
            throw PaperManagerError.message("Invalid metadata query.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("PaperManager/1.0 (mailto:unknown@example.com)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PaperManagerError.message("No paper found for this query.")
        }
        let decoded = try JSONDecoder().decode(CrossrefSearchResponse.self, from: data)
        guard let metadata = decoded.message.items.first?.metadata else {
            throw PaperManagerError.message("No paper found for this query.")
        }
        return metadata
    }
}

private struct CrossrefResponse: Decodable {
    let message: CrossrefWork
}

private struct CrossrefSearchResponse: Decodable {
    struct Message: Decodable {
        var items: [CrossrefWork]
    }

    let message: Message
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
    var subtitle: [String]?
    var author: [Author]?
    var editor: [Author]?
    var translator: [Author]?
    var issued: DateParts?
    var publishedPrint: DateParts?
    var publishedOnline: DateParts?
    var posted: DateParts?
    var containerTitle: [String]?
    var publisher: String?
    var publisherLocation: String?
    var volume: String?
    var issue: String?
    var page: String?
    var DOI: String?
    var ISBN: [String]?
    var ISSN: [String]?
    var URL: String?
    var abstract: String?
    var type: String?
    var subtype: String?
    var language: String?
    var archive: [String]?
    var event: Event?
    var institution: [Institution]?
    var resource: Resource?

    struct Event: Decodable {
        var name: String?
        var location: String?
        var start: DateParts?
    }

    struct Institution: Decodable {
        var name: String?
    }

    struct Resource: Decodable {
        var primary: Primary?

        struct Primary: Decodable {
            var URL: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case author
        case editor
        case translator
        case issued
        case publishedPrint = "published-print"
        case publishedOnline = "published-online"
        case posted
        case containerTitle = "container-title"
        case publisher
        case publisherLocation = "publisher-location"
        case volume
        case issue
        case page
        case DOI
        case ISBN
        case ISSN
        case URL
        case abstract
        case type
        case subtype
        case language
        case archive
        case event
        case institution
        case resource
    }

    var metadata: PaperMetadata {
        var metadata = PaperMetadata()
        metadata.title = title?.first?.strippingSimpleHTML() ?? ""
        metadata.subtitle = subtitle?.first?.strippingSimpleHTML() ?? ""
        metadata.authors = names(author)
        metadata.editors = names(editor)
        metadata.translators = names(translator)
        metadata.year = issued?.dateParts.first?.first ?? publishedPrint?.dateParts.first?.first ?? publishedOnline?.dateParts.first?.first ?? posted?.dateParts.first?.first
        metadata.journal = containerTitle?.first ?? ""
        if paperType == .inBook || paperType == .inProceedings || paperType == .proceedings {
            metadata.bookTitle = containerTitle?.first ?? ""
        }
        metadata.publisher = publisher ?? ""
        metadata.address = publisherLocation ?? ""
        metadata.volume = volume ?? ""
        metadata.issue = issue ?? ""
        metadata.pages = page ?? ""
        metadata.doi = DOI ?? ""
        metadata.isbn = ISBN?.first ?? ISSN?.first ?? ""
        metadata.url = URL ?? resource?.primary?.URL ?? ""
        metadata.abstract = abstract?.strippingSimpleHTML() ?? ""
        metadata.type = subtype ?? type ?? ""
        metadata.language = language ?? ""
        metadata.eprint = archive?.first ?? ""
        metadata.eventTitle = event?.name ?? ""
        metadata.eventDate = event?.start?.dateParts.first?.map(String.init).joined(separator: "-") ?? ""
        metadata.venue = event?.location ?? ""
        metadata.institution = institution?.compactMap(\.name).first ?? ""
        metadata.paperType = paperType
        return metadata
    }

    private func names(_ people: [Author]?) -> [String] {
        people?.compactMap { author in
            if let name = author.name?.trimmed, !name.isEmpty { return name }
            let given = author.given?.trimmed ?? ""
            let family = author.family?.trimmed ?? ""
            return [family, given].filter { !$0.isEmpty }.joined(separator: ", ")
        }.filter { !$0.isEmpty } ?? []
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

private enum ArxivClient {
    static func fetch(arxivID: String) async throws -> PaperMetadata {
        let cleanID = arxivID
            .trimmed
            .replacingOccurrences(of: #"(?i)^arxiv:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.pdf$"#, with: "", options: .regularExpression)
        guard !cleanID.isEmpty,
              var components = URLComponents(string: "https://export.arxiv.org/api/query") else {
            throw PaperManagerError.message("Enter an arXiv ID.")
        }
        components.queryItems = [URLQueryItem(name: "id_list", value: cleanID)]
        guard let url = components.url else {
            throw PaperManagerError.message("Invalid arXiv ID.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("PaperManager/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PaperManagerError.message("No paper found for this arXiv ID.")
        }

        let parser = XMLParser(data: data)
        let delegate = ArxivParserDelegate(requestedID: cleanID)
        parser.delegate = delegate
        guard parser.parse(), var metadata = delegate.metadata else {
            throw PaperManagerError.message("No paper found for this arXiv ID.")
        }
        metadata.paperType = .preprint
        metadata.journal = "arXiv"
        metadata.eprint = cleanID
        metadata.eprintType = "arxiv"
        metadata.url = metadata.url.nilIfBlank ?? "https://arxiv.org/abs/\(cleanID)"
        let versionlessID = cleanID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        if metadata.doi.trimmed.isEmpty {
            metadata.doi = "10.48550/arXiv.\(versionlessID)"
        }
        return metadata
    }
}

private final class ArxivParserDelegate: NSObject, XMLParserDelegate {
    private let requestedID: String
    private var inEntry = false
    private var inAuthor = false
    private var currentElement = ""
    private var buffer = ""
    private var title = ""
    private var summary = ""
    private var published = ""
    private var entryID = ""
    private var doi = ""
    private var authors: [String] = []

    var metadata: PaperMetadata?

    init(requestedID: String) {
        self.requestedID = requestedID
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = qName ?? elementName
        currentElement = name
        buffer = ""
        if name == "entry" {
            inEntry = true
        } else if inEntry, name == "author" {
            inAuthor = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let value = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        defer {
            buffer = ""
            currentElement = ""
        }
        guard inEntry else { return }

        switch name {
        case "title":
            title = value
        case "summary":
            summary = value
        case "published":
            published = value
        case "id":
            entryID = value
        case "arxiv:doi", "doi":
            doi = value
        case "name" where inAuthor:
            if !value.isEmpty { authors.append(value) }
        case "author":
            inAuthor = false
        case "entry":
            inEntry = false
            var result = PaperMetadata()
            result.title = title
            result.authors = authors
            result.abstract = summary
            result.url = entryID.nilIfBlank ?? "https://arxiv.org/abs/\(requestedID)"
            result.doi = doi
            result.year = Int(published.prefix(4))
            metadata = result
        default:
            break
        }
    }
}

private enum OpenLibraryClient {
    static func fetch(isbn: String) async throws -> PaperMetadata {
        let cleanISBN = isbn.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression)
        guard !cleanISBN.isEmpty,
              var components = URLComponents(string: "https://openlibrary.org/search.json") else {
            throw PaperManagerError.message("Enter an ISBN.")
        }
        components.queryItems = [
            URLQueryItem(name: "isbn", value: cleanISBN),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            throw PaperManagerError.message("Invalid ISBN.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("PaperManager/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PaperManagerError.message("No book found for this ISBN.")
        }
        let decoded = try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data)
        guard let doc = decoded.docs.first else {
            throw PaperManagerError.message("No book found for this ISBN.")
        }
        var metadata = PaperMetadata()
        metadata.paperType = .book
        metadata.title = doc.title ?? ""
        metadata.subtitle = doc.subtitle ?? ""
        metadata.authors = doc.authorName ?? []
        metadata.year = doc.firstPublishYear
        metadata.publisher = doc.publisher?.first ?? ""
        metadata.isbn = cleanISBN
        metadata.language = doc.language?.first ?? ""
        metadata.url = "https://openlibrary.org/isbn/\(cleanISBN)"
        return metadata
    }
}

private struct OpenLibrarySearchResponse: Decodable {
    struct Document: Decodable {
        var title: String?
        var subtitle: String?
        var authorName: [String]?
        var firstPublishYear: Int?
        var publisher: [String]?
        var language: [String]?

        enum CodingKeys: String, CodingKey {
            case title
            case subtitle
            case authorName = "author_name"
            case firstPublishYear = "first_publish_year"
            case publisher
            case language
        }
    }

    var docs: [Document]
}
