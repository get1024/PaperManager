import CoreFoundation
import Foundation

struct ConnectorFailure: Error, CustomStringConvertible {
    let description: String
    var exitCode: Int32 = 2
    var response: Any? = nil
}

struct CLIArguments {
    var command = "status"
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    static let switches: Set<String> = ["allow-write", "read-only", "force", "enrich"]
    static let valued: Set<String> = ["base-url", "port", "query", "limit", "id", "reference", "include", "title", "authors", "year", "journal", "abstract", "doi", "volume", "issue", "pages", "isbn", "type", "url", "eprint", "eprint-type", "eprint-class", "collection", "tag", "strategy", "pdf-path", "output"]

    init(_ arguments: [String]) throws {
        var index = 0, foundCommand = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if Self.switches.contains(name) { flags.insert(name) }
                else if Self.valued.contains(name) {
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw ConnectorFailure(description: "Missing value for --\(name)") }
                    values[name, default: []].append(arguments[index])
                } else { throw ConnectorFailure(description: "Unknown option: \(argument)") }
            } else if !foundCommand {
                command = argument; foundCommand = true
            } else { throw ConnectorFailure(description: "Unexpected argument: \(argument)") }
            index += 1
        }
        guard !(flags.contains("allow-write") && flags.contains("read-only")) else { throw ConnectorFailure(description: "--read-only and --allow-write cannot be combined") }
        for (name, items) in values where items.count > 1 && !["include", "collection", "tag"].contains(name) {
            throw ConnectorFailure(description: "--\(name) may only be provided once")
        }
    }

    func value(_ name: String) -> String? { values[name]?.first }
    func require(_ name: String) throws -> String {
        guard let text = value(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw ConnectorFailure(description: "--\(name) is required") }
        return text
    }

    func validateOptions(_ allowed: Set<String>) throws {
        let globals: Set<String> = ["base-url", "port", "read-only", "allow-write"]
        let unknown = Set(values.keys).union(flags).subtracting(allowed.union(globals))
        guard unknown.isEmpty else { throw ConnectorFailure(description: "Unsupported option(s) for \(command): \(unknown.sorted().joined(separator: ", "))") }
    }
}

struct ConnectorConfiguration {
    let baseURL: URL
    let readOnly: Bool

    init(arguments: CLIArguments, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let base: String
        if let explicit = arguments.value("base-url") { base = explicit }
        else if let port = arguments.value("port") { base = "http://127.0.0.1:\(port)" }
        else if let configured = environment["PAPERMANAGER_CLI_BASE_URL"] { base = configured }
        else { base = "http://127.0.0.1:\(environment["PAPERMANAGER_CLI_PORT"] ?? "29467")" }
        guard let components = URLComponents(string: base), components.scheme == "http",
              let host = components.host?.lowercased(), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              let port = components.port, (1024...65535).contains(port),
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil, let url = components.url else {
            throw ConnectorFailure(description: "Base URL must be an explicit http:// loopback host with port 1024...65535 and no path, credentials, query, or fragment")
        }
        baseURL = url
        if arguments.flags.contains("read-only") { readOnly = true }
        else if arguments.flags.contains("allow-write") { readOnly = false }
        else if let value = environment["PAPERMANAGER_CLI_READONLY"] {
            switch value.lowercased() {
            case "1", "true": readOnly = true
            case "0", "false": readOnly = false
            default: throw ConnectorFailure(description: "PAPERMANAGER_CLI_READONLY must be 1, 0, true, or false")
            }
        } else { readOnly = true }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ConnectorClient {
    let configuration: ConnectorConfiguration
    private let session: URLSession

    init(configuration: ConnectorConfiguration) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 30
        settings.httpShouldSetCookies = false
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Any {
        guard path.hasPrefix("/api/v1/") else { throw ConnectorFailure(description: "Invalid API path") }
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ConnectorFailure(description: "Local API unavailable: \(error.localizedDescription)", exitCode: 1) }
        guard let http = response as? HTTPURLResponse else { throw ConnectorFailure(description: "Local API did not return HTTP", exitCode: 1) }
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(http.statusCode) else {
            let message = (json as? [String: Any])?["error"] as? String ?? String(data: data.prefix(8192), encoding: .utf8) ?? "Request failed"
            throw ConnectorFailure(description: "HTTP \(http.statusCode): \(message)", exitCode: 1, response: json)
        }
        guard let json else { throw ConnectorFailure(description: "Local API returned invalid JSON", exitCode: 1) }
        return json
    }

    func status() async throws -> [String: Any] {
        guard var status = try await request("/api/v1/status") as? [String: Any], status["ok"] as? Bool == true,
              let serverReadOnly = status["readOnly"] as? Bool else { throw ConnectorFailure(description: "Invalid Local API status schema", exitCode: 1) }
        status["clientReadOnly"] = configuration.readOnly
        status["effectiveReadOnly"] = configuration.readOnly || serverReadOnly
        return status
    }

    func requireWrite(_ capability: String) async throws {
        guard !configuration.readOnly else { throw ConnectorFailure(description: "Client is read-only. Use --allow-write only for an explicitly requested mutation.") }
        let current = try await status()
        guard current["effectiveReadOnly"] as? Bool == false else { throw ConnectorFailure(description: "Local API is in read-only mode", exitCode: 1) }
        guard (current["capabilities"] as? [String])?.contains(capability) == true else { throw ConnectorFailure(description: "Local API capability unavailable: \(capability)", exitCode: 1) }
    }

    func paper(reference: String, includes: [String] = []) async throws -> [String: Any] {
        let id: UUID
        if let parsed = UUID(uuidString: reference) { id = parsed }
        else {
            let key = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw ConnectorFailure(description: "Reference must be a UUID or exact citekey") }
            guard let result = try await request("/api/v1/papers/by-citekey", query: [.init(name: "key", value: key)]) as? [String: Any],
                  let papers = result["papers"] as? [[String: Any]] else { throw ConnectorFailure(description: "Invalid citekey response schema", exitCode: 1) }
            guard papers.count == 1, let value = papers[0]["id"] as? String, let parsed = UUID(uuidString: value) else {
                throw ConnectorFailure(description: papers.isEmpty ? "No paper has that exact citekey" : "Citekey is ambiguous; select an explicit UUID", exitCode: 1, response: result)
            }
            id = parsed
        }
        let allowed: Set<String> = ["abstract", "pdf_path", "pdfPath", "collections", "tags", "library"]
        guard includes.allSatisfy({ allowed.contains($0) }) else { throw ConnectorFailure(description: "Unknown --include value") }
        let query = includes.isEmpty ? [] : [URLQueryItem(name: "include", value: includes.map { $0 == "pdf_path" ? "pdfPath" : $0 }.joined(separator: ","))]
        guard let result = try await request("/api/v1/papers/\(id.uuidString)", query: query) as? [String: Any] else { throw ConnectorFailure(description: "Invalid paper response schema", exitCode: 1) }
        return result
    }

