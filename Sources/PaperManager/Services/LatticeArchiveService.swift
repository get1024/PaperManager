import CryptoKit
import Darwin
import Foundation

struct LatticeArchiveResult {
    var snapshot: LibrarySnapshot
    var manifestData: Data
    var libraryData: Data
    var dataSHA256: String
    var archivePDFCount: Int
    var attachmentFileCount: Int
    var sourceReferenceCount: Int
    var templateCount: Int
    var warnings: [String]

    var summary: [String: Any] {
        ["papers": snapshot.papers.count, "collections": snapshot.collections.count,
         "tags": snapshot.tags.count, "annotations": snapshot.papers.reduce(0) { $0 + $1.annotations.count },
         "notes": snapshot.papers.filter { !$0.notes.isEmpty }.count,
         "ratedPapers": snapshot.papers.filter { $0.rating != 0 }.count,
         "originalAddedDates": snapshot.papers.count, "archivePDFs": archivePDFCount,
         "attachmentFiles": attachmentFileCount, "sourcePDFReferences": sourceReferenceCount,
         "materializedPDFs": snapshot.papers.flatMap(\.attachments).filter { $0.kind == .pdf && !$0.isReadOnlyReference && !$0.missing }.count,
         "templates": templateCount, "dataSHA256": dataSHA256, "warnings": warnings]
    }
}

/// Reads the observed Lattice 3.0 schema-2 backup. PDF bytes stay in the ZIP;
/// accessible source references are explicitly marked read-only in our own library.
enum LatticeArchiveService {
    private struct ArchivedAttachment {
        var paperID: UUID
        var id: UUID
        var filename: String
        var addedAt: Date
        var member: String?
        var outputName: String {
            let ext = URL(fileURLWithPath: filename).pathExtension
            let suffix = !ext.isEmpty && ext.count <= 16 && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
                ? "." + ext.lowercased() : ""
            return "attachment-\(paperID.uuidString)-\(id.uuidString)\(suffix)"
        }
    }

