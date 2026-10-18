import Foundation

struct LatticeImportSummary {
    var discovered = 0
    var imported = 0
    var skipped = 0
    var collections = 0
    var tags = 0
    var pdfReferences = 0
    var expectedPaperCount: Int?
    var warnings: [String] = []

    var text: String {
        "从 Lattice 读取 \(discovered) 篇，导入 \(imported) 篇，跳过已有 \(skipped) 篇；\(collections) 个文集，\(tags) 个标签，\(pdfReferences) 个 PDF 引用。"
    }
}

/// Uses only the app's supported read commands. It never opens the source database
/// or changes Lattice preferences, entitlement, metadata, or files.
enum LatticeImportService {
    @MainActor
    static func importFromRunningLattice(
        into store: LibraryStore,
        expectedPaperCount: Int? = nil,
        cliExecutablePath: String? = nil
    ) async throws -> LatticeImportSummary {
        let library = try await Task.detached(priority: .userInitiated) {
            try readRunningLibrary(expectedPaperCount: expectedPaperCount, cliExecutablePath: cliExecutablePath)
        }.value
        return try merge(library, into: store, expectedPaperCount: expectedPaperCount)
    }

    @MainActor
    static func importMetadataSnapshot(
        at url: URL,
        into store: LibraryStore,
        expectedPaperCount: Int? = nil
    ) async throws -> LatticeImportSummary {
        let library = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(LatticeLibraryMetadata.self, from: Data(contentsOf: url))
        }.value
        return try merge(library, into: store, expectedPaperCount: expectedPaperCount)
    }

    private static func readRunningLibrary(expectedPaperCount: Int?, cliExecutablePath: String?) throws -> LatticeLibraryMetadata {
        let candidates = [
            "/Applications/Lattice.app/Contents/MacOS/LatticeCLI",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Lattice.app/Contents/MacOS/LatticeCLI").path
        ]
        guard let executable = (cliExecutablePath.map { [$0] } ?? candidates)
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw LatticeImportError.message("没有找到 LatticeCLI。请安装 Lattice 3.0 或更新版本。")
        }
        let status: LatticeStatus = try run(executable, arguments: ["status"])
        guard status.ok else { throw LatticeImportError.message("Lattice 的 Local API 尚未就绪。") }
        guard status.capabilities.contains("search"), status.capabilities.contains("paper-detail") else {
            throw LatticeImportError.message("当前 Lattice Local API 不提供文献查询和详情读取。")
        }

        let collections: [LatticeCollectionMetadata] = try run(executable, arguments: ["collections"])
        let tags: [LatticeTagMetadata] = try run(executable, arguments: ["tags"])
        let recent: LatticeSearchResult = try run(executable, arguments: ["search", "--limit", "50"])
        var hits = Dictionary(recent.papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wasCapped = recent.papers.count >= 50

        if wasCapped {
            // The API caps each query at 50 and ignores page/offset. Broaden the
            // discovery across independent literal searches; do not pretend this
            // is pagination or that the resulting set is inherently exhaustive.
            var queries = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)
            let unicodeTerms = recent.papers.flatMap { hit in
                (hit.title + " " + (hit.authorsDisplay ?? ""))
                    .split { $0.isWhitespace || $0.isPunctuation }
                    .map(String.init)
                    .filter { $0.contains(where: { !$0.isASCII }) }
            }
            queries.append(contentsOf: Array(Set(unicodeTerms)).sorted().prefix(30))
            for query in queries {
                try Task.checkCancellation()
                if let expectedPaperCount, hits.count >= expectedPaperCount { break }
                let result: LatticeSearchResult = try run(
                    executable, arguments: ["search", "--query", query, "--limit", "50"]
                )
                for hit in result.papers { hits[hit.id] = hit }
            }
        }

        var papers: [LatticePaperMetadata] = []
        for id in hits.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let paper: LatticePaperMetadata = try run(executable, arguments: [
                "get-paper", "--id", id.uuidString,
                "--include", "library", "--include", "pdf_path", "--include", "abstract"
            ])
            guard paper.id == id else { throw LatticeImportError.message("Lattice 返回的文献 ID 与请求不一致。") }
            papers.append(paper)
        }
        return LatticeLibraryMetadata(papers: papers, collections: collections, tags: tags, discoveryWasCapped: wasCapped)
    }

    private static func run<Value: Decodable>(_ executable: String, arguments: [String]) throws -> Value {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LATTICE_CLI_READONLY"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Consume stdout before waiting, so large search results cannot fill the pipe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LatticeImportError.message(
                detail.isEmpty
                    ? "LatticeCLI 读取失败（\(process.terminationStatus)）。请保持 Lattice 运行并启用 Local API。"
                    : "LatticeCLI：\(detail)"
            )
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    @MainActor
    private static func merge(
        _ library: LatticeLibraryMetadata,
        into store: LibraryStore,
        expectedPaperCount: Int?
    ) throws -> LatticeImportSummary {
        guard Set(library.papers.map(\.id)).count == library.papers.count else {
            throw LatticeImportError.message("读取结果包含重复文献 ID，未写入本地文库。")
        }
        var summary = LatticeImportSummary(
            discovered: library.papers.count,
            expectedPaperCount: expectedPaperCount
        )
        if let expectedPaperCount, expectedPaperCount != library.papers.count {
            summary.warnings.append("Lattice 预期 \(expectedPaperCount) 篇，本次发现 \(library.papers.count) 篇，请核对是否有遗漏。")
        } else if expectedPaperCount == nil, library.discoveryWasCapped ?? true {
            summary.warnings.append("Lattice API 每次最多返回 50 篇；本次合并多次搜索结果，仍可能遗漏无法被这些关键词检索的文献。")
        }
        if library.papers.allSatisfy({ $0.rating != nil && $0.dateAdded.flatMap(ISO8601DateFormatter().date) != nil }) {
            summary.warnings.append("评分和添加日期由已核对的界面快照补充，日期精度为一天。笔记、批注和次要附件未迁移。")
        } else {
            summary.warnings.append("Lattice API 不提供评分、笔记、原添加日期、批注和次要附件；这些内容未迁移。")
        }

        var snapshot = store.snapshot
        var collectionMap: [UUID: UUID] = [:]
        var paths = Dictionary(snapshot.collections.map { ($0.id, collectionPath($0.id, in: snapshot.collections)) }, uniquingKeysWith: { first, _ in first })
        var pathToID = Dictionary(paths.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for (index, source) in library.collections.sorted(by: { $0.depth < $1.depth }).enumerated() {
            if snapshot.collections.contains(where: { $0.id == source.id }) {
                collectionMap[source.id] = source.id
            } else if let existing = pathToID[source.path] {
                collectionMap[source.id] = existing
            } else {
                let parentPath = source.path.split(separator: "/").dropLast().joined(separator: "/")
                let collection = PaperCollection(
                    id: source.id, name: source.name, parentID: pathToID[parentPath], sortIndex: index
                )
                snapshot.collections.append(collection)
                paths[source.id] = source.path
                pathToID[source.path] = source.id
                collectionMap[source.id] = source.id
            }
        }
        var tagMap: [UUID: UUID] = [:]
        for (index, source) in library.tags.enumerated() {
            if let existing = snapshot.tags.first(where: {
                $0.id == source.id || $0.name.caseInsensitiveCompare(source.name) == .orderedSame
            }) {
                tagMap[source.id] = existing.id
            } else {
                snapshot.tags.append(PaperTag(
                    id: source.id, name: source.name, colorHex: source.colorHex ?? "#5B8DEF", sortIndex: index
                ))
                tagMap[source.id] = source.id
            }
        }

        for source in library.papers {
            var paper = source.asPaper
            if snapshot.papers.contains(where: { existing in
                existing.id == paper.id ||
                (!paper.doi.isEmpty && existing.doi.caseInsensitiveCompare(paper.doi) == .orderedSame) ||
                (!paper.citekey.isEmpty && existing.citekey.caseInsensitiveCompare(paper.citekey) == .orderedSame)
            }) {
                summary.skipped += 1
                continue
            }
            paper.collectionIDs = (source.collections ?? []).compactMap { collectionMap[$0.id] }
            paper.tagIDs = (source.tags ?? []).compactMap { tagMap[$0.id] }
            if let path = source.pdfPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                var attachment = Attachment(
                    kind: .pdf, filePath: path, displayName: url.lastPathComponent,
                    bookmarkData: bookmark, missing: !FileManager.default.isReadableFile(atPath: path)
                )
                attachment.isReadOnlyReference = true
                paper.attachments = [attachment]
                summary.pdfReferences += 1
            }
            snapshot.papers.append(paper)
            summary.imported += 1
        }
        summary.collections = library.collections.count
        summary.tags = library.tags.count
        try store.replaceSnapshotDurably(snapshot)
        store.statusMessage = summary.text
        return summary
    }

    private static func collectionPath(_ id: UUID, in collections: [PaperCollection], visited: Set<UUID> = []) -> String {
        guard !visited.contains(id), let collection = collections.first(where: { $0.id == id }) else { return "" }
        guard let parentID = collection.parentID else { return collection.name }
        let parent = collectionPath(parentID, in: collections, visited: visited.union([id]))
        return parent.isEmpty ? collection.name : parent + "/" + collection.name
    }
}

