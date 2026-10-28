import Foundation
import MachO

enum ConnectorResources {
    static var executablePath: String {
        var count: UInt32 = 0
        _NSGetExecutablePath(nil, &count)
        var buffer = [CChar](repeating: 0, count: Int(count))
        let result = buffer.withUnsafeMutableBufferPointer { _NSGetExecutablePath($0.baseAddress, &count) }
        guard result == 0 else { return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
    static let help = """
    PaperManagerCLI 1.1.0 — native loopback connector

    PaperManagerCLI [--base-url http://127.0.0.1:PORT] [--read-only|--allow-write] COMMAND [OPTIONS]

    Read commands:
      status
      search [--query TEXT] [--limit 1..50]
      get-paper --id UUID [--include abstract|pdf_path|collections|tags|library]...
      get-paper-by-reference --reference UUID_OR_EXACT_CITEKEY
      get-csl-item --reference UUID_OR_EXACT_CITEKEY
      collections
      tags
    Explicit writes:
      create-paper --title TITLE [--authors TEXT_OR_JSON_ARRAY] [--year YEAR]
        [--doi DOI] [--journal SOURCE] [--abstract TEXT] [--isbn ISBN] [--type TYPE]
        [--volume N] [--issue N] [--pages RANGE] [--url URL] [--eprint ID]
        [--eprint-type TYPE] [--eprint-class CLASS] [--collection PATH]... [--tag NAME]...
        [--strategy skip|replace] [--enrich]
      attach-pdf --id UUID --pdf-path PATH [--force]
    Agent integration:
      mcp                          Newline JSON-RPC stdio MCP server; read-only by default
      export-skill [--output PATH]  Markdown skill text, or create a new SKILL.md file
      export-mcp-config            Generic MCP client JSON configuration
      --help / --version

    Environment: PAPERMANAGER_CLI_BASE_URL, PAPERMANAGER_CLI_PORT (default 29467),
    PAPERMANAGER_CLI_READONLY (1/0/true/false; default 1).
    Only explicit HTTP loopback URLs without paths or credentials are accepted.
    Read/write success: one JSON value, exit 0. Usage/policy error: stderr, exit 2.
    API/transport error: stderr, exit 1. Warnings and duplicate responses are preserved.
    """

    static func skill(configuration: ConnectorConfiguration) -> String { """
    ---
    name: papermanager-cli
    description: Query and explicitly update a local PaperManager library through its native loopback connector.
    ---

    # PaperManager

    Executable for this exported integration: `\(executablePath)`.
    Connection for this exported integration: `\(configuration.baseURL.absoluteString)`.
    Start every command with `--base-url \(configuration.baseURL.absoluteString) --\(configuration.readOnly ? "read-only" : "allow-write")`.

    Use the app-distributed PaperManagerCLI executable or the path supplied by the user.
    Do not edit the library JSON or source PDFs directly to imitate an application operation.

    First run `PaperManagerCLI --base-url \(configuration.baseURL.absoluteString) --\(configuration.readOnly ? "read-only" : "allow-write") status`.
    The app must be running with Local API enabled at the exported connection address.
    If the app's port changes, export this skill again or explicitly update the connection.
    Client and server read-only policies are independent; the stricter policy always wins.

    Read workflows:
    1. `search --query TEXT --limit 10` returns candidates. Preserve ambiguity.
    2. `get-paper --id UUID` reads a confirmed identity. Request optional fields with repeated
       `--include abstract`, `--include pdf_path`, or `--include library`.
    3. `get-paper-by-reference --reference KEY` resolves an exact citekey or UUID only.
    4. `get-csl-item --reference KEY` returns the API's CSL object unchanged.
    5. `collections` and `tags` list assignable paths and names. Use exact returned values.

    Writes require an explicit user request and `--allow-write` (or an explicitly configured
    PAPERMANAGER_CLI_READONLY=0). Start duplicate handling with `--strategy skip`.
    Use `replace` only when replacement is requested. Never automatically retry a conflict
    with replacement or a PDF upload with `--force`.

    `create-paper --title TITLE` accepts known metadata, collection paths and tags.
    `attach-pdf --id UUID --pdf-path PATH` copies a readable PDF through the configured
    file library. No arbitrary remote URLs, trusted-folder access, or source-file moves
    are performed by this connector.

    A successful mutation is not necessarily a complete import: inspect warnings,
    alreadyExists, enrichmentStatus and PDF outcomes. Pending enrichment is not completed
    enrichment. A PDF path is metadata until the requested file is actually read by the
    agent's file or PDF tools.

    `mcp` exposes the same operations over stdio. Its default tool list is read-only.
    `export-mcp-config` emits generic client configuration without installing or enabling it.
    Library commands return one JSON value on stdout only on success. Keep stderr and
    exit status separate; do not treat a nonzero exit as a successful result.
    """ }
}