    static func readArchive(at url: URL, fallbackSnapshot: LibrarySnapshot? = nil,
                            materializePDFsTo directory: URL? = nil) throws -> LatticeArchiveResult {
        let archive = try LatticeZIPInventory(url: url)
        let manifestData = try archive.readJSONMember("manifest.json", maximumBytes: 1_048_576)
        let libraryData = try archive.readJSONMember("data.json", maximumBytes: 32 * 1_048_576)
        let manifest = try object(manifestData)
        guard try integer(manifest, "version", required: true) == 1,
              try integer(manifest, "schemaVersion", required: true) == 2 else {
            throw failure("暂不支持该 Lattice 备份版本。已验证的格式为 version 1 / schemaVersion 2。")
        }
        let counts = try dictionary(manifest, "counts")
        let payload = try object(libraryData)
        let papers = try records(payload, "papers")
        let collections = try records(payload, "collections")
        let tags = try records(payload, "tags")
        let annotations = try records(payload, "annotations")
        let templates = try records(payload, "templates")
        for (name, values) in [("papers", papers), ("collections", collections), ("tags", tags),
                               ("annotations", annotations), ("templates", templates)] {
            guard try integer(counts, name, required: true) == values.count else {
                throw failure("备份的 \(name) 数量与 manifest 不一致。")
            }
        }
        try uniqueIDs(papers, entity: "papers")
        try uniqueIDs(collections, entity: "collections")
        try uniqueIDs(tags, entity: "tags")
        try uniqueIDs(templates, entity: "templates")
        let archivedAttachments = try attachmentDTOs(in: papers)
        let attachmentFiles = archivedAttachments.compactMap(\.member)
        guard Set(attachmentFiles).count == attachmentFiles.count,
              try integer(counts, "attachmentFiles", required: true) == attachmentFiles.count else {
            throw failure("备份附件载荷重复，或数量与 manifest 不一致。")
        }
        for member in attachmentFiles { try archive.requirePayload(member) }
        var snapshot = LibrarySnapshot.empty
        snapshot.settings = fallbackSnapshot?.settings ?? .defaults
        let referencePapers = Dictionary((fallbackSnapshot?.papers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.collections = try collections.map { value in
            var collection = PaperCollection(id: try identifier(value, "id"), name: try string(value, "name", required: true))
            collection.sortIndex = try integer(value, "sortOrder", required: true)!
            collection.createdAt = fallbackSnapshot?.collections.first { $0.id == collection.id }?.createdAt ?? Date(timeIntervalSince1970: 0)
            if value["parentID"] != nil { collection.parentID = try identifier(value, "parentID") }
            return collection
        }
        let collectionIDs = Set(snapshot.collections.map(\.id))
        for collection in snapshot.collections {
            var visited: Set<UUID> = [collection.id]
            var parentID = collection.parentID
            while let parent = parentID {
                guard collectionIDs.contains(parent), visited.insert(parent).inserted else {
                    throw failure("备份文集包含未知父节点或循环关系。")
                }
                parentID = snapshot.collections.first { $0.id == parent }?.parentID
            }
        }
        snapshot.tags = try tags.map { value in
            let id = try identifier(value, "id")
            return PaperTag(id: id, name: try string(value, "name", required: true),
                colorHex: try string(value, "color", required: true), sortIndex: try integer(value, "sortOrder", required: true)!,
                createdAt: fallbackSnapshot?.tags.first { $0.id == id }?.createdAt ?? Date(timeIntervalSince1970: 0))
        }
        let tagIDs = Set(snapshot.tags.map(\.id))
        var archivePDFCount = 0
        var referenceCount = 0
        snapshot.papers = try papers.map { value in
            var paper = Paper()
            paper.id = try identifier(value, "id")
            paper.title = try string(value, "title", required: true)
            paper.authors = try strings(value, "authors", required: true)
            paper.editors = try strings(value, "editors")
            paper.translators = try strings(value, "translators")
            paper.citekey = try string(value, "bibtexKey", required: true)
            paper.paperType = try paperType(try string(value, "paperType", required: true))
            paper.year = try integer(value, "year")
            paper.dateAdded = try date(try string(value, "dateAdded", required: true))
            paper.dateModified = paper.dateAdded // No original modification date is present in this schema.
            paper.rating = try integer(value, "rating", required: true)!
            guard (0...5).contains(paper.rating) else { throw failure("备份评分超出 0–5。") }
            let fields: [(String, WritableKeyPath<Paper, String>)] = [
                ("journal", \.journal), ("booktitle", \.bookTitle), ("publisher", \.publisher),
                ("institution", \.institution), ("school", \.school), ("series", \.series),
                ("volume", \.volume), ("issue", \.issue), ("pages", \.pages), ("month", \.month),
                ("doi", \.doi), ("isbn", \.isbn), ("url", \.url), ("language", \.language),
                ("abstract", \.abstract), ("notes", \.notes), ("eventTitle", \.event),
                ("eventDate", \.eventDate), ("venue", \.venue), ("edition", \.edition),
                ("chapter", \.chapter), ("eprint", \.eprint), ("eprintType", \.eprintType),
                ("eprintClass", \.eprintClass), ("pubState", \.publicationState), ("howpublished", \.howPublished)
            ]
            for (key, path) in fields { paper[keyPath: path] = try string(value, key) }
            paper.subtitle = try optionalString(value, "subtitle")
            paper.address = try optionalString(value, "address")
            paper.organization = try optionalString(value, "organization")
            paper.type = try optionalString(value, "type")
            paper.urlDate = try optionalString(value, "urlDate")
            paper.collectionIDs = try identifiers(value, "collectionIDs")
            paper.tagIDs = try identifiers(value, "tagIDs")
            guard Set(paper.collectionIDs).isSubset(of: collectionIDs), Set(paper.tagIDs).isSubset(of: tagIDs) else {
                throw failure("备份文献引用了不存在的文集或标签。")
            }
            if value["extraFields"] != nil {
                let extra = try dictionary(value, "extraFields")
                paper.customFields = try extra.keys.sorted().map { key in
                    guard let content = extra[key] as? String else { throw failure("备份自定义字段的值必须是文本。") }
                    return CustomField(key: key, value: content)
                }
            }
            if try boolean(value, "hasPDF", required: true) {
                archivePDFCount += 1
                guard archive.entries["pdfs/\(paper.id.uuidString).pdf"] != nil else {
                    throw failure("备份缺少 manifest 声明的主要 PDF。")
                }
                if let originalPath = try optionalString(value, "pdfPath"),
                   FileManager.default.fileExists(atPath: originalPath) {
                    paper.attachments = [Attachment(kind: .pdf, filePath: originalPath,
                        displayName: try string(value, "pdfFilename"), isReadOnlyReference: true)]
                } else if let reference = referencePapers[paper.id] {
                    paper.attachments = reference.attachments.filter { $0.id == reference.primaryPDF?.id }.map { attachment in
                        var protected = attachment
                        protected.isReadOnlyReference = true
                        let directPathExists = FileManager.default.fileExists(atPath: attachment.filePath)
                        if (try? attachment.resolvedURL()) == nil, directPathExists {
                            // A source bookmark may belong to a different app context.
                            // Keep the already accessible literal path in our own store.
                            protected.bookmarkData = nil
                        }
                        protected.missing = !directPathExists && ((try? attachment.withResolvedURL { !FileManager.default.fileExists(atPath: $0.path) }) ?? true)
                        return protected
                    }
                }
                if paper.primaryPDF?.missing == false { referenceCount += 1 }
            }
            for item in archivedAttachments where item.paperID == paper.id {
                var attachment = referencePapers[paper.id]?.attachments.first(where: { $0.id == item.id })
                    ?? Attachment(id: item.id, kind: .file,
                                  filePath: url.appendingPathComponent("unmaterialized-attachments/\(item.id.uuidString)").path,
                                  displayName: item.filename, missing: true, isReadOnlyReference: true, addedAt: item.addedAt)
                attachment.id = item.id; attachment.kind = .file
                attachment.displayName = item.filename; attachment.addedAt = item.addedAt
                attachment.isReadOnlyReference = true
                attachment.missing = (try? attachment.withResolvedURL { !FileManager.default.fileExists(atPath: $0.path) }) ?? true
                paper.attachments.append(attachment)
            }
            return paper
        }
        let storedPDFCount = archive.entries.keys.filter { $0.hasPrefix("pdfs/") && $0.lowercased().hasSuffix(".pdf") }.count
        guard try integer(counts, "pdfs", required: true) == archivePDFCount, storedPDFCount == archivePDFCount else {
            throw failure("备份 PDF 数量与 manifest 不一致。")
        }
        let paperIndexes = Dictionary(uniqueKeysWithValues: snapshot.papers.enumerated().map { ($0.element.id, $0.offset) })
        var annotationIDs: Set<UUID> = []
        for value in try annotations.sorted(by: { try integer($0, "sortOrder", required: true)! < integer($1, "sortOrder", required: true)! }) {
            let paperID = try identifier(value, "paperID")
            guard let index = paperIndexes[paperID] else { throw failure("备份标注引用了不存在的文献。") }
            let rawKind = try string(value, "type", required: true)
            guard let kind = AnnotationKind(rawValue: rawKind == "strikethrough" ? "strikeout" : rawKind) else {
                throw failure("备份包含尚未支持的标注类型：\(rawKind)。")
            }
            let pageIndex = try integer(value, "pageIndex", required: true)!
            guard pageIndex >= 0 else { throw failure("备份标注的页码无效。") }
            let bounds = CGRect(x: try number(value, "boundsX"), y: try number(value, "boundsY"),
                                width: try number(value, "boundsWidth"), height: try number(value, "boundsHeight"))
            var color = try string(value, "colorHex", required: true)
            if !color.hasPrefix("#") { color = "#" + color }
            let annotation = ResearchAnnotation(id: try stableAnnotationID(value), page: pageIndex + 1,
                pageLabel: try string(value, "pageLabel"), kind: kind, colorHex: color,
                selectedText: try string(value, "text"), note: try string(value, "contents"), bounds: CGRectCodable(bounds))
            guard annotationIDs.insert(annotation.id).inserted else { throw failure("备份标注存在重复标识。") }
            snapshot.papers[index].annotations.append(annotation)
        }
        let defaults = try templates.filter { try boolean($0, "isDefault", required: true) }
        guard defaults.count <= 1 else { throw failure("备份包含多个默认元数据模板。") }
        snapshot.metadataTemplates = try templates.map { value in
            MetadataTemplate(id: try identifier(value, "id"), name: try string(value, "name", required: true),
                             content: try string(value, "content", required: true), isDefault: try boolean(value, "isDefault", required: true),
                             dateCreated: try date(string(value, "dateCreated", required: true)))
        }
        if let template = snapshot.metadataTemplates?.first(where: \.isDefault) ?? snapshot.metadataTemplates?.first {
            snapshot.settings.activeMetadataTemplateID = template.id
            snapshot.settings.metadataTemplate = template.content
        } else { snapshot.settings.activeMetadataTemplateID = nil }
        let attachmentCount = try integer(counts, "attachmentFiles", required: true)!
        var warnings: [String] = []
        if referenceCount < archivePDFCount { warnings.append("归档包含 \(archivePDFCount) 个 PDF；仅恢复 \(referenceCount) 个可用外部引用。未解压 PDF，剩余文件仍保留在原归档中。") }
        if attachmentCount > 0 { warnings.append("归档附件包含 \(attachmentCount) 个文件；未解压的文件仍保留在原归档中。") }
        let unavailableAttachments = archivedAttachments.filter { $0.member == nil }.count
        if unavailableAttachments > 0 { warnings.append("\(unavailableAttachments) 个附件仅含元数据，归档未携带其文件；已保留身份、名称及可用的原引用。") }
        if let template = defaults.first {
            let body = try string(template, "content", required: true)
            let pattern = try NSRegularExpression(pattern: #"\{\{[#/]?([A-Za-z0-9_]+)\}\}"#)
            let sourceTokens = Set(pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
                Range(match.range(at: 1), in: body).map { String(body[$0]) }
            })
            let supported = Set(TemplateRenderer.context(for: snapshot.papers.first ?? Paper(), snapshot: snapshot).keys).union(["annotations"])
            let missing = sourceTokens.subtracting(supported).sorted()
            if !missing.isEmpty { warnings.append("原默认模板使用当前导出器尚未提供的变量：\(missing.joined(separator: ", "))。模板原文已完整保留。") }
        }
        warnings.append("原 manifest/data JSON 将保留为私有旁车，以保存排序和其他模型尚未表示的未知字段。")
        let result = LatticeArchiveResult(snapshot: snapshot, manifestData: manifestData, libraryData: libraryData,
            dataSHA256: SHA256.hash(data: libraryData).map { String(format: "%02x", $0) }.joined(),
            archivePDFCount: archivePDFCount, attachmentFileCount: attachmentCount,
            sourceReferenceCount: referenceCount, templateCount: templates.count, warnings: warnings)
        return try directory.map { try materialize(result, archiveURL: url, to: $0) } ?? result
    }

    static func readSnapshot(at url: URL) throws -> LibrarySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try date(decoder.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: url))
    }