private enum LatticeImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private struct LatticeStatus: Decodable {
    let ok: Bool
    let capabilities: [String]
}

private struct LatticeSearchResult: Decodable {
    let papers: [LatticeSearchHit]
}

private struct LatticeSearchHit: Decodable {
    let id: UUID
    let title: String
    let authorsDisplay: String?
}

struct LatticeLibraryMetadata: Decodable {
    let papers: [LatticePaperMetadata]
    let collections: [LatticeCollectionMetadata]
    let tags: [LatticeTagMetadata]
    var discoveryWasCapped: Bool?
}

struct LatticeCollectionMetadata: Decodable {
    let id: UUID
    let name: String
    let path: String
    let depth: Int
}

struct LatticeTagMetadata: Decodable {
    let id: UUID
    let name: String
    let colorHex: String?
}

struct LatticePaperMetadata: Decodable {
    let id: UUID
    let title: String
    let authors: [String]
    let citekey: String?
    let rating: Int?
    let dateAdded: String?
    let year: Int?
    let journal: String?
    let doi: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let isbn: String?
    let paperType: String?
    let abstract: String?
    let pdfPath: String?
    let collections: [LatticeCollectionMetadata]?
    let tags: [LatticeTagMetadata]?
    let cslItem: LatticeCSLMetadata?

