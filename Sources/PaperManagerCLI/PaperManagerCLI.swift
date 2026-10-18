import Darwin
import Foundation

@main
struct PaperManagerCLI {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        if raw.contains("--help") || raw == ["help"] { print(ConnectorResources.help); return }
        if raw == ["--version"] { print("1.0.0"); return }
        do {
            let arguments = try CLIArguments(raw)
            let configuration = try ConnectorConfiguration(arguments: arguments)
            let client = ConnectorClient(configuration: configuration)
            if arguments.command == "mcp" {
                try arguments.validateOptions([])
                var server = MCPServer(client: client)
                await server.run()
                return
            }
            if arguments.command == "export-skill" {
                try arguments.validateOptions(["output"])
                let skill = ConnectorResources.skill(configuration: configuration)
                if let path = arguments.value("output") {
                    guard !FileManager.default.fileExists(atPath: path) else { throw ConnectorFailure(description: "Skill destination already exists; choose a new file") }
                    try Data(skill.utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                    try writeJSON(["path": URL(fileURLWithPath: path).standardizedFileURL.path])
                } else { print(skill) }
                return
            }
            if arguments.command == "export-mcp-config" {
                try arguments.validateOptions([])
                let executable = ConnectorResources.executablePath
                try writeJSON(["mcpServers": ["papermanager": ["command": executable, "args": ["mcp"],
                    "env": ["PAPERMANAGER_CLI_BASE_URL": configuration.baseURL.absoluteString,
                            "PAPERMANAGER_CLI_READONLY": configuration.readOnly ? "1" : "0"]]]])
                return
            }
            let result: Any
            switch arguments.command {
            case "status": try arguments.validateOptions([]); result = try await client.status()
            case "search":
                try arguments.validateOptions(["query", "limit"])
                let limit = Int(arguments.value("limit") ?? "10") ?? 0
                guard (1...50).contains(limit) else { throw ConnectorFailure(description: "--limit must be 1...50") }
                result = try await client.request("/api/v1/search", query: [.init(name: "q", value: arguments.value("query") ?? ""), .init(name: "limit", value: String(limit))])
            case "get-paper":
                try arguments.validateOptions(["id", "include"])
                let id = try arguments.require("id")
                guard UUID(uuidString: id) != nil else { throw ConnectorFailure(description: "--id must be a UUID") }
                result = try await client.paper(reference: id, includes: arguments.values["include"] ?? [])
            case "get-paper-by-reference", "get-csl-item":
                try arguments.validateOptions(["reference"])
                let paper = try await client.paper(reference: arguments.require("reference"))
                if arguments.command == "get-csl-item" {
                    guard let csl = paper["cslItem"] as? [String: Any] else { throw ConnectorFailure(description: "No CSL object in paper detail", exitCode: 1) }
                    result = csl
                } else { result = paper }
            case "collections": try arguments.validateOptions([]); result = try await client.request("/api/v1/collections")
            case "tags": try arguments.validateOptions([]); result = try await client.request("/api/v1/tags")
            case "create-paper":
                try arguments.validateOptions(["title", "authors", "year", "journal", "abstract", "doi", "volume", "issue", "pages", "isbn", "type", "url", "eprint", "eprint-type", "eprint-class", "collection", "tag", "strategy", "enrich"])
                var payload: [String: Any] = ["title": try arguments.require("title"), "strategy": arguments.value("strategy") ?? "skip"]
                for field in ["journal", "abstract", "doi", "volume", "issue", "pages", "isbn", "url", "eprint"] {
                    if let value = arguments.value(field) { payload[field] = value }
                }
                if let value = arguments.value("type") { payload["paperType"] = value.lowercased() }
                if let value = arguments.value("eprint-type") { payload["eprintType"] = value }
                if let value = arguments.value("eprint-class") { payload["eprintClass"] = value }
                if let raw = arguments.value("authors") {
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                        guard let names = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else { throw ConnectorFailure(description: "--authors JSON must be a string array") }
                        payload["authors"] = names
                    } else { payload["authors"] = raw }
                }
                if let raw = arguments.value("year") {
                    guard let year = Int(raw) else { throw ConnectorFailure(description: "--year must be an integer") }
                    payload["year"] = year
                }
                if let names = arguments.values["collection"] { payload["collections"] = names }
                if let names = arguments.values["tag"] { payload["tags"] = names }
                if arguments.flags.contains("enrich") { payload["enrich"] = true }
                result = try await client.create(payload)
            case "attach-pdf":
                try arguments.validateOptions(["id", "pdf-path", "force"])
                result = try await client.attach(id: arguments.require("id"), path: arguments.require("pdf-path"), force: arguments.flags.contains("force"))
            default: throw ConnectorFailure(description: "Unknown command: \(arguments.command). Use --help.")
            }
            try writeJSON(result)
        } catch {
            let failure = error as? ConnectorFailure ?? ConnectorFailure(description: error.localizedDescription, exitCode: 1)
            var details: [String: Any] = ["error": failure.description]
            if let response = failure.response { details["response"] = response }
            if let data = try? encodedJSON(details) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10])) }
            exit(failure.exitCode)
        }
    }
}