    @MainActor
    static func importArchive(at url: URL, into store: LibraryStore, fallbackSnapshotURL: URL? = nil,
                              materializePDFsTo directory: URL? = nil) throws -> LatticeArchiveResult {
        guard url.resolvingSymlinksInPath() != store.persistenceURL.resolvingSymlinksInPath(), store.loadError == nil else {
            throw failure("请选择独立且可读取的 PaperManager 文库作为导入目标。")
        }
        let fallback = try fallbackSnapshotURL.map(readSnapshot) ?? store.snapshot
        let result = try readArchive(at: url, fallbackSnapshot: fallback, materializePDFsTo: directory)
        try persist(result, into: store)
        return result
    }

    private static func materialize(_ input: LatticeArchiveResult, archiveURL url: URL, to directory: URL) throws -> LatticeArchiveResult {
            var result = input
            let archive = try LatticeZIPInventory(url: url)
            let raw = try archive.readJSONMember("data.json", maximumBytes: 32 * 1_048_576)
            guard SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == result.dataSHA256 else {
                throw failure("归档在导入准备后发生变化。")
            }
            let payload = try object(raw)
            let records = try records(payload, "papers")
            let included = try records.filter { try boolean($0, "hasPDF", required: true) }
            let secondary = try attachmentDTOs(in: records).filter { $0.member != nil }
            let primaryMembers = try included.map { "pdfs/\(try identifier($0, "id").uuidString).pdf" }
            let names = primaryMembers + secondary.compactMap(\.member)
            let outputNames = Dictionary(uniqueKeysWithValues: secondary.map { ($0.member!, $0.outputName) })
            try archive.copyMembers(names, toNewDirectory: directory, outputNames: outputNames)
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
            for record in included {
                let id = try identifier(record, "id")
                guard let index = result.snapshot.papers.firstIndex(where: { $0.id == id }) else { throw failure("归档文献 ID 无法匹配。") }
                let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
                result.snapshot.papers[index].attachments.removeAll { $0.kind == .pdf }
                result.snapshot.papers[index].attachments.insert(Attachment(kind: .pdf, filePath: file.path,
                    displayName: try string(record, "pdfFilename"), fileSize: Int64(archive.entries["pdfs/\(id.uuidString).pdf"]!.size),
                    addedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))), at: 0)
            }
            for item in secondary {
                guard let index = result.snapshot.papers.firstIndex(where: { $0.id == item.paperID }),
                      let attachmentIndex = result.snapshot.papers[index].attachments.firstIndex(where: { $0.id == item.id }) else {
                    throw failure("归档附件 ID 无法匹配。")
                }
                let member = item.member!
                result.snapshot.papers[index].attachments[attachmentIndex] = Attachment(
                    id: item.id, kind: .file, filePath: directory.appendingPathComponent(item.outputName).path,
                    displayName: item.filename, fileSize: Int64(archive.entries[member]!.size), addedAt: item.addedAt)
            }
            result.sourceReferenceCount = 0
            result.warnings.removeAll { $0.hasPrefix("归档包含") || $0.hasPrefix("归档附件包含") }
            completed = true
            return result
    }

    /// Field layout observed in the shipped arm64 AttachmentDTO descriptor.
    /// The member is explicit data, never a guessed writer naming convention.
    private static func attachmentDTOs(in papers: [[String: Any]]) throws -> [ArchivedAttachment] {
        var result: [ArchivedAttachment] = [], ids: Set<UUID> = []
        for paper in papers {
            guard let value = paper["attachments"], !(value is NSNull) else { continue }
            guard let attachments = value as? [[String: Any]] else { throw failure("备份 attachments 必须是对象数组。") }
            let paperID = try identifier(paper, "id")
            for item in attachments {
                let id = try identifier(item, "id")
                guard ids.insert(id).inserted else { throw failure("备份附件存在重复 UUID。") }
                let filename = try string(item, "filename", required: true)
                guard !filename.trimmed.isEmpty, !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0"),
                      filename != ".", filename != ".." else { throw failure("备份附件名称无效。") }
                let member = try optionalString(item, "archivedRelativePath")
                if let member {
                    guard LatticeZIPInventory.safePayloadPath(member), member != "manifest.json", member != "data.json",
                          !member.hasPrefix("pdfs/") else { throw failure("备份附件 archivedRelativePath 不是安全的独立载荷路径。") }
                }
                result.append(ArchivedAttachment(paperID: paperID, id: id, filename: filename,
                                                 addedAt: try date(string(item, "dateAdded", required: true)), member: member))
            }
        }
        return result
    }

    @MainActor
    static func persist(_ result: LatticeArchiveResult, into store: LibraryStore, expectedRevision: Data? = nil) throws {
        guard store.loadError == nil else { throw failure("目标文库无法读取，已停止恢复以保护原文件。") }
        if let expectedRevision { try store.requireUnchangedSnapshot(since: expectedRevision) }
        if !store.snapshot.papers.isEmpty, FileManager.default.fileExists(atPath: store.persistenceURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = store.persistenceURL.deletingLastPathComponent()
                .appendingPathComponent("library-before-lattice-\(stamp)-\(UUID().uuidString).papermanager")
            try Data(contentsOf: store.persistenceURL).write(to: backup, options: .withoutOverwriting)
        }
        let sidecar = store.persistenceURL.deletingPathExtension().appendingPathExtension("lattice-source")
        let manager = FileManager.default
        let existed = manager.fileExists(atPath: sidecar.path)
        try manager.createDirectory(at: sidecar, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sidecar.path)
        let names = ["manifest.json", "data.json", ".gitignore"]
        var previous: [String: Data] = [:]
        for name in names where manager.fileExists(atPath: sidecar.appendingPathComponent(name).path) {
            previous[name] = try Data(contentsOf: sidecar.appendingPathComponent(name))
        }
        // Preserve provenance from earlier imports before changing the latest
        // projection; the successful import remains compatible with old tools.
        if !previous.isEmpty {
            let history = sidecar.appendingPathComponent("history/\(UUID().uuidString)")
            try manager.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, bytes) in previous { try bytes.write(to: history.appendingPathComponent(name), options: .withoutOverwriting) }
        }
        do {
            try result.manifestData.write(to: sidecar.appendingPathComponent("manifest.json"), options: .atomic)
            try result.libraryData.write(to: sidecar.appendingPathComponent("data.json"), options: .atomic)
            try Data("*\n!.gitignore\n".utf8).write(to: sidecar.appendingPathComponent(".gitignore"), options: .atomic)
            try store.replaceSnapshotDurably(result.snapshot, expectedRevision: expectedRevision)
        } catch {
            if !existed { try? manager.removeItem(at: sidecar) }
            else {
                for name in names {
                    let file = sidecar.appendingPathComponent(name)
                    if let bytes = previous[name] { try? bytes.write(to: file, options: .atomic) }
                    else { try? manager.removeItem(at: file) }
                }
            }
            throw error
        }
    }

    private static func failure(_ message: String) -> PaperManagerError { .message(message) }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("备份 JSON 必须是对象。") }
        return object
    }
    private static func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw failure("备份字段 \(key) 必须是对象。") }
        return value
    }
    private static func records(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let values = object[key] as? [[String: Any]] else { throw failure("备份字段 \(key) 必须是对象数组。") }
        return values
    }
    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw failure("备份字段 \(key) 必须是文本。") }
        return text
    }
    private static func string(_ object: [String: Any], _ key: String, required: Bool = false) throws -> String {
        if let value = try optionalString(object, key) { return value }
        guard !required else { throw failure("备份缺少必需字段 \(key)。") }
        return ""
    }
    private static func strings(_ object: [String: Any], _ key: String, required: Bool = false) throws -> [String] {
        guard let value = object[key], !(value is NSNull) else {
            guard !required else { throw failure("备份缺少必需字段 \(key)。") }; return []
        }
        guard let strings = value as? [String] else { throw failure("备份字段 \(key) 必须是文本数组。") }
        return strings
    }
    private static func integer(_ object: [String: Any], _ key: String, required: Bool = false) throws -> Int? {
        guard let value = object[key], !(value is NSNull) else {
            guard !required else { throw failure("备份缺少必需字段 \(key)。") }; return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else {
            throw failure("备份字段 \(key) 必须是整数。")
        }
        return number.intValue
    }
    private static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw failure("备份字段 \(key) 必须是有限数值。")
        }
        return value.doubleValue
    }
    private static func boolean(_ object: [String: Any], _ key: String, required: Bool = false) throws -> Bool {
        guard let value = object[key], !(value is NSNull) else {
            guard !required else { throw failure("备份缺少必需字段 \(key)。") }; return false
        }
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw failure("备份字段 \(key) 必须是布尔值。") }
        return value.boolValue
    }
    private static func identifier(_ object: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(object, key, required: true)) else { throw failure("备份字段 \(key) 的 UUID 无效。") }
        return id
    }
    private static func identifiers(_ object: [String: Any], _ key: String) throws -> [UUID] {
        try strings(object, key, required: true).map { value in
            guard let id = UUID(uuidString: value) else { throw failure("备份 \(key) 的 UUID 无效。") }; return id
        }
    }
    private static func uniqueIDs(_ records: [[String: Any]], entity: String) throws {
        var seen: Set<UUID> = []
        for record in records where !(try seen.insert(identifier(record, "id")).inserted) { throw failure("备份 \(entity) 存在重复 UUID。") }
    }
    private static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw failure("备份日期不是有效 ISO8601。") }
        return date
    }
    private static func paperType(_ raw: String) throws -> PaperType {
        if let type = PaperType(rawValue: raw) { return type }
        let supported = ["inbook", "incollection", "inproceedings", "conference", "phdthesis", "mastersthesis", "techreport", "report", "online", "webpage", "unpublished"]
        guard supported.contains(raw.lowercased()) else { throw failure("备份文献类型尚未支持：\(raw)。") }
        return PaperType.fromBibTeX(raw)
    }
    private static func stableAnnotationID(_ value: [String: Any]) throws -> UUID {
        if value["id"] != nil { return try identifier(value, "id") }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let hex = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        let text = String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32])
        return UUID(uuidString: text)!
    }
}

