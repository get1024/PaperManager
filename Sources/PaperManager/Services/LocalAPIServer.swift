import Combine
import Foundation
import Network
import PDFKit

/// Cancelling an API request removes a queued waiter without consuming a
/// provider slot. Active providers retain their slot until they actually finish.
private actor APIEnrichmentLimiter {
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func run<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < 3 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
}

@MainActor
final class LocalAPIServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Disabled"

    private var listener: NWListener?
    private var activePort: Int?
    private var listenerGeneration: UUID?
    private weak var boundStore: LibraryStore?
    private var connections: [UUID: NWConnection] = [:]
    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    private var enrichmentGenerations: [UUID: UUID] = [:]
    private let metadataLookup: (Paper) async throws -> PaperMetadata
    private let enrichmentLimiter = APIEnrichmentLimiter()
    private let queue = DispatchQueue(label: "PaperManager.LocalAPI")

    init(metadataLookup: @escaping (Paper) async throws -> PaperMetadata = { paper in
        try await MetadataLookupClient.lookup(doi: paper.doi.nilIfBlank, arxivID: paper.arxivLookupID,
                                              isbn: paper.isbn.nilIfBlank, title: paper.title.nilIfBlank)
    }) { self.metadataLookup = metadataLookup }

    func reconfigure(with store: LibraryStore) {
        let settings = store.settings
        guard settings.localAPIEnabled else {
            stop()
            if statusText != "Disabled" { statusText = "Disabled" }
            return
        }
        // Multiple library windows and unrelated settings changes can arrive
        // before the listener reports ready. Reuse that pending listener too.
        if listener != nil, activePort == settings.localAPIPort, boundStore === store {
            return
        }
        stop()
        start(port: settings.localAPIPort, store: store)
    }

    func stop() {
        // Invalidate before cancelling: Network delivers state changes later.
        // An old listener must not change a replacement listener's state.
        listenerGeneration = nil
        boundStore = nil
        enrichmentTasks.values.forEach { $0.cancel() }
        enrichmentTasks.removeAll()
        enrichmentGenerations.removeAll()
        listener?.cancel()
        listener = nil
        activePort = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        if isRunning { isRunning = false }
    }

    func waitForEnrichment() async {
        let tasks = Array(enrichmentTasks.values)
        for task in tasks { await task.value }
    }

    private func start(port: Int, store: LibraryStore) {
        do {
            guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                statusText = "Invalid port"
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: nwPort)
            // The required endpoint already supplies the address and port.
            // Passing a second port to NWListener conflicts with it (EINVAL).
            let listener = try NWListener(using: parameters)
            let generation = UUID()
            listener.newConnectionHandler = { [weak self, weak store] connection in
                Task { @MainActor in
                    guard let self, let store, self.listenerGeneration == generation else {
                        connection.cancel()
                        return
                    }
                    self.handle(connection: connection, store: store, generation: generation)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerGeneration == generation else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.statusText = "Listening on 127.0.0.1:\(port)"
                    case .failed(let error):
                        self.stop()
                        self.statusText = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.stop()
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listenerGeneration = generation
            activePort = port
            boundStore = store
            statusText = "Starting..."
            listener.start(queue: queue)
        } catch {
            statusText = "Failed: \(error.localizedDescription)"
        }
    }

    private func handle(connection: NWConnection, store: LibraryStore, generation: UUID) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection: connection, store: store, generation: generation, buffer: Data())
    }

    private nonisolated func receive(connection: NWConnection, store: LibraryStore, generation: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            switch HTTPRequest.parse(data: nextBuffer) {
            case .request(let request):
                Task { @MainActor in
                    guard self.listenerGeneration == generation else { connection.cancel(); return }
                    let response = await self.respond(to: request, store: store)
                    guard self.listenerGeneration == generation else { connection.cancel(); return }
                    self.send(response, on: connection)
                }
                return
            case .invalid(let status, let message):
                self.send(.json(status: status, object: ["error": message]), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    self.send(.plain(status: 400, text: "Bad Request"), on: connection)
                } else {
                    self.receive(connection: connection, store: store, generation: generation, buffer: nextBuffer)
                }
            }
        }
    }

    private nonisolated func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond(to request: HTTPRequest, store: LibraryStore) async -> HTTPResponse {
        let origin = request.headers["origin"]
        if let origin, !Self.isAllowedOrigin(origin, port: store.settings.localAPIPort) {
            return .json(status: 403, object: ["error": "Origin not allowed"])
        }
        var response = await route(request, store: store)
        response.allowedOrigin = origin
        return response
    }

    // CLI clients do not send Origin. Browser clients must be the loopback
    // service itself or a supported extension; web pages cannot access a library.
    private static func isAllowedOrigin(_ origin: String, port: Int) -> Bool {
        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil else { return false }
        switch scheme {
        case "http":
            return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
                && (components.port ?? 80) == port
        case "chrome-extension":
            return components.port == nil && host.count == 32 && host.utf8.allSatisfy { (97...112).contains($0) }
        case "safari-web-extension":
            return components.port == nil && UUID(uuidString: host) != nil
        default:
            return false
        }
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
        // Lattice 3.0 makes browser integrations available with Local API;
        // there is no second independent extension-enabled policy.

        switch (request.method, path) {
        case ("GET", "/connector/status"), ("GET", "/api/v1/status"):
            return statusResponse(store: store)
        case ("GET", "/connector/collections"), ("GET", "/api/v1/collections"):
            return .json(object: ["collections": collectionsPayload(store: store)])
        case ("GET", "/connector/tags"), ("GET", "/api/v1/tags"):
            return .json(object: ["tags": tagsPayload(store: store)])
        case ("GET", "/connector/metadata"), ("GET", "/api/v1/metadata"):
            return await metadataResponse(request: request)
        case ("GET", "/api/v1/search"):
            return searchResponse(request: request, store: store)
        case ("GET", "/api/v1/papers/by-citekey"):
            guard let key = request.query["key"]?.nilIfBlank else {
                return .json(status: 400, object: ["error": "An exact citekey is required"])
            }
            // Return every exact match. The official CLI rejects ambiguous
            // matches rather than silently picking an arbitrary record.
            let matches = store.papers.filter { $0.citekey.trimmed.caseInsensitiveCompare(key) == .orderedSame }
            return .json(object: ["papers": matches.map(lightweightPaperPayload)])
        case ("POST", "/connector/papers"), ("POST", "/api/v1/papers"):
            return await createPaperResponse(request: request, store: store)
        case ("GET", "/api/v1/papers"):
            return .json(object: ["papers": store.papers.map(lightweightPaperPayload)])
        default:
            if request.method == "PUT",
               (path.hasPrefix("/connector/papers/") || path.hasPrefix("/api/v1/papers/")), path.hasSuffix("/pdf") {
                return uploadPDFResponse(request: request, store: store)
            }
            if request.method == "GET", path.hasPrefix("/api/v1/papers/") {
                let idPart = path.replacingOccurrences(of: "/api/v1/papers/", with: "")
                if let id = UUID(uuidString: idPart), let paper = store.paper(with: id) {
                    return .json(object: detailPayload(paper: paper, store: store, includes: request.query["include"] ?? ""))
                }
                return .json(status: 404, object: ["error": "Paper not found"])
            }
            return .json(status: 404, object: ["error": "Not found"])
        }
    }

    private func statusResponse(store: LibraryStore) -> HTTPResponse {
        let baseURL = "http://127.0.0.1:\(store.settings.localAPIPort)"
        let fileLibrary = FileLibraryService.status(for: store.settings)
        var capabilities = ["search", "paper-detail", "csl-item", "collections", "tags", "metadata-lookup"]
        if !store.settings.localAPIReadOnly {
            capabilities.append("create-paper")
            if fileLibrary.isAvailable {
                capabilities.append("pdf-upload")
            }
        }
        return .json(object: [
            "ok": true,
            "apiVersion": "1",
            "serverVersion": "PaperManager 1.0",
            "appVersion": "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))",
            "readOnly": store.settings.localAPIReadOnly,
            "browserExtensionEnabled": true,
            "fileLibrary": ["state": fileLibrary.availability.rawValue, "available": fileLibrary.isAvailable,
                             "rootPath": fileLibrary.rootURL?.path as Any, "message": fileLibrary.message],
            "baseURL": baseURL,
            "capabilities": capabilities
        ])
    }

    private func searchResponse(request: HTTPRequest, store: LibraryStore) -> HTTPResponse {
        let limit: Int
        if let value = request.query["limit"] {
            guard let requested = Int(value), requested > 0 else {
                return .json(status: 400, object: ["error": "limit must be a positive integer"])
            }
            limit = min(requested, 50)
        } else { limit = 10 }
        let terms = (request.query["q"] ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches = store.snapshot.papers.filter { paper in
            let text = [paper.title, paper.authors.joined(separator: " "), paper.sourceDisplay, paper.citekey, paper.year.map(String.init) ?? ""]
                .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { text.contains($0) }
        }.sorted { lhs, rhs in
            lhs.dateAdded == rhs.dateAdded ? lhs.id.uuidString < rhs.id.uuidString : lhs.dateAdded > rhs.dateAdded
        }
        return .json(object: ["papers": matches.prefix(limit).map(lightweightPaperPayload)])
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
            try payload.validate()
            let incoming = payload.paper
            let duplicateID = store.duplicatePaperID(for: incoming)
            if let duplicateID, payload.strategy != "replace" {
                let existing = store.paper(with: duplicateID)
                return .json(status: 409, object: [
                    "error": "Duplicate paper.",
                    "alreadyExists": true,
                    "existingPaperID": duplicateID.uuidString,
                    "existingTitle": existing?.displayTitle ?? "",
                    "conflictField": incoming.doi.isEmpty ? "title" : "doi",
                    "paperManagerURL": "papermanager://paper/\(duplicateID.uuidString)",
                    "latticeURL": "papermanager://paper/\(duplicateID.uuidString)"
                ])
            }
            var paper = incoming
            if let duplicateID, let existing = store.paper(with: duplicateID) {
                paper = try payload.applyingMetadata(to: existing)
            }
            var warnings: [String] = []
            if payload.pdfPath?.nilIfBlank != nil {
                warnings.append("A local PDF path was not attached. Use the PDF upload endpoint to copy a readable PDF into the configured File Library.")
            }
            for collectionName in payload.collections ?? [] {
                if let id = collectionID(forPath: collectionName, store: store), !paper.collectionIDs.contains(id) {
                    paper.collectionIDs.append(id)
                } else if collectionID(forPath: collectionName, store: store) == nil {
                    warnings.append("Collection not found: \(collectionName)")
                }
            }
            var additionalTags: [PaperTag] = []
            for tagName in payload.tags ?? [] {
                let clean = tagName.trimmed
                guard !clean.isEmpty else { continue }
                let tag: PaperTag
                if let existing = (store.tags + additionalTags).first(where: { $0.name == clean }) { tag = existing }
                else {
                    let sortIndex = ((store.tags + additionalTags).map(\.sortIndex).max() ?? -1) + 1
                    tag = PaperTag(name: clean, colorHex: "#5B8DEF", sortIndex: sortIndex)
                    additionalTags.append(tag)
                }
                if !paper.tagIDs.contains(tag.id) { paper.tagIDs.append(tag.id) }
            }
            let id: UUID
            do {
                if let duplicateID {
                    try store.updatePaperDurably(paper, additionalTags: additionalTags)
                    id = duplicateID
                } else {
                    id = try store.addPaperDurably(paper, additionalTags: additionalTags)
                }
            } catch {
                return .json(status: 500, object: ["error": error.localizedDescription])
            }
            let saved = store.paper(with: id) ?? paper
            if payload.enrich == true { enqueueEnrichment(for: saved, store: store) }
            return .json(object: [
                "id": id.uuidString,
                "title": saved.displayTitle,
                "authors": saved.authors,
                "year": saved.year as Any,
                "doi": saved.doi,
                "pdfAttached": saved.hasPDF,
                "enrichmentStatus": payload.enrich == true ? "pending" : "none",
                "alreadyExists": duplicateID != nil,
                "warnings": warnings,
                "paperManagerURL": "papermanager://paper/\(id.uuidString)",
                "latticeURL": "papermanager://paper/\(id.uuidString)"
            ])
        } catch {
            return .json(status: 400, object: ["error": error.localizedDescription])
        }
    }

    private func enqueueEnrichment(for paper: Paper, store: LibraryStore) {
        enrichmentTasks[paper.id]?.cancel()
        let generation = UUID()
        enrichmentGenerations[paper.id] = generation
        let libraryIdentity = store.libraryIdentityToken
        let sourceIdentity = LibraryStore.metadataRefreshIdentity(paper)
        let lookup = metadataLookup
        let limiter = enrichmentLimiter
        enrichmentTasks[paper.id] = Task { [weak self, weak store] in
            defer {
                if self?.enrichmentGenerations[paper.id] == generation {
                    self?.enrichmentTasks.removeValue(forKey: paper.id)
                    self?.enrichmentGenerations.removeValue(forKey: paper.id)
                }
            }
            guard let metadata = try? await limiter.run({ try await lookup(paper) }), !Task.isCancelled,
                  self?.enrichmentGenerations[paper.id] == generation,
                  let store, store.libraryIdentityToken == libraryIdentity,
                  let latest = store.paper(with: paper.id),
                  LibraryStore.metadataRefreshIdentity(latest) == sourceIdentity else { return }
            // A delayed provider result may fill gaps, never erase intervening
            // local edits, memberships, attachments, ratings or annotations.
            do { try store.updatePaperDurably(metadata.merged(into: latest)) }
            catch { store.statusMessage = PMLocalization.format("保存文库失败：%@", error.localizedDescription) }
        }
    }

    private func uploadPDFResponse(request: HTTPRequest, store: LibraryStore) -> HTTPResponse {
        guard request.body.count <= 200_000_000 else {
            return .json(status: 413, object: ["error": "PDF exceeds the 200MB upload limit."])
        }
        let path = request.path
        let stripped = path
            .replacingOccurrences(of: "/connector/papers/", with: "")
            .replacingOccurrences(of: "/api/v1/papers/", with: "")
            .replacingOccurrences(of: "/pdf", with: "")
        guard let id = UUID(uuidString: stripped), let paper = store.paper(with: id) else {
            return .json(status: 404, object: ["error": "Paper not found"])
        }
        guard request.headers["content-type"]?.components(separatedBy: ";").first?.trimmed.lowercased() == "application/pdf" else {
            return .json(status: 400, object: ["error": "Content-Type must be application/pdf"])
        }
        guard request.body.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: request.body), document.pageCount > 0 else {
            return .json(status: 400, object: ["error": "Invalid PDF payload"])
        }
        let force = request.query["force"]?.lowercased() == "true"
        if paper.primaryPDF != nil, !force {
            return .json(status: 409, object: ["error": "PDF already attached", "existingPaperID": id.uuidString])
        }

        let fileLibrary = FileLibraryService.status(for: store.settings)
        guard fileLibrary.isAvailable else {
            return .json(status: 503, object: ["error": fileLibrary.message, "fileLibraryState": fileLibrary.availability.rawValue])
        }

        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let baseName = (paper.citekey.nilIfBlank ?? paper.displayTitle).sanitizedFileName()
            let url = temporary.appendingPathComponent(baseName).appendingPathExtension("pdf")
            try request.body.write(to: url, options: [.atomic])
            try store.attachManagedFile(url, to: id, kind: .pdf, replacePrimary: force)
            return .json(object: ["ok": true, "reason": "uploaded", "id": id.uuidString, "pdfAttached": store.paper(with: id)?.hasPDF == true])
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
                return nil
            }
        }
        return currentID
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
            "authorsDisplay": paper.authorsDisplay,
            "paperType": paper.paperType.rawValue.lowercased(),
            "year": paper.year as Any,
            "source": paper.sourceDisplay,
            "doi": paper.doi,
            "url": paper.url,
            "pdfAttached": paper.hasPDF,
            "paperManagerURL": "papermanager://paper/\(paper.id.uuidString)",
            "latticeURL": "papermanager://paper/\(paper.id.uuidString)"
        ]
    }

    private func detailPayload(paper: Paper, store: LibraryStore, includes: String) -> [String: Any] {
        var payload = lightweightPaperPayload(paper)
        payload["type"] = paper.paperType.rawValue
        payload["paperType"] = paper.paperType.rawValue.lowercased()
        payload["journal"] = paper.journal
        payload["volume"] = paper.volume
        payload["issue"] = paper.issue
        payload["pages"] = paper.pages
        payload["isbn"] = paper.isbn
        payload["cslItem"] = cslItem(for: paper)
        let fields = Set(includes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if fields.contains("abstract") { payload["abstract"] = paper.abstract.nilIfBlank as Any }
        if fields.contains("library") || fields.contains("collections") {
            payload["collections"] = collectionsPayload(store: store).filter { item in
                guard let id = item["id"] as? String, let uuid = UUID(uuidString: id) else { return false }
                return paper.collectionIDs.contains(uuid)
            }
        }
        if fields.contains("library") || fields.contains("tags") {
            payload["tags"] = tagsPayload(store: store).filter { item in
                guard let id = item["id"] as? String, let uuid = UUID(uuidString: id) else { return false }
                return paper.tagIDs.contains(uuid)
            }
        }
        if fields.contains("pdfpath") || fields.contains("pdf_path") {
            var path: String?
            if let attachment = paper.primaryPDF {
                path = try? attachment.withResolvedURL { url in
                    FileManager.default.isReadableFile(atPath: url.path) ? url.path : nil
                }
            }
            payload["pdfPath"] = path as Any
        }
        return payload
    }

    // The independent library stores typed bibliography fields rather than an
    // opaque provider CSL record. This mapping is deterministic and usable by
    // CSL processors; it does not claim to reproduce unrecovered provider keys.
    private func cslItem(for paper: Paper) -> [String: Any] {
        let types = ["article": "article-journal", "book": "book", "inbook": "chapter", "incollection": "chapter",
                     "inproceedings": "paper-conference", "proceedings": "book", "thesis": "thesis", "phdthesis": "thesis",
                     "mastersthesis": "thesis", "report": "report", "techreport": "report", "online": "webpage",
                     "dataset": "dataset", "software": "software", "patent": "patent", "manuscript": "manuscript",
                     "unpublished": "manuscript", "preprint": "article", "misc": "article"]
        var item: [String: Any] = ["id": paper.citekey.nilIfBlank ?? paper.id.uuidString,
                                   "type": types[paper.paperType.rawValue.lowercased()] ?? types[paper.paperType.bibTeXType] ?? "article",
                                   "title": paper.title]
        if !paper.authors.isEmpty { item["author"] = paper.authors.map(cslName) }
        if let editors = paper.editors, !editors.isEmpty { item["editor"] = editors.map(cslName) }
        if let translators = paper.translators, !translators.isEmpty { item["translator"] = translators.map(cslName) }
        if let year = paper.year { item["issued"] = ["date-parts": [[year]]] }
        let values = [("container-title", paper.bookTitle.nilIfBlank ?? paper.journal), ("publisher", paper.publisher),
                      ("publisher-place", paper.address ?? ""), ("volume", paper.volume), ("issue", paper.issue), ("page", paper.pages),
                      ("DOI", paper.doi), ("ISBN", paper.isbn), ("URL", paper.url), ("abstract", paper.abstract),
                      ("edition", paper.edition), ("collection-title", paper.series), ("language", paper.language),
                      ("event-title", paper.event), ("event-place", paper.venue)]
        for (key, value) in values where !value.trimmed.isEmpty { item[key] = value }
        return item
    }

    private func cslName(_ name: String) -> [String: String] {
        let clean = name.trimmed
        if clean.hasPrefix("{"), clean.hasSuffix("}") { return ["literal": String(clean.dropFirst().dropLast())] }
        if let comma = clean.firstIndex(of: ",") {
            let family = String(clean[..<comma]).trimmed
            let given = String(clean[clean.index(after: comma)...]).trimmed
            return given.isEmpty ? ["family": family] : ["family": family, "given": given]
        }
        let components = clean.split(whereSeparator: { $0.isWhitespace })
        guard components.count > 1, let family = components.last else { return ["family": clean] }
        return ["family": String(family), "given": components.dropLast().joined(separator: " ")]
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

private struct APINames: Codable {
    var values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let names = try? container.decode([String].self) {
            guard !names.isEmpty, names.allSatisfy({ !$0.trimmed.isEmpty }) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Authors must be a non-empty array of non-empty names")
            }
            values = names.map(\.trimmed)
        } else {
            let text = try container.decode(String.self)
            values = text.components(separatedBy: ";").map(\.trimmed).filter { !$0.isEmpty }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

private struct CreatePaperPayload: Codable {
    var title: String
    var subtitle: String?
    var authors: APINames?
    var editors: APINames?
    var translators: APINames?
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
    var pdfPath: String?

    func validate() throws {
        guard !title.trimmed.isEmpty, title.utf8.count <= 1_024 else {
            throw PaperManagerError.message("title must contain 1 to 1024 UTF-8 bytes")
        }
        guard (authors?.values.joined(separator: "; ").utf8.count ?? 0) <= 16_384 else {
            throw PaperManagerError.message("authors exceeds 16384 UTF-8 bytes")
        }
        guard (abstract?.utf8.count ?? 0) <= 65_536 else {
            throw PaperManagerError.message("abstract exceeds 65536 UTF-8 bytes")
        }
        for (name, values) in [("collections", collections ?? []), ("tags", tags ?? [])] {
            guard values.count <= 100, values.allSatisfy({ !$0.trimmed.isEmpty && $0.utf8.count <= 256 }) else {
                throw PaperManagerError.message("\(name) must contain at most 100 non-empty values, each at most 256 UTF-8 bytes")
            }
        }
        if let strategy, !["skip", "replace"].contains(strategy) {
            throw PaperManagerError.message("strategy must be skip or replace")
        }
        if let paperType {
            let active = ["article", "book", "inbook", "incollection", "inproceedings", "proceedings", "thesis", "report", "online", "dataset", "software", "patent", "manuscript", "preprint", "misc"]
            guard active.contains(paperType.lowercased()) || PaperType(rawValue: paperType) != nil else {
                throw PaperManagerError.message("Unsupported paperType")
            }
        }
    }

    func applyingMetadata(to existing: Paper) throws -> Paper {
        let encoder = JSONEncoder()
        let supplied = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        let incoming = try JSONSerialization.jsonObject(with: encoder.encode(paper)) as! [String: Any]
        var merged = try JSONSerialization.jsonObject(with: encoder.encode(existing)) as! [String: Any]
        let aliases = [
            "booktitle": "bookTitle", "howpublished": "howPublished", "pubState": "publicationState", "eventTitle": "event"
        ]
        for key in supplied.keys where !["collections", "tags", "enrich", "strategy", "pdfPath"].contains(key) {
            let paperKey = aliases[key] ?? key
            merged[paperKey] = incoming[paperKey]
        }
        return try JSONDecoder().decode(Paper.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    var paper: Paper {
        var paper = Paper()
        paper.title = title
        paper.subtitle = subtitle?.nilIfBlank
        paper.authors = authors?.values ?? []
        paper.editors = editors?.values
        paper.translators = translators?.values
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

    private static let maximumHeaderLength = 64 * 1024
    private static let maximumBodyLength = 200_000_000

    enum ParseResult {
        case incomplete
        case request(HTTPRequest)
        case invalid(status: Int, message: String)
    }

    static func parse(data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderLength
                ? .invalid(status: 431, message: "Request headers too large") : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderLength else {
            return .invalid(status: 431, message: "Request headers too large")
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid(status: 400, message: "Invalid request headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid(status: 400, message: "Invalid request line") }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3,
              ["HTTP/1.0", "HTTP/1.1"].contains(String(requestParts[2])),
              requestParts[0].utf8.allSatisfy(isTokenByte),
              requestParts[1].hasPrefix("/") else {
            return .invalid(status: 400, message: "Invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, message: "Invalid request header")
            }
            let key = String(line[..<colon]).lowercased()
            let rawValue = String(line[line.index(after: colon)...])
            guard !key.isEmpty, key.utf8.allSatisfy(isTokenByte),
                  !rawValue.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }),
                  headers[key] == nil else {
                return .invalid(status: 400, message: "Invalid or duplicate request header")
            }
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers[key] = value
        }
        guard requestParts[2] != "HTTP/1.1" || headers["host"]?.nilIfBlank != nil else {
            return .invalid(status: 400, message: "Host header required")
        }
        guard headers["transfer-encoding"] == nil else {
            return .invalid(status: 400, message: "Transfer-Encoding is not supported; use Content-Length")
        }

        let bodyStart = headerRange.upperBound
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return .invalid(status: 400, message: "Invalid Content-Length")
        }
        guard let expectedLength = Int(lengthText), expectedLength <= maximumBodyLength else {
            return .invalid(status: 413, message: "Payload too large")
        }
        guard data.count - bodyStart >= expectedLength else { return .incomplete }

        let rawTarget = String(requestParts[1])
        guard var components = URLComponents(string: "http://127.0.0.1\(rawTarget)"),
              components.host == "127.0.0.1", components.fragment == nil else {
            return .invalid(status: 400, message: "Invalid request target")
        }
        // LatticeCLI uses standard form query encoding: spaces are '+', while
        // a literal plus is '%2B'. URLComponents alone leaves '+' unchanged.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        return .request(HTTPRequest(
            method: String(requestParts[0]), path: components.path, query: query,
            headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + expectedLength))
        ))
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}

private struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var allowedOrigin: String? = nil

    var data: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        if let allowedOrigin {
            header += "Access-Control-Allow-Origin: \(allowedOrigin)\r\n"
            header += "Access-Control-Allow-Headers: Content-Type\r\n"
            header += "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
            header += "Vary: Origin\r\n"
        }
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
        case 431: return "Request Header Fields Too Large"
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
