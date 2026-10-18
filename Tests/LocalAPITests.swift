import Darwin
import Foundation

private struct APITestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct TCPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(_ data: Data) throws {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[..<separator.lowerBound], encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first,
              let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw APITestFailure(description: "Server did not return an HTTP response")
        }
        self.status = status
        headers = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmed
            }
        }
        body = Data(data[separator.upperBound...])
    }
}

@main
@MainActor
struct LocalAPITests {
    private static var passed = 0
    private static var failures: [String] = []

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerAPI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try availablePort()
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.localAPIEnabled, value: true)
        store.updateSetting(\.localAPIPort, value: port)
        let uploads = root.appendingPathComponent("uploads", isDirectory: true)
        store.updateSetting(\.browserUploadFolder, value: uploads.path)
        let pdf = minimalPDF()
        let original = root.appendingPathComponent("lattice-source.pdf")
        try pdf.write(to: original)
        let collection = store.addCollection(name: "Original collection")
        let tag = store.addTag(name: "Original tag")
        var fixture = Paper(title: "Local API fixture", authors: ["Ada"], year: 2026, doi: "10.5555/api-fixture", notes: "Retain local notes")
        fixture.rating = 4
        fixture.journal = "Retain omitted journal"
        fixture.annotations = [ResearchAnnotation(page: 1, note: "Retain local annotation")]
        fixture.collectionIDs = [collection]
        fixture.tagIDs = [tag]
        fixture.attachments = [Attachment(kind: .pdf, filePath: original.path, displayName: original.lastPathComponent, isReadOnlyReference: true)]
        let id = store.addPaper(fixture)
        let server = LocalAPIServer()
        server.reconfigure(with: store)
        defer { server.stop() }
        for _ in 0..<100 where !server.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        guard server.isRunning else { throw APITestFailure(description: server.statusText) }

        await run("Actual listener is restricted to 127.0.0.1") {
            let status = try await request(port: port, path: "/api/v1/status")
            try expect(status.status == 200 && status.headers["access-control-allow-origin"] == nil, "CLI status or no-Origin CORS is incorrect")
            try expect(try listeningEndpoints(port: port) == ["127.0.0.1:\(port)"], "The actual listening socket is not bound only to 127.0.0.1")
            let otherLoopback = await canConnect(host: "127.0.0.2", port: port)
            try expect(!otherLoopback, "Listener accepts another local address, indicating a wildcard bind")
            for address in localIPv4Addresses() where !address.hasPrefix("127.") {
                let exposed = await canConnect(host: address, port: port)
                try expect(!exposed, "Listener is exposed on \(address)")
            }
        }
        await run("CLI, loopback and browser extension origins remain compatible") {
            for origin in ["http://127.0.0.1:\(port)", "http://localhost:\(port)", "chrome-extension://abcdefghijklmnopabcdefghijklmnop", "safari-web-extension://12345678-1234-1234-1234-123456789ABC"] {
                let response = try await request(port: port, path: "/connector/status", headers: ["Origin": origin])
                try expect(response.status == 200 && response.headers["access-control-allow-origin"] == origin, "Supported Origin was not echoed: \(origin)")
                try expect(response.headers["vary"] == "Origin", "Origin-dependent response missing Vary")
            }
            let preflight = try await request(port: port, method: "OPTIONS", path: "/connector/papers", headers: ["Origin": "chrome-extension://abcdefghijklmnopabcdefghijklmnop"])
            try expect(preflight.status == 204 && preflight.headers["access-control-allow-methods"]?.contains("PUT") == true, "Supported extension preflight failed")
        }
        await run("Arbitrary website origins cannot read or mutate the library") {
            for origin in ["https://example.invalid", "null", "http://localhost:\(port + 1)", "https://localhost:\(port)", "http://localhost.evil.invalid:\(port)"] {
                let response = try await request(port: port, path: "/api/v1/papers", headers: ["Origin": origin])
                try expect(response.status == 403 && response.headers["access-control-allow-origin"] == nil, "Disallowed Origin was authorized: \(origin)")
            }
            let preflight = try await request(port: port, method: "OPTIONS", path: "/connector/papers", headers: ["Origin": "https://example.invalid"])
            let write = try await request(port: port, method: "POST", path: "/api/v1/papers", headers: ["Origin": "https://example.invalid", "Content-Type": "application/json"], body: Data(#"{"title":"Unauthorized write"}"#.utf8))
            try expect(preflight.status == 403 && write.status == 403 && store.papers.count == 1, "Disallowed preflight/write succeeded")
        }
        await run("Malformed framing returns an error and the server remains alive") {
            let malformed: [(String, Int)] = [
                ("GET /api/v1/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n", 400),
                ("GET /api/v1/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n", 400),
                ("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 209715201\r\n\r\n", 413),
                ("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999999999999999999999999\r\n\r\n", 413),
                ("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\ncOnTeNt-LeNgTh: 0\r\n\r\n", 400),
                ("GET /api/v1/status HTTP/1.1\r\nHost: localhost\r\nOrigin: https://example.invalid\r\nOrigin: http://localhost:\(port)\r\n\r\n", 400),
                ("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 400),
                ("GET /api/v1/status HTTP/1.1\r\nBroken header\r\n\r\n", 400),
                ("GET /api/v1/status HTTP/1.1\r\nHost: localhost\r\nOrigin: \nhttp://localhost:\(port)\r\n\r\n", 400),
                ("GET /api/v1/status HTTP/1.1\r\nHost: localhost\r\nX-Large: \(String(repeating: "a", count: 70 * 1024))\r\n\r\n", 431),
                ("POST /api/v1/papers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nx", 400)
            ]
            for (raw, expected) in malformed {
                let response = try TCPResponse(await exchange(port: port, chunks: [Data(raw.utf8)]))
                try expect(response.status == expected, "Malformed framing returned \(response.status), expected \(expected)")
            }
            let alive = try await request(port: port, path: "/api/v1/status?duplicate=1&duplicate=2")
            try expect(alive.status == 200, "Repeated query parameters crashed the server")
        }
        await run("Read-only mode guards writes and extensions follow Local API") {
            store.updateSetting(\.localAPIReadOnly, value: true)
            let read = try await request(port: port, path: "/api/v1/papers")
            let write = try await request(port: port, method: "POST", path: "/connector/papers", body: Data(#"{"title":"Read only write"}"#.utf8))
            let upload = try await request(port: port, method: "PUT", path: "/connector/papers/\(id)/pdf?force=true", headers: ["Content-Type": "application/pdf"], body: pdf)
            try expect(read.status == 200 && write.status == 403 && upload.status == 403 && store.papers.count == 1, "Read-only guard failed")
            store.updateSetting(\.localAPIReadOnly, value: false)
            store.updateSetting(\.browserExtensionEnabled, value: false)
            let status = try await request(port: port, path: "/connector/status")
            let blocked = try await request(port: port, path: "/connector/collections")
            try expect(status.status == 200 && blocked.status == 200, "Legacy extension toggle incorrectly overrides the enabled Local API")
            store.updateSetting(\.browserExtensionEnabled, value: true)
        }
        await run("PDF uploads reject bad MIME, invalid PDF and unforced replacement") {
            let path = "/connector/papers/\(id)/pdf"
            let wrongMIME = try await request(port: port, method: "PUT", path: path, headers: ["Content-Type": "text/plain"], body: pdf)
            let invalidPDF = try await request(port: port, method: "PUT", path: path, headers: ["Content-Type": "application/pdf"], body: Data("not a PDF".utf8))
            let conflict = try await request(port: port, method: "PUT", path: path, headers: ["Content-Type": "application/pdf"], body: pdf)
            try expect(wrongMIME.status == 400 && invalidPDF.status == 400 && conflict.status == 409, "PDF upload validation or conflict response failed")
            try expect(store.paper(with: id)?.attachments.count == 1 && !FileManager.default.fileExists(atPath: uploads.path), "Rejected PDF request wrote files or changed attachments")
        }
        await run("Forced PDF upload replaces the primary and preserves source references") {
            try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
            store.updateSetting(\.pdfOrganizationMode, value: .copy)
            store.updateSetting(\.pdfOrganizationFolder, value: uploads.path)
            let response = try await request(port: port, method: "PUT", path: "/connector/papers/\(id)/pdf?force=true", headers: ["Content-Type": "application/pdf"], body: pdf, fragmented: true)
            try expect(response.status == 200, "Valid fragmented upload failed")
            let saved = store.paper(with: id)!
            try expect(saved.primaryPDF?.filePath != original.path && saved.attachments.count == 2, "Uploaded PDF is not the primary attachment")
            try expect(saved.attachments.contains { $0.filePath == original.path && $0.isReadOnlyReference }, "Forced upload removed source authority")
            try expect(try Data(contentsOf: original) == pdf, "Forced upload changed original source bytes")
        }
        await run("Duplicate metadata replacement preserves local records and supplied fields") {
            _ = store.addCollection(name: "API collection")
            let payload = Data(#"{"title":"Updated API title","doi":"10.5555/api-fixture","authors":"Grace; Alan","strategy":"replace","collections":["API collection"],"tags":["API tag"]}"#.utf8)
            let response = try await request(port: port, method: "POST", path: "/connector/papers", headers: ["Content-Type": "application/json"], body: payload)
            try expect(response.status == 200 && store.papers.count == 1, "Metadata replacement created another record")
            let saved = store.paper(with: id)!
            try expect(saved.title == "Updated API title" && saved.authors == ["Grace", "Alan"], "Supplied metadata did not replace values")
            try expect(saved.rating == 4 && saved.notes == fixture.notes && saved.annotations == fixture.annotations && saved.journal == fixture.journal, "Replacement erased omitted/local metadata")
            try expect(saved.attachments.count == 2 && saved.collectionIDs.contains(collection) && saved.tagIDs.contains(tag), "Replacement erased attachments or memberships")
            try expect(saved.collectionIDs.count == 2 && saved.tagIDs.count == 2, "Supplied memberships were not merged")
            let conflict = try await request(port: port, method: "POST", path: "/connector/papers", headers: ["Content-Type": "application/json"], body: Data(#"{"title":"Duplicate title","doi":"10.5555/api-fixture","collections":["Rejected collection"],"tags":["Rejected tag"]}"#.utf8))
            try expect(conflict.status == 409 && !store.collections.contains { $0.name == "Rejected collection" } && !store.tags.contains { $0.name == "Rejected tag" }, "Duplicate conflict unexpectedly changed library structure")
            let reopened = LibraryStore(persistenceURL: store.persistenceURL)
            try expect(reopened.paper(with: id)?.attachments.map(\.filePath) == saved.attachments.map(\.filePath)
                && reopened.paper(with: id)?.attachments.contains { $0.filePath == original.path && $0.isReadOnlyReference } == true
                && reopened.paper(with: id)?.notes == fixture.notes, "API replacement/upload did not persist")
        }
        await run("Out-of-range configured ports fail without a conversion trap") {
            let isolated = LibraryStore(persistenceURL: root.appendingPathComponent("invalid-port.json"))
            isolated.updateSetting(\.localAPIEnabled, value: true)
            let invalid = LocalAPIServer()
            for port in [-1, 0, 65536] {
                isolated.updateSetting(\.localAPIPort, value: port)
                invalid.reconfigure(with: isolated)
                try expect(!invalid.isRunning && invalid.statusText == "Invalid port", "Invalid configured port did not fail safely")
            }
        }
        await run("Search and exact citekey resolution expose the documented read contract") {
            var snapshot = store.snapshot
            let searchID = UUID()
            var paper = Paper(title: "A Synthetic Search Fixture", authors: ["Lovelace, Ada"], year: 2026, doi: "10.5555/synthetic-search", notes: "not-searchable-secret")
            paper.id = searchID
            paper.citekey = "SyntheticSearch2026"
            paper.dateAdded = Date(timeIntervalSince1970: 2_000_000_000)
            paper.abstract = "Synthetic abstract"
            paper.collectionIDs = [collection]
            paper.tagIDs = [tag]
            paper.attachments = [Attachment(kind: .pdf, filePath: original.path, displayName: "synthetic.pdf", isReadOnlyReference: true)]
            snapshot.papers.append(paper)
            for index in 0..<60 {
                var item = Paper(title: "Synthetic bulk \(index)", authors: ["Bulk Author"], year: 2020)
                item.citekey = "bulk\(index)"
                item.dateAdded = Date(timeIntervalSince1970: 1_500_000_000 + Double(index))
                snapshot.papers.append(item)
            }
            store.replaceSnapshot(snapshot)
            let search = try jsonObject(await request(port: port, path: "/api/v1/search?q=synthetic+fixture&limit=7"))
            let hits = search["papers"] as? [[String: Any]] ?? []
            try expect(hits.count == 1 && hits.first?["id"] as? String == searchID.uuidString, "Form-encoded words did not match the correct bibliographic record")
            try expect(hits.first?["authorsDisplay"] as? String != nil && hits.first?["paperType"] as? String == "article", "Search hit is missing official CLI fields")
            let recent = try jsonObject(await request(port: port, path: "/api/v1/search"))["papers"] as? [[String: Any]] ?? []
            let capped = try jsonObject(await request(port: port, path: "/api/v1/search?limit=500"))["papers"] as? [[String: Any]] ?? []
            try expect(recent.count == 10 && recent.first?["id"] as? String == searchID.uuidString && capped.count == 50, "Recent order, default limit, or 50-result cap is incorrect")
            let privateText = try jsonObject(await request(port: port, path: "/api/v1/search?q=not-searchable-secret"))["papers"] as? [[String: Any]] ?? []
            try expect(privateText.isEmpty, "API search unexpectedly exposes notes outside its documented search fields")
            let exact = try jsonObject(await request(port: port, path: "/api/v1/papers/by-citekey?key=%20SYNTHETICSEARCH2026%20"))["papers"] as? [[String: Any]] ?? []
            let fuzzy = try jsonObject(await request(port: port, path: "/api/v1/papers/by-citekey?key=SyntheticSearch"))["papers"] as? [[String: Any]] ?? []
            try expect(exact.count == 1 && exact.first?["id"] as? String == searchID.uuidString && fuzzy.isEmpty, "Citekey resolution was fuzzy or case-sensitive")
            let base = try jsonObject(await request(port: port, path: "/api/v1/papers/\(searchID)"))
            try expect(base["abstract"] == nil && base["pdfPath"] == nil && base["collections"] == nil && base["tags"] == nil, "Detail returned unrequested opt-in fields")
            let detail = try jsonObject(await request(port: port, path: "/api/v1/papers/\(searchID)?include=library,pdfPath,abstract"))
            let collections = detail["collections"] as? [[String: Any]] ?? []
            let tags = detail["tags"] as? [[String: Any]] ?? []
            let csl = detail["cslItem"] as? [String: Any] ?? [:]
            let names = csl["author"] as? [[String: String]] ?? []
            try expect(detail["pdfPath"] as? String == original.path && detail["abstract"] as? String == paper.abstract, "Opt-in PDF path or abstract was not resolved")
            try expect(collections.first?["id"] as? String == collection.uuidString && collections.first?["depth"] as? Int == 0 && tags.first?["colorHex"] as? String != nil, "Library membership payload is not the documented object shape")
            try expect(csl["type"] as? String == "article-journal" && csl["DOI"] as? String == paper.doi && names.first?["family"] == "Lovelace" && names.first?["given"] == "Ada", "CSL item is missing bibliographic fields or person names")
        }
        await run("Create validates UTF-8 limits and reports missing collections without creating them") {
            let before = store.papers.count
            let invalid: [[String: Any]] = [
                ["title": " "], ["title": String(repeating: "中", count: 342)],
                ["title": "Invalid authors", "authors": [""]],
                ["title": "Oversize authors", "authors": String(repeating: "A", count: 16_385)],
                ["title": "Oversize abstract", "abstract": String(repeating: "A", count: 65_537)],
                ["title": "Too many tags", "tags": Array(repeating: "tag", count: 101)],
                ["title": "Invalid policy", "strategy": "erase"]
            ]
            for payload in invalid {
                let response = try await request(port: port, method: "POST", path: "/api/v1/papers", headers: ["Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: payload))
                try expect(response.status == 400 && store.papers.count == before, "Invalid create request was saved")
            }
            let body = try JSONSerialization.data(withJSONObject: ["title": "Synthetic created paper", "authors": ["Grace Hopper", "Alan Turing"], "collections": ["Missing/Collection"], "tags": ["Created tag"]])
            let response = try jsonObject(await request(port: port, method: "POST", path: "/api/v1/papers", headers: ["Content-Type": "application/json"], body: body))
            let newID = (response["id"] as? String).flatMap(UUID.init(uuidString:))
            try expect(newID.flatMap { store.paper(with: $0) }?.authors == ["Grace Hopper", "Alan Turing"], "Array authors were not retained")
            try expect((response["warnings"] as? [String]) == ["Collection not found: Missing/Collection"] && !store.collections.contains { $0.name == "Missing" }, "Missing collection was created or warning was omitted")
        }
        await run("Public PDF route uploads and preserves force conflict semantics") {
            let target = store.papers.first { $0.title == "Synthetic created paper" }!
            let path = "/api/v1/papers/\(target.id)/pdf"
            let first = try jsonObject(await request(port: port, method: "PUT", path: path, headers: ["Content-Type": "application/pdf"], body: pdf))
            try expect(first["reason"] as? String == "uploaded" && store.paper(with: target.id)?.primaryPDF != nil, "Public route did not report uploaded PDF")
            let conflict = try await request(port: port, method: "PUT", path: path, headers: ["Content-Type": "application/pdf"], body: pdf)
            try expect(conflict.status == 409, "Unforced public upload overwrote the primary PDF")
            let tooLarge = try TCPResponse(await exchange(port: port, chunks: [Data("PUT \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: 200000001\r\n\r\n".utf8)]))
            try expect(tooLarge.status == 413, "Decimal 200,000,000-byte upload limit is not enforced before buffering")
        }
        await run("Write failures return server errors without publishing phantom papers or replacements") {
            let before = try store.snapshotRevisionToken()
            let stored = root.appendingPathComponent("saved-library.json")
            try FileManager.default.moveItem(at: store.persistenceURL, to: stored)
            try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: store.persistenceURL)
                try? FileManager.default.moveItem(at: stored, to: store.persistenceURL)
            }
            for payload: [String: Any] in [
                ["title": "Must not appear after failure"],
                ["title": "Must not overwrite after failure", "doi": fixture.doi, "strategy": "replace"]
            ] {
                let response = try await request(port: port, method: "POST", path: "/api/v1/papers", headers: ["Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: payload))
                try expect(response.status == 500, "A failed durable write was reported as success or an invalid request")
                try expect(try store.snapshotRevisionToken() == before, "A failed API write changed the published library")
            }
        }
        let officialCLI = "/Applications/Lattice.app/Contents/MacOS/LatticeCLI"
        if FileManager.default.isExecutableFile(atPath: officialCLI) {
            await run("Installed official LatticeCLI reads the independent server over real TCP") {
                let fixture = store.papers.first { $0.citekey == "SyntheticSearch2026" }!
                let commands = [
                    ["status"], ["search", "--query", "synthetic fixture", "--limit", "7"],
                    ["get-paper", "--id", fixture.id.uuidString, "--include", "library", "--include", "pdf_path", "--include", "abstract"],
                    ["get-paper-by-reference", "--reference", "SYNTHETICSEARCH2026"],
                    ["get-csl-item", "--reference", "SyntheticSearch2026"], ["get-csl-item", "--reference", fixture.id.uuidString],
                    ["collections"], ["tags"]
                ]
                for args in commands {
                    let result = try await cli(executable: officialCLI, port: port, arguments: args)
                    try expect(result.status == 0, "Official CLI \(args.first!) failed: \(result.error)")
                    let value = try JSONSerialization.jsonObject(with: result.output)
                    if args.first == "get-csl-item" {
                        try expect((value as? [String: Any])?["type"] as? String == "article-journal", "Official CLI did not retrieve cslItem")
                    } else if args.first == "status" {
                        let object = value as? [String: Any] ?? [:]
                        try expect(object["effectiveReadOnly"] as? Bool == true && (object["capabilities"] as? [String])?.contains("search") == true, "CLI read-only policy/capabilities are incorrect")
                    } else if args.first == "search" {
                        let hits = (value as? [String: Any])?["papers"] as? [[String: Any]] ?? []
                        try expect(hits.count == 1 && hits.first?["id"] as? String == fixture.id.uuidString, "Official CLI search did not decode '+' query spaces")
                    } else if args.first == "get-paper" || args.first == "get-paper-by-reference" {
                        try expect((value as? [String: Any])?["id"] as? String == fixture.id.uuidString, "Official CLI resolved the wrong paper")
                    }
                }
                let absent = try await cli(executable: officialCLI, port: port, arguments: ["get-paper-by-reference", "--reference", "SyntheticSearch"])
                try expect(absent.status != 0, "Official CLI accepted a fuzzy citekey as exact")
                var snapshot = store.snapshot
                var ambiguous = fixture
                ambiguous.id = UUID()
                ambiguous.title = "Synthetic ambiguous key fixture"
                snapshot.papers.append(ambiguous)
                store.replaceSnapshot(snapshot)
                let duplicate = try await cli(executable: officialCLI, port: port, arguments: ["get-paper-by-reference", "--reference", "SyntheticSearch2026"])
                try expect(duplicate.status != 0, "Official CLI silently picked one of multiple exact citekey matches")
            }
        } else { print("SKIP: optional installed LatticeCLI compatibility (executable not available)") }
        for failure in failures { print("FAIL: \(failure)") }
        print("Local API TCP tests: \(passed) passed, \(failures.count) failed")
        server.stop()
        try? FileManager.default.removeItem(at: root)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, body: () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw APITestFailure(description: message) }
    }
    private static func jsonObject(_ response: TCPResponse) throws -> [String: Any] {
        guard response.status == 200, let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw APITestFailure(description: "Expected HTTP 200 JSON object, got \(response.status)")
        }
        return object
    }
    private nonisolated static func cli(executable: String, port: Int, arguments: [String]) async throws -> (status: Int32, output: Data, error: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LATTICE_CLI_BASE_URL"] = "http://127.0.0.1:\(port)"
            environment["LATTICE_CLI_READONLY"] = "1"
            process.environment = environment
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data, String(data: diagnostics, encoding: .utf8) ?? "")
        }.value
    }
    private static func request(port: Int, method: String = "GET", path: String, headers: [String: String] = [:], body: Data = Data(), fragmented: Bool = false) async throws -> TCPResponse {
        var fields = headers
        fields["Host"] = "127.0.0.1:\(port)"
        fields["Content-Length"] = String(body.count)
        let header = "\(method) \(path) HTTP/1.1\r\n" + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        let chunks = fragmented ? [Data(header.utf8), body] : [Data(header.utf8) + body]
        return try TCPResponse(await exchange(port: port, chunks: chunks))
    }
    private nonisolated static func exchange(port: Int, chunks: [Data]) async throws -> Data {
        try await Task.detached {
            let descriptor = try connectSocket(host: "127.0.0.1", port: port)
            defer { Darwin.close(descriptor) }
            for chunk in chunks {
                try chunk.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                        guard count > 0 else { throw APITestFailure(description: "send failed: \(errno)") }
                        sent += count
                    }
                }
                if chunks.count > 1 { usleep(20_000) }
            }
            Darwin.shutdown(descriptor, SHUT_WR)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!, $0.count, 0) }
                if count == 0 { return result }
                guard count > 0 else { throw APITestFailure(description: "recv failed: \(errno)") }
                result.append(contentsOf: buffer.prefix(count))
            }
        }.value
    }
    private nonisolated static func connectSocket(host: String, port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw APITestFailure(description: "socket failed") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var suppressSIGPIPE: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { Darwin.close(descriptor); throw APITestFailure(description: "Invalid test host") }
        var status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status != 0, errno == EINPROGRESS {
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if poll(&descriptorEvent, 1, 1000) > 0,
               getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 {
                status = 0
            }
        }
        guard status == 0 else { let error = errno; Darwin.close(descriptor); throw APITestFailure(description: "connect failed: \(error)") }
        _ = fcntl(descriptor, F_SETFL, originalFlags)
        return descriptor
    }
    private nonisolated static func canConnect(host: String, port: Int) async -> Bool {
        await Task.detached {
            guard let descriptor = try? connectSocket(host: host, port: port) else { return false }
            Darwin.close(descriptor)
            return true
        }.value
    }
    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0 && inspected == 0 else { throw APITestFailure(description: "Could not choose an isolated port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private static func localIPv4Addresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        var current = head
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            // VPN/TUN interfaces can accept every port through a local proxy.
            // They are not evidence that our listener is bound to a LAN address.
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) == 0 else { continue }
            guard let raw = interface.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil { addresses.insert(String(cString: buffer)) }
        }
        return addresses
    }
    private static func listeningEndpoints(port: Int) throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(getpid()), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw APITestFailure(description: "Could not inspect test-process listener") }
        return Set(String(data: data, encoding: .utf8)!.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
    }
    private static func minimalPDF() -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>"]
        var output = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let crossReference = output.utf8.count
        output += "xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { output += String(format: "%010d 00000 n \n", offset) }
        output += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n"
        return Data(output.utf8)
    }
}