/// Classic single-volume ZIP inventory. ZIP64/encryption are rejected rather
/// than guessed; only the two bounded JSON members are inflated by system unzip.
private struct LatticeZIPInventory {
    struct Entry { let name: String; let flags: UInt16; let method: UInt16; let crc: UInt32; let compressed: UInt32; let size: UInt32; let offset: UInt32; let unixMode: UInt32 }
    let url: URL
    let entries: [String: Entry]
    let fileSize: UInt64
    let centralOffset: UInt64

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        let file = try FileHandle(forReadingFrom: self.url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22 else { throw PaperManagerError.message("备份不是完整 ZIP 文件。") }
        fileSize = size
        let tailSize = Int(min(size, 65_557))
        try file.seek(toOffset: size - UInt64(tailSize))
        let tail = [UInt8](try file.read(upToCount: tailSize) ?? Data())
        guard tail.count >= 22 else { throw PaperManagerError.message("ZIP 尾部已截断。") }
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if Self.u32(tail, index) == 0x06054b50, index + 22 + Int(Self.u16(tail, index + 20)) == tail.count { end = index; break }
        }
        guard let end, Self.u16(tail, end + 4) == 0, Self.u16(tail, end + 6) == 0,
              Self.u16(tail, end + 8) == Self.u16(tail, end + 10) else { throw PaperManagerError.message("不支持分卷或不完整 ZIP。") }
        let count = Int(Self.u16(tail, end + 10))
        let directorySize = UInt64(Self.u32(tail, end + 12))
        let directoryOffset = UInt64(Self.u32(tail, end + 16))
        guard count != 65_535, directoryOffset != UInt64(UInt32.max), directorySize <= 16 * 1_048_576,
              directoryOffset + directorySize <= size - UInt64(tailSize) + UInt64(end) else {
            throw PaperManagerError.message("ZIP64 或过大的 ZIP 索引暂不支持。")
        }
        centralOffset = directoryOffset
        try file.seek(toOffset: directoryOffset)
        let bytes = [UInt8](try file.read(upToCount: Int(directorySize)) ?? Data())
        guard bytes.count == directorySize else { throw PaperManagerError.message("ZIP 索引不完整。") }
        var found: [String: Entry] = [:]
        var position = 0
        for _ in 0..<count {
            guard position + 46 <= bytes.count, Self.u32(bytes, position) == 0x02014b50 else { throw PaperManagerError.message("ZIP 索引头无效。") }
            let nameLength = Int(Self.u16(bytes, position + 28))
            let recordLength = 46 + nameLength + Int(Self.u16(bytes, position + 30)) + Int(Self.u16(bytes, position + 32))
            guard position + recordLength <= bytes.count,
                  let name = String(bytes: bytes[(position + 46)..<(position + 46 + nameLength)], encoding: .utf8),
                  Self.safePath(name), found[name] == nil else { throw PaperManagerError.message("ZIP 存在重复成员或不安全的载荷路径。") }
            let entry = Entry(name: name, flags: Self.u16(bytes, position + 8), method: Self.u16(bytes, position + 10),
                crc: Self.u32(bytes, position + 16), compressed: Self.u32(bytes, position + 20), size: Self.u32(bytes, position + 24), offset: Self.u32(bytes, position + 42),
                unixMode: Self.u16(bytes, position + 4) >> 8 == 3 ? Self.u32(bytes, position + 38) >> 16 : 0)
            guard entry.flags & 1 == 0, entry.compressed != UInt32.max, entry.size != UInt32.max,
                  UInt64(entry.offset) + 30 < directoryOffset else { throw PaperManagerError.message("加密或 ZIP64 载荷暂不支持。") }
            found[name] = entry
            position += recordLength
        }
        guard position == bytes.count else { throw PaperManagerError.message("ZIP 索引包含无法解释的额外记录。") }
        entries = found
    }

    func readJSONMember(_ name: String, maximumBytes: Int) throws -> Data {
        guard let entry = entries[name], entry.size <= maximumBytes, entry.method == 0 || entry.method == 8 else {
            throw PaperManagerError.message("备份缺少 JSON 成员、超过读取预算或使用不支持的压缩方式。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.seekToEnd() == fileSize else { throw PaperManagerError.message("备份在读取期间发生变化。") }
        try file.seek(toOffset: UInt64(entry.offset))
        let header = [UInt8](try file.read(upToCount: 30) ?? Data())
        guard header.count == 30, Self.u32(header, 0) == 0x04034b50,
              Self.u16(header, 6) == entry.flags, Self.u16(header, 8) == entry.method else { throw PaperManagerError.message("ZIP 本地载荷头不匹配。") }
        if entry.flags & 8 == 0 {
            guard Self.u32(header, 14) == entry.crc, Self.u32(header, 18) == entry.compressed,
                  Self.u32(header, 22) == entry.size else { throw PaperManagerError.message("ZIP 本地头与索引的大小或 CRC 不一致。") }
        }
        let nameLength = Int(Self.u16(header, 26))
        let extraLength = Int(Self.u16(header, 28))
        let rawName = try file.read(upToCount: nameLength) ?? Data()
        guard String(data: rawName, encoding: .utf8) == name,
              UInt64(entry.offset) + 30 + UInt64(nameLength + extraLength) + UInt64(entry.compressed) <= centralOffset else {
            throw PaperManagerError.message("ZIP 载荷名称或范围无效。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard data.count + chunk.count <= maximumBytes, data.count + chunk.count <= entry.size else {
                    throw PaperManagerError.message("ZIP 载荷超过声明大小或读取预算。")
                }
                data.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count == entry.size, Self.crc32(data) == entry.crc,
              try file.seekToEnd() == fileSize else { throw PaperManagerError.message("ZIP JSON 载荷完整性验证失败。") }
        return data
    }

    func requirePayload(_ name: String) throws {
        guard Self.safePayloadPath(name), let entry = entries[name], entry.size <= 512 * 1_048_576,
              entry.method == 0 || entry.method == 8,
              entry.unixMode & UInt32(S_IFMT) == 0 || entry.unixMode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            throw PaperManagerError.message("归档缺少附件，或载荷路径、类型、压缩方式、大小不受支持。")
        }
    }

    func copyMembers(_ names: [String], toNewDirectory directory: URL, outputNames: [String: String] = [:]) throws {
        // Keep the caller's canonical physical path: macOS URL standardization
        // may abbreviate /private/var back to its /var symlink.
        let destination = directory
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
            throw PaperManagerError.message("PDF 导入目录必须是尚未存在的新目录。")
        }
        // Inspect every existing ancestor instead of following symlinked parents.
        let components = destination.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else { throw PaperManagerError.message("PDF 导入目录必须是规范绝对路径。") }
        for boundary in 1..<components.count {
            let path = "/" + components.prefix(boundary).joined(separator: "/")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw PaperManagerError.message("PDF 导入目录不能经过符号链接。")
            }
        }
        let selected = try names.map { name -> Entry in
            try requirePayload(name)
            return entries[name]!
        }
        let filenames = names.map { outputNames[$0] ?? URL(fileURLWithPath: $0).lastPathComponent }
        guard filenames.allSatisfy({ Self.safePayloadPath($0) && !$0.contains("/") }),
              Set(filenames.map { $0.lowercased() }).count == filenames.count,
              Set(names).count == names.count, selected.reduce(UInt64(0), { $0 + UInt64($1.size) }) <= 20 * 1_073_741_824 else {
            throw PaperManagerError.message("PDF 载荷重复或总大小超过 20 GiB。")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryFD = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw PaperManagerError.message("无法安全打开新的 PDF 导入目录。") }
        defer { close(directoryFD) }
        var created: [String] = []
        do {
            for entry in selected {
                let filename = outputNames[entry.name] ?? URL(fileURLWithPath: entry.name).lastPathComponent
                let descriptor = openat(directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw PaperManagerError.message("无法创建 PDF；不会覆盖现有文件或符号链接。") }
                created.append(filename)
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    try copyMember(entry, to: output)
                    try output.synchronize()
                    try output.close()
                } catch { try? output.close(); throw error }
            }
        } catch {
            for filename in created { _ = unlinkat(directoryFD, filename, 0) }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func copyMember(_ entry: Entry, to output: FileHandle) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        guard try source.seekToEnd() == fileSize else { throw PaperManagerError.message("归档在读取期间发生变化。") }
        try source.seek(toOffset: UInt64(entry.offset))
        let header = [UInt8](try source.read(upToCount: 30) ?? Data())
        guard header.count == 30, Self.u32(header, 0) == 0x04034b50,
              Self.u16(header, 6) == entry.flags, Self.u16(header, 8) == entry.method else { throw PaperManagerError.message("PDF 本地载荷头不匹配。") }
        if entry.flags & 8 == 0 {
            guard Self.u32(header, 14) == entry.crc, Self.u32(header, 18) == entry.compressed, Self.u32(header, 22) == entry.size else {
                throw PaperManagerError.message("PDF 本地头与 ZIP 索引不匹配。")
            }
        }
        let nameLength = Int(Self.u16(header, 26)); let extraLength = Int(Self.u16(header, 28))
        let rawName = try source.read(upToCount: nameLength) ?? Data()
        guard String(data: rawName, encoding: .utf8) == entry.name,
              UInt64(entry.offset) + 30 + UInt64(nameLength + extraLength) + UInt64(entry.compressed) <= centralOffset else {
            throw PaperManagerError.message("PDF 载荷名称或范围不匹配。")
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry.name]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var count: UInt64 = 0; var crc: UInt32 = 0xffffffff
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                count += UInt64(chunk.count)
                guard count <= UInt64(entry.size) else { throw PaperManagerError.message("PDF 超出声明大小。") }
                Self.updateCRC(chunk, value: &crc)
                try output.write(contentsOf: chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close(); process.waitUntilExit(); throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, count == UInt64(entry.size), crc ^ 0xffffffff == entry.crc,
              try source.seekToEnd() == fileSize else { throw PaperManagerError.message("PDF 大小或 CRC 验证失败。") }
    }

    private static func safePath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, component in
            component != "." && component != ".." && (!component.isEmpty || index == components.count - 1)
        }
    }
    static func safePayloadPath(_ name: String) -> Bool {
        safePath(name) && !name.hasSuffix("/") && name.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]").union(.controlCharacters)) == nil
    }
    private static func u16(_ data: [UInt8], _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private static func u32(_ data: [UInt8], _ offset: Int) -> UInt32 { UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16 }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        updateCRC(data, value: &crc)
        return crc ^ 0xffffffff
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    private static func updateCRC(_ data: Data, value crc: inout UInt32) {
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
    }
}
