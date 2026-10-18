# Native CLI, MCP, agent skill, and browser connector

## Evidence and scope

The installed Lattice 3.0 CLI sidecar read/write/runtime documents and `API_COMPATIBILITY.md` define the command behavior and observed HTTP routes. The reconstruction implements its own native Swift executable. It does not modify, wrap for writes, or redistribute the original LatticeCLI. All executed mutation tests use synthetic records, PDFs, and an isolated reconstructed LocalAPIServer.

Sources are under `Sources/PaperManagerCLI/`; `scripts/build-cli.sh` produces `.build/cli/PaperManagerCLI`, with an optional `PAPERMANAGER_CLI_BUILD_DIR` destination override. The packaged main app includes this executable at `Contents/Helpers/PaperManagerCLI` and sign the outer bundle after copying it. No global command or client configuration is installed.

## CLI

The executable supports `--version`, `--help`, `status`, `search`, `get-paper`, `get-paper-by-reference`, `get-csl-item`, `collections`, `tags`, `create-paper`, `attach-pdf`, `mcp`, `export-skill`, and `export-mcp-config`.

Read commands use the routes recorded from the published original CLI. Citekey resolution is exact, trimmed, and case-insensitive; zero or multiple matches are errors. `get-csl-item` extracts the returned `cslItem` object unchanged. Repeated `--include` accepts abstract, pdf_path, collections, tags and library. Collections and tags preserve the server response wrappers.

Default configuration is `http://127.0.0.1:29467` and client read-only. Override the host root with `--base-url`, or the port with `--port`; environment equivalents are `PAPERMANAGER_CLI_BASE_URL`, `PAPERMANAGER_CLI_PORT` and `PAPERMANAGER_CLI_READONLY`. Only explicit `http://` loopback hosts, ports 1024–65535, and no credentials, paths, queries or fragments are accepted. URLSession uses finite timeouts, ephemeral storage, and refuses redirects.

Writes require `--allow-write` or an explicitly configured read-only value of `0`/`false`, and then the server's status must independently allow the required capability. Schema/UTF-8 limits are checked locally. Replacement and `--force` are never inferred from a conflict. API warnings, pending enrichment and duplicate response data are preserved. Upload accepts a readable regular PDF of at most 200,000,000 bytes and copies through the app's managed upload endpoint; the connector does not move source files.

Successful library commands print exactly one JSON value on stdout and exit 0. Local usage, configuration or client policy errors exit 2; transport and API operation errors exit 1. Errors are JSON diagnostics on stderr, with original response details when available. Help, version, and an exported skill without an output destination intentionally print text.

## MCP and exported skill

`PaperManagerCLI mcp` implements the initialize / initialized / tools/list / tools/call lifecycle over UTF-8 newline-delimited JSON-RPC stdio. Supported negotiated revisions are 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25. Stdout contains only protocol frames. This follows the [2025-11-25 MCP stdio specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports); it does not claim implementation of later protocol revisions or Streamable HTTP.

The default tool list includes status, search, exact identity/detail/CSL reads, collections, tags, and skill text. An explicitly writable process also lists create and attachment tools, with write annotations; the backend's live read-only policy is still enforced. Invalid schemas and operations produce tool errors rather than fabricated success.

`export-skill` prints an independent Skill Markdown document including the resolved executable path. `--output PATH` creates a new file without overwriting an existing file. `export-mcp-config` prints generic `mcpServers` JSON with the actual executable, `mcp` argument and loopback/read-only environment. Client configuration formats differ; exporting does not register a server or change any coding agent's settings.

## Browser source package

`BrowserExtension/` contains an MV3 popup and dependency-free ES modules for active-page metadata capture and API workflows. It reads collection/tag options, supports editable preview, separate duplicate/PDF replacement choices, and optional PDF upload. File-library unavailability is shown as metadata-only; legacy conflict and read-only states prevent writes as specified. It never silently retries replacement.

The manifest uses temporary active-tab access and loopback host access. Cross-origin PDFs require user-selected local files instead of expanding website permissions. No extension was installed or permission requested. See `BrowserExtension/README.md` for the source-package and packaging boundary.

## Verification

`Tests/Connector/run.sh` builds and signs the native connector, starts the actual Swift LocalAPIServer using an isolated fixture library, and runs CLI subprocesses, persistent MCP processes, and browser-core JavaScript against its real TCP endpoint. Academic-page extraction uses local Highwire and JSON-LD fixtures. Tests use system-assigned loopback ports and synthetic PDF files; no original Lattice records, files, preferences or running API are mutated.

The final connector regression completed with **12 passed, 0 failed**. The separate App Intents regression completed with **6 passed, 0 failed**, including persisted template queries and explicit missing-template rejection; it does not establish Shortcuts platform registration.

Covered behavior includes read commands/CSL, exact/ambiguous citekeys, JSON stdout and exit codes, malformed/remote URLs, redirect refusal, UTF-8 schema rejection, client and server read-only, metadata creation, duplicate preservation, force guards, protected sources, MCP default read-only and explicit writes, non-installing exporters, browser metadata capture, optional upload, metadata-only fallback and location-conflict handling.

Native build/signature and TCP checks do not establish browser installation or popup interaction. Safari packaging/signing and a real browser UI acceptance remain separate. On this machine the installed CLT does not provide `safari-web-extension-converter`; no Xcode installation or Safari signing was attempted. Current Apple documentation also supports temporary source-folder testing and App Store Connect cloud packaging, so missing local Xcode is not presented as a universal barrier to all Safari testing; none of those workflows was executed here.
