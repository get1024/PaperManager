import CoreFoundation
import Foundation

struct MCPServer {
    let client: ConnectorClient
    private(set) var initialized = false

    mutating func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= 1_048_576 else {
                try? writeJSON(error(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB")); continue
            }
            let request: [String: Any]
            do {
                guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw ConnectorFailure(description: "Expected a JSON-RPC object") }
                request = value
            } catch {
                try? writeJSON(self.error(id: NSNull(), code: -32700, message: "Invalid JSON")); continue
            }
            let id = request["id"]
            guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                if let id { try? writeJSON(error(id: id, code: -32600, message: "Invalid JSON-RPC request")) }
                continue
            }
            if method.hasPrefix("notifications/") { continue }
            guard let id else { continue }
            do {
                let result: Any
                switch method {
                case "initialize":
                    initialized = true
                    let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-11-25"
                    let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                    result = ["protocolVersion": supported.contains(requested) ? requested : "2025-11-25",
                              "capabilities": ["tools": ["listChanged": false]],
                              "serverInfo": ["name": "papermanager", "version": "1.0.0"],
                              "instructions": "Read-only by default. Exact UUID/citekey resolution. Writes require an explicitly configured --allow-write and a writable local API."]
                case "ping": result = [:] as [String: Any]
                case "tools/list":
                    guard initialized else { throw ConnectorFailure(description: "Initialize the MCP session first") }
                    result = ["tools": toolDefinitions()]
                case "tools/call":
                    guard initialized else { throw ConnectorFailure(description: "Initialize the MCP session first") }
                    guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else { throw ConnectorFailure(description: "Tool name is required") }
                    do {
                        let value = try await call(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
                        if let text = value as? String { result = ["content": [["type": "text", "text": text]], "isError": false] }
                        else {
                            var response: [String: Any] = ["content": [["type": "text", "text": String(decoding: try encodedJSON(value), as: UTF8.self)]], "isError": false]
                            if let object = value as? [String: Any] { response["structuredContent"] = object }
                            result = response
                        }
                    } catch {
                        var details: [String: Any] = ["error": String(describing: error)]
                        if let response = (error as? ConnectorFailure)?.response { details["response"] = response }
                        result = ["content": [["type": "text", "text": String(decoding: try encodedJSON(details), as: UTF8.self)]], "isError": true]
                    }
                default:
                    try writeJSON(error(id: id, code: -32601, message: "Method not found")); continue
                }
                try writeJSON(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                try? writeJSON(self.error(id: id, code: -32602, message: String(describing: error)))
            }
        }
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func toolDefinitions() -> [[String: Any]] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [], writes: Bool = false) -> [String: Any] {
            ["name": "papermanager_" + name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": !writes, "destructiveHint": writes, "openWorldHint": writes]]
        }
        var tools = [
            tool("status", "Read local API status and effective read-only policy."),
            tool("search", "Search lightweight candidates; do not select an ambiguous fuzzy hit.", ["query": text("Title, author, source, citekey or year"), "limit": ["type": "integer", "minimum": 1, "maximum": 50]]),
            tool("get_paper", "Get a confirmed UUID with opt-in fields.", ["id": text("Paper UUID"), "include": ["type": "array", "items": ["type": "string", "enum": ["abstract", "pdf_path", "collections", "tags", "library"]]]], required: ["id"]),
            tool("get_paper_by_reference", "Resolve UUID or exact case-insensitive citekey; ambiguity is an error.", ["reference": text("UUID or exact persisted citekey")], required: ["reference"]),
            tool("get_csl_item", "Return the API's CSL object without reconstructing it from display strings.", ["reference": text("UUID or exact citekey")], required: ["reference"]),
            tool("collections", "List existing assignable collection paths."),
            tool("tags", "List existing tags and colors."),
            tool("agent_skill", "Return instructions for using this connector safely.")
        ]
        if !client.configuration.readOnly {
            tools += [
                tool("create_paper", "Create a paper from explicit metadata. Replacement requires strategy=replace; preserve warnings and partial success.",
                     ["metadata": ["type": "object", "required": ["title"], "properties": ["title": text("Non-empty title, maximum 1024 UTF-8 bytes"), "authors": ["oneOf": [["type": "string"], ["type": "array", "items": ["type": "string"], "minItems": 1]]], "year": ["type": "integer"], "doi": text("DOI"), "journal": text("Source"), "abstract": text("Abstract"), "paperType": text("Active paper type"), "collections": ["type": "array", "items": ["type": "string"]], "tags": ["type": "array", "items": ["type": "string"]], "strategy": ["type": "string", "enum": ["skip", "replace"]]], "additionalProperties": true]], required: ["metadata"], writes: true),
                tool("attach_pdf", "Upload a local PDF to a confirmed paper. force=true requires explicit PDF replacement intent.", ["id": text("Paper UUID"), "path": text("Absolute readable PDF path"), "force": ["type": "boolean", "default": false]], required: ["id", "path"], writes: true)
            ]
        }
        return tools
    }

    private func call(name: String, arguments: [String: Any]) async throws -> Any {
        guard let definition = toolDefinitions().first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
            throw ConnectorFailure(description: "Unknown tool or unsupported arguments")
        }
        func required(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectorFailure(description: "\(key) must be a non-empty string") }
            return value
        }
        switch name {
        case "papermanager_status": return try await client.status()
        case "papermanager_search":
            if let value = arguments["query"], !(value is String) { throw ConnectorFailure(description: "query must be a string") }
            if let value = arguments["limit"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), value as? Int != nil else { throw ConnectorFailure(description: "limit must be an integer") }
            }
            let limit = arguments["limit"] as? Int ?? 10
            guard (1...50).contains(limit) else { throw ConnectorFailure(description: "limit must be 1...50") }
            return try await client.request("/api/v1/search", query: [.init(name: "q", value: arguments["query"] as? String ?? ""), .init(name: "limit", value: String(limit))])
        case "papermanager_get_paper":
            let id = try required("id")
            guard UUID(uuidString: id) != nil else { throw ConnectorFailure(description: "id must be a UUID") }
            if let value = arguments["include"], !(value is [String]) { throw ConnectorFailure(description: "include must be a string array") }
            return try await client.paper(reference: id, includes: arguments["include"] as? [String] ?? [])
        case "papermanager_get_paper_by_reference": return try await client.paper(reference: required("reference"))
        case "papermanager_get_csl_item":
            let paper = try await client.paper(reference: required("reference"))
            guard let csl = paper["cslItem"] as? [String: Any] else { throw ConnectorFailure(description: "Paper has no CSL object", exitCode: 1) }
            return csl
        case "papermanager_collections": return try await client.request("/api/v1/collections")
        case "papermanager_tags": return try await client.request("/api/v1/tags")
        case "papermanager_agent_skill": return ConnectorResources.skill
        case "papermanager_create_paper":
            guard let metadata = arguments["metadata"] as? [String: Any] else { throw ConnectorFailure(description: "metadata object is required") }
            return try await client.create(metadata)
        case "papermanager_attach_pdf":
            if let value = arguments["force"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ConnectorFailure(description: "force must be a boolean") }
            }
            return try await client.attach(id: required("id"), path: required("path"), force: arguments["force"] as? Bool ?? false)
        default: throw ConnectorFailure(description: "Unknown tool: \(name)")
        }
    }
}
