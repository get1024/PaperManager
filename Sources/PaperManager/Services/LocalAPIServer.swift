import Combine
import Foundation
import Network

@MainActor
final class LocalAPIServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Disabled"

    private var listener: NWListener?
    private var activePort: Int?
    private let queue = DispatchQueue(label: "PaperManager.LocalAPI")

    func reconfigure(with store: LibraryStore) {
        let settings = store.settings
        guard settings.localAPIEnabled else {
            stop()
            statusText = "Disabled"
            return
        }
        if isRunning, activePort == settings.localAPIPort {
            statusText = "Listening on 127.0.0.1:\(settings.localAPIPort)"
            return
        }
        stop()
        start(port: settings.localAPIPort, store: store)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        isRunning = false
    }

    private func start(port: Int, store: LibraryStore) {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                statusText = "Invalid port"
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: nwPort)
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self, weak store] connection in
                guard let self, let store else { return }
                self.handle(connection: connection, store: store)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.activePort = port
                        self?.statusText = "Listening on 127.0.0.1:\(port)"
                    case .failed(let error):
                        self?.isRunning = false
                        self?.statusText = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            statusText = "Starting..."
        } catch {
            statusText = "Failed: \(error.localizedDescription)"
        }
    }

    private nonisolated func handle(connection: NWConnection, store: LibraryStore) {
        connection.start(queue: queue)
        receive(connection: connection, store: store, buffer: Data())
    }

    private nonisolated func receive(connection: NWConnection, store: LibraryStore, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            if let request = HTTPRequest(data: nextBuffer) {
                Task { @MainActor in
                    let response = await self.route(request, store: store)
                    self.send(response, on: connection)
                }
                return
            }

            if isComplete || error != nil {
                self.send(.plain(status: 400, text: "Bad Request"), on: connection)
            } else if nextBuffer.count > 220 * 1024 * 1024 {
                self.send(.plain(status: 413, text: "Payload too large"), on: connection)
            } else {
                self.receive(connection: connection, store: store, buffer: nextBuffer)
            }
        }
    }

    private nonisolated func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func route(_ request: HTTPRequest, store: LibraryStore) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return .plain(status: 204, text: "")
        }

        let path = request.path
        let isConnector = path.hasPrefix("/connector")
        let isPublicAPI = path.hasPrefix("/api/v1")

        if (isPublicAPI || isConnector), store.settings.localAPIReadOnly, request.method != "GET" {
            return .json(status: 403, object: ["error": "Read-Only Mode is enabled."])
        }
        if isConnector, path != "/connector/status", !store.settings.browserExtensionEnabled {
            return .json(status: 403, object: ["error": "Browser Extension is disabled."])
        }

        switch (request.method, path) {
        case ("GET", "/connector/status"), ("GET", "/api/v1/status"):
            return statusResponse(store: store)
        case ("GET", "/connector/collections"), ("GET", "/api/v1/collections"):
            return .json(object: ["collections": collectionsPayload(store: store)])
        case ("GET", "/connector/tags"), ("GET", "/api/v1/tags"):
            return .json(object: ["tags": tagsPayload(store: store)])
        case ("GET", "/connector/metadata"), ("GET", "/api/v1/metadata"):
            return await metadataResponse(request: request)
        case ("POST", "/connector/papers"), ("POST", "/api/v1/papers"):
            return await createPaperResponse(request: request, store: store)
        case ("GET", "/api/v1/papers"):
            return .json(object: ["papers": store.papers.map(lightweightPaperPayload)])
        default:
            if request.method == "PUT", path.hasPrefix("/connector/papers/"), path.hasSuffix("/pdf") {
                return uploadPDFResponse(request: request, store: store)
            }
            if request.method == "GET", path.hasPrefix("/api/v1/papers/") {
                let idPart = path.replacingOccurrences(of: "/api/v1/papers/", with: "")
                if let id = UUID(uuidString: idPart), let paper = store.paper(with: id) {
                    return .json(object: detailPayload(paper: paper, store: store))
                }
                return .json(status: 404, object: ["error": "Paper not found"])
            }
            return .json(status: 404, object: ["error": "Not found"])
        }
    }

    private func statusResponse(store: LibraryStore) -> HTTPResponse {
        let baseURL = "http://127.0.0.1:\(store.settings.localAPIPort)"
        return .json(object: [
            "ok": true,
            "apiVersion": "1",
            "serverVersion": "PaperManager 1.0",
            "appVersion": "PaperManager 1.0",
            "readOnly": store.settings.localAPIReadOnly,
            "browserExtensionEnabled": store.settings.browserExtensionEnabled,
            "baseURL": baseURL,
            "capabilities": [
                "papers",
                "collections",
                "tags",
                "metadata",
                "pdf-upload",
                "bibtex-export",
                "ris-export"
            ]
        ])
    }

    private func metadataResponse(request: HTTPRequest) async -> HTTPResponse {
        do {
            let metadata = try await MetadataLookupClient.lookup(
                doi: request.query["doi"],
                arxivID: request.query["arxivId"] ?? request.query["arxiv_id"],
                isbn: request.query["isbn"],
                title: request.query["title"]
            )
            return .json(object: metadataPayload(metadata))
        } catch {
            let status = error.localizedDescription.hasPrefix("Provide at least one") ? 400 : 404
            return .json(status: status, object: ["error": error.localizedDescription])
        }
    }

    private func createPaperResponse(request: HTTPRequest, store: LibraryStore) async -> HTTPResponse {
        do {
            let payload = try JSONDecoder().decode(CreatePaperPayload.self, from: request.body)
            var paper = payload.paper
            if payload.enrich == true, let metadata = try? await MetadataLookupClient.lookup(
                doi: paper.doi,
                arxivID: paper.eprint,
                isbn: paper.isbn,
                title: paper.title
            ) {
                paper = metadata.merged(into: paper)
            }

            for collectionName in payload.collections ?? [] {
                if let id = collectionID(forPath: collectionName, store: store) {
                    paper.collectionIDs.append(id)
                }
            }
            for tagName in payload.tags ?? [] {
                if let id = tagID(named: tagName, store: store) {
                    paper.tagIDs.append(id)
                }
            }

            if let duplicateID = store.duplicatePaperID(for: paper), payload.strategy != "replace" {
                let existing = store.paper(with: duplicateID)
                return .json(status: 409, object: [
                    "error": "Duplicate paper.",
                    "existingPaperID": duplicateID.uuidString,
                    "existingTitle": existing?.displayTitle ?? "",
                    "conflictField": paper.doi.isEmpty ? "title" : "doi",
                    "paperManagerURL": "papermanager://paper/\(duplicateID.uuidString)",
                    "latticeURL": "papermanager://paper/\(duplicateID.uuidString)"
                ])
            }

            let id = store.addOrReplacePaper(paper, replaceDuplicate: payload.strategy == "replace")
            let saved = store.paper(with: id) ?? paper
            return .json(object: [
                "id": id.uuidString,
                "title": saved.displayTitle,
                "authors": saved.authorsText,
                "year": saved.year as Any,
                "doi": saved.doi,
                "pdfAttached": saved.hasPDF,
                "enrichmentStatus": payload.enrich == true ? "attempted" : "none",
                "warnings": [],
                "paperManagerURL": "papermanager://paper/\(id.uuidString)",
                "latticeURL": "papermanager://paper/\(id.uuidString)"
            ])
        } catch {
            return .json(status: 400, object: ["error": error.localizedDescription])
        }
    }

    private func uploadPDFResponse(request: HTTPRequest, store: LibraryStore) -> HTTPResponse {
        guard request.body.count <= 200 * 1024 * 1024 else {
            return .json(status: 413, object: ["error": "PDF exceeds the 200MB upload limit."])
        }
        let path = request.path
        let stripped = path
            .replacingOccurrences(of: "/connector/papers/", with: "")
            .replacingOccurrences(of: "/pdf", with: "")
        guard let id = UUID(uuidString: stripped), let paper = store.paper(with: id) else {
            return .json(status: 404, object: ["error": "Paper not found"])
        }

        let folderPath = store.settings.browserUploadFolder.nilIfBlank ?? store.settings.pdfOrganizationFolder
        guard let folderPath = folderPath.nilIfBlank else {
            return .json(status: 503, object: ["error": "PaperManager is not configured to accept PDF uploads."])
        }

        do {
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let baseName = (paper.citekey.nilIfBlank ?? paper.displayTitle).sanitizedFileName()
            var url = folder.appendingPathComponent(baseName).appendingPathExtension("pdf")
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension("pdf")
                suffix += 1
            }
            try request.body.write(to: url, options: [.atomic])
            try store.attachFile(url, to: id, kind: .pdf)
            return .json(object: ["ok": true, "id": id.uuidString, "pdfAttached": true])
        } catch {
            return .json(status: 500, object: ["error": error.localizedDescription])
        }
    }

    private func collectionID(forPath path: String, store: LibraryStore) -> UUID? {
        let parts = path.split(separator: "/").map { String($0).trimmed }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var parentID: UUID?
        var currentID: UUID?
        for part in parts {
            if let existing = store.collections.first(where: { $0.parentID == parentID && $0.name == part }) {
                currentID = existing.id
                parentID = existing.id
            } else {
                let newID = store.addCollection(name: part, parentID: parentID)
                currentID = newID
                parentID = newID
            }
        }
        return currentID
    }

    private func tagID(named name: String, store: LibraryStore) -> UUID? {
        let clean = name.trimmed
        guard !clean.isEmpty else { return nil }
        if let existing = store.tags.first(where: { $0.name == clean }) {
            return existing.id
        }
        return store.addTag(name: clean)
    }

    private func collectionsPayload(store: LibraryStore) -> [[String: Any]] {
        store.collections.map { collection in
            let path = store.collections.path(for: collection.id)
            return [
                "id": collection.id.uuidString,
                "name": collection.name,
                "parentID": collection.parentID?.uuidString as Any,
                "path": path,
                "depth": max(path.split(separator: "/").count - 1, 0)
            ]
        }
    }

    private func tagsPayload(store: LibraryStore) -> [[String: Any]] {
        store.tags.map { tag in
            [
                "id": tag.id.uuidString,
                "name": tag.name,
                "color": tag.colorHex,
                "colorHex": tag.colorHex
            ]
        }
    }

    private func lightweightPaperPayload(_ paper: Paper) -> [String: Any] {
        [
            "id": paper.id.uuidString,
            "citekey": paper.citekey,
            "title": paper.displayTitle,
            "subtitle": [paper.authorsDisplay, paper.year.map(String.init) ?? "", paper.sourceDisplay]
                .filter { !$0.isEmpty && $0 != "No authors" }
                .joined(separator: ", "),
            "authors": paper.authors,
            "year": paper.year as Any,
            "source": paper.sourceDisplay,
            "doi": paper.doi,
            "url": paper.url,
            "pdfAttached": paper.hasPDF,
            "paperManagerURL": "papermanager://paper/\(paper.id.uuidString)",
            "latticeURL": "papermanager://paper/\(paper.id.uuidString)"
        ]
    }

    private func detailPayload(paper: Paper, store: LibraryStore) -> [String: Any] {
        var payload = lightweightPaperPayload(paper)
        payload["type"] = paper.paperType.rawValue
        payload["paperType"] = paper.paperType.rawValue
        payload["subtitle"] = paper.subtitle ?? ""
        payload["editors"] = paper.editors ?? []
        payload["translators"] = paper.translators ?? []
        payload["abstract"] = paper.abstract
        payload["notes"] = paper.notes
        payload["rating"] = paper.rating
        payload["dateAdded"] = paper.dateAdded
        payload["csl"] = metadataPayload(PaperMetadata(
            title: paper.title,
            subtitle: paper.subtitle ?? "",
            authors: paper.authors,
            editors: paper.editors ?? [],
            translators: paper.translators ?? [],
            year: paper.year,
            paperType: paper.paperType,
            journal: paper.journal,
            bookTitle: paper.bookTitle,
            publisher: paper.publisher,
            address: paper.address ?? "",
            volume: paper.volume,
            issue: paper.issue,
            pages: paper.pages,
            doi: paper.doi,
            isbn: paper.isbn,
            url: paper.url,
            urlDate: paper.urlDate ?? "",
            abstract: paper.abstract,
            edition: paper.edition,
            series: paper.series,
            chapter: paper.chapter,
            institution: paper.institution,
            school: paper.school,
            type: paper.type ?? "",
            howPublished: paper.howPublished,
            organization: paper.organization ?? "",
            language: paper.language,
            month: paper.month,
            eprint: paper.eprint,
            eprintType: paper.eprintType,
            eprintClass: paper.eprintClass,
            publicationState: paper.publicationState,
            eventTitle: paper.event,
            eventDate: paper.eventDate,
            venue: paper.venue
        ))
        payload["collections"] = paper.collectionIDs.map { store.collections.path(for: $0) }
        payload["tags"] = paper.tagIDs.compactMap { id in store.tags.first(where: { $0.id == id })?.name }
        return payload
    }

    private func metadataPayload(_ metadata: PaperMetadata) -> [String: Any] {
        [
            "title": metadata.title,
            "subtitle": metadata.subtitle,
            "authors": metadata.authors,
            "editors": metadata.editors,
            "translators": metadata.translators,
            "year": metadata.year as Any,
            "journal": metadata.journal,
            "bookTitle": metadata.bookTitle,
            "booktitle": metadata.bookTitle,
            "abstract": metadata.abstract,
            "doi": metadata.doi,
            "volume": metadata.volume,
            "issue": metadata.issue,
            "pages": metadata.pages,
            "isbn": metadata.isbn,
            "url": metadata.url,
            "urlDate": metadata.urlDate,
            "paperType": metadata.paperType.rawValue,
            "type": metadata.paperType.rawValue,
            "bibtexType": metadata.type,
            "publisher": metadata.publisher,
            "address": metadata.address,
            "edition": metadata.edition,
            "series": metadata.series,
            "chapter": metadata.chapter,
            "institution": metadata.institution,
            "school": metadata.school,
            "howpublished": metadata.howPublished,
            "organization": metadata.organization,
            "language": metadata.language,
            "month": metadata.month,
            "eprint": metadata.eprint,
            "eprintType": metadata.eprintType,
            "eprintClass": metadata.eprintClass,
            "pubState": metadata.publicationState,
            "eventTitle": metadata.eventTitle,
            "eventDate": metadata.eventDate,
            "venue": metadata.venue
        ]
    }
}