    func create(_ payload: [String: Any]) async throws -> Any {
        try Self.validatePayload(payload)
        try await requireWrite("create-paper")
        return try await request("/api/v1/papers", method: "POST", body: JSONSerialization.data(withJSONObject: payload), contentType: "application/json; charset=utf-8")
    }

    func attach(id: String, path: String, force: Bool) async throws -> Any {
        guard let id = UUID(uuidString: id) else { throw ConnectorFailure(description: "--id must be a UUID") }
        let url = URL(fileURLWithPath: path)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw ConnectorFailure(description: "PDF file is not readable") }
        guard values.isRegularFile == true, let size = values.fileSize, size <= 200_000_000 else { throw ConnectorFailure(description: "PDF must be a readable regular file of at most 200000000 bytes") }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ConnectorFailure(description: "PDF file is not readable") }
        guard data.starts(with: Data("%PDF-".utf8)), data.count <= 200_000_000 else { throw ConnectorFailure(description: "File is not a PDF or exceeds the upload limit") }
        try await requireWrite("pdf-upload")
        return try await request("/api/v1/papers/\(id.uuidString)/pdf", query: force ? [.init(name: "force", value: "true")] : [], method: "PUT", body: data, contentType: "application/pdf")
    }

    static func validatePayload(_ payload: [String: Any]) throws {
        let stringFields: Set<String> = ["title", "subtitle", "journal", "bookTitle", "booktitle", "abstract", "doi", "volume", "issue", "pages", "isbn", "url", "urlDate", "paperType", "publisher", "address", "edition", "series", "chapter", "institution", "school", "type", "howpublished", "howPublished", "organization", "language", "month", "eprint", "eprintType", "eprintClass", "pubState", "publicationState", "eventTitle", "event", "eventDate", "venue", "notes", "strategy", "pdfPath"]
        let allowed = stringFields.union(["authors", "editors", "translators", "year", "collections", "tags", "enrich"])
        guard Set(payload.keys).isSubset(of: allowed) else { throw ConnectorFailure(description: "Unsupported metadata field(s): \(Set(payload.keys).subtracting(allowed).sorted().joined(separator: ", "))") }
        for field in stringFields where payload[field] != nil {
            guard payload[field] is String else { throw ConnectorFailure(description: "\(field) must be a string") }
        }
        if let year = payload["year"] {
            guard let number = year as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  year as? Int != nil else { throw ConnectorFailure(description: "year must be an integer") }
        }
        if let enrich = payload["enrich"] {
            guard let number = enrich as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ConnectorFailure(description: "enrich must be a boolean") }
        }
        guard let title = payload["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1024 else { throw ConnectorFailure(description: "title must contain 1...1024 UTF-8 bytes") }
        for field in ["authors", "editors", "translators"] {
          if let raw = payload[field] {
            let normalized: String
            if let names = raw as? [String], !names.isEmpty, names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { normalized = names.joined(separator: "; ") }
            else if let text = raw as? String { normalized = text }
            else { throw ConnectorFailure(description: "\(field) must be a string or a non-empty array of non-empty names") }
            guard normalized.utf8.count <= 16384 else { throw ConnectorFailure(description: "\(field) exceeds 16384 UTF-8 bytes") }
          }
        }
        if let abstract = payload["abstract"] as? String, abstract.utf8.count > 65536 { throw ConnectorFailure(description: "abstract exceeds 65536 UTF-8 bytes") }
        for key in ["collections", "tags"] {
            if let raw = payload[key] {
                guard let names = raw as? [String], names.count <= 100,
                      names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }) else { throw ConnectorFailure(description: "\(key) must contain at most 100 non-empty names of at most 256 UTF-8 bytes") }
            }
        }
        if let strategy = payload["strategy"] as? String, !["skip", "replace"].contains(strategy) { throw ConnectorFailure(description: "strategy must be skip or replace") }
        if let type = payload["paperType"] as? String, !["article", "book", "inbook", "incollection", "inproceedings", "proceedings", "thesis", "report", "online", "dataset", "software", "patent", "manuscript", "preprint", "misc"].contains(type.lowercased()) { throw ConnectorFailure(description: "Unknown paper type") }
    }
}

func encodedJSON(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
func writeJSON(_ object: Any) throws { FileHandle.standardOutput.write(try encodedJSON(object)); FileHandle.standardOutput.write(Data([10])) }