    var asPaper: Paper {
        var paper = Paper(id: id)
        paper.title = title
        paper.authors = authors
        paper.citekey = citekey ?? ""
        if let rating { paper.rating = min(5, max(0, rating)) }
        if let dateAdded, let date = ISO8601DateFormatter().date(from: dateAdded) {
            paper.dateAdded = date
        }
        paper.year = year
        paper.paperType = PaperType(rawValue: paperType ?? "") ?? PaperType.fromBibTeX(paperType ?? "misc")
        paper.journal = journal ?? cslItem?.containerTitle ?? ""
        paper.doi = doi ?? cslItem?.doi ?? ""
        paper.volume = volume ?? cslItem?.volume ?? ""
        paper.issue = issue ?? cslItem?.issue ?? ""
        paper.pages = pages ?? cslItem?.page ?? ""
        paper.isbn = isbn ?? cslItem?.isbn ?? ""
        paper.abstract = abstract ?? ""
        paper.publisher = cslItem?.publisher ?? ""
        paper.address = cslItem?.publisherPlace
        paper.url = cslItem?.url ?? ""
        paper.language = cslItem?.language ?? ""
        paper.edition = cslItem?.edition ?? ""
        paper.event = cslItem?.eventTitle ?? ""
        if paper.paperType == .inProceedings || paper.paperType == .inBook || paper.paperType == .inCollection {
            paper.bookTitle = cslItem?.containerTitle ?? ""
        }
        paper.editors = cslItem?.editor?.map(\.displayName)
        if let arxivID = paper.arxivLookupID {
            paper.eprint = arxivID
            paper.eprintType = "arXiv"
        }
        return paper
    }
}

struct LatticeCSLMetadata: Decodable {
    let containerTitle: String?
    let doi: String?
    let volume: String?
    let issue: String?
    let page: String?
    let isbn: String?
    let publisher: String?
    let publisherPlace: String?
    let url: String?
    let language: String?
    let edition: String?
    let eventTitle: String?
    let editor: [Name]?

    enum CodingKeys: String, CodingKey {
        case containerTitle = "container-title"
        case doi = "DOI", isbn = "ISBN", url = "URL"
        case volume, issue, page, publisher, language, edition, editor
        case publisherPlace = "publisher-place"
        case eventTitle = "event-title"
    }

    struct Name: Decodable {
        let family: String?
        let given: String?
        let literal: String?
        var displayName: String { literal ?? [given, family].compactMap { $0 }.joined(separator: " ") }
    }
}