private struct CreatePaperPayload: Decodable {
    var title: String
    var subtitle: String?
    var authors: String?
    var editors: String?
    var translators: String?
    var year: Int?
    var journal: String?
    var bookTitle: String?
    var booktitle: String?
    var abstract: String?
    var doi: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var isbn: String?
    var url: String?
    var urlDate: String?
    var paperType: String?
    var publisher: String?
    var address: String?
    var edition: String?
    var series: String?
    var chapter: String?
    var institution: String?
    var school: String?
    var type: String?
    var howpublished: String?
    var howPublished: String?
    var organization: String?
    var language: String?
    var month: String?
    var eprint: String?
    var eprintType: String?
    var eprintClass: String?
    var pubState: String?
    var publicationState: String?
    var eventTitle: String?
    var event: String?
    var eventDate: String?
    var venue: String?
    var notes: String?
    var collections: [String]?
    var tags: [String]?
    var enrich: Bool?
    var strategy: String?

    var paper: Paper {
        var paper = Paper()
        paper.title = title
        paper.subtitle = subtitle?.nilIfBlank
        paper.authorsText = authors ?? ""
        paper.editorsText = editors ?? ""
        paper.translatorsText = translators ?? ""
        paper.year = year
        paper.journal = journal ?? ""
        paper.bookTitle = bookTitle ?? booktitle ?? ""
        paper.abstract = abstract ?? ""
        paper.doi = doi ?? ""
        paper.volume = volume ?? ""
        paper.issue = issue ?? ""
        paper.pages = pages ?? ""
        paper.isbn = isbn ?? ""
        paper.url = url ?? ""
        paper.urlDate = urlDate?.nilIfBlank
        paper.publisher = publisher ?? ""
        paper.address = address?.nilIfBlank
        paper.edition = edition ?? ""
        paper.series = series ?? ""
        paper.chapter = chapter ?? ""
        paper.institution = institution ?? ""
        paper.school = school ?? ""
        paper.type = type?.nilIfBlank
        paper.howPublished = howPublished ?? howpublished ?? ""
        paper.organization = organization?.nilIfBlank
        paper.language = language ?? ""
        paper.month = month ?? ""
        paper.eprint = eprint ?? ""
        paper.eprintType = eprintType ?? ""
        paper.eprintClass = eprintClass ?? ""
        paper.publicationState = publicationState ?? pubState ?? ""
        paper.event = eventTitle ?? event ?? ""
        paper.eventDate = eventDate ?? ""
        paper.venue = venue ?? ""
        paper.notes = notes ?? ""
        if let paperType {
            paper.paperType = PaperType(rawValue: paperType) ?? PaperType.fromBibTeX(paperType)
        }
        return paper
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmed
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let expectedLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - bodyStart >= expectedLength else { return nil }

        method = String(requestParts[0])
        let rawTarget = String(requestParts[1])
        let components = URLComponents(string: "http://127.0.0.1\(rawTarget)")
        path = components?.path ?? rawTarget
        query = Dictionary(uniqueKeysWithValues: components?.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + expectedLength))
    }
}

private struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    var data: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    static func json(status: Int = 200, object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: sanitizeJSON(object), options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    static func plain(status: Int = 200, text: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private static func sanitizeJSON(_ value: Any) -> Any {
        switch value {
        case Optional<Any>.none:
            return NSNull()
        case let value as [String: Any]:
            return value.mapValues(sanitizeJSON)
        case let value as [[String: Any]]:
            return value.map { sanitizeJSON($0) }
        case let value as [Any]:
            return value.map(sanitizeJSON)
        case let value as UUID:
            return value.uuidString
        case let value as Date:
            return ISO8601DateFormatter().string(from: value)
        case let value as Int:
            return value
        case let value as Bool:
            return value
        case let value as Double:
            return value
        case let value as String:
            return value
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let child = mirror.children.first {
                    return sanitizeJSON(child.value)
                }
                return NSNull()
            }
            return "\(value)"
        }
    }
}
