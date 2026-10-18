import CryptoKit
import Foundation
import SQLite3

enum ZoteroAttachmentImportMode {
    /// Matches Lattice's Import Without PDFs: no attachment path is opened or probed.
    case metadataOnly
    /// The caller chooses a new, nonexistent destination. Linked external files require explicit opt-in.
    case copy(to: URL, includeExternalLinkedFiles: Bool = false)
}

struct ZoteroImportResult {
    var snapshot: LibrarySnapshot
    var sourceSnapshotSHA256: String
    var rawSidecarData: Data
    var warnings: [String]
    var discoveredAttachments: Int
    var copiedAttachments: Int
    var ownedDirectory: URL?
    fileprivate var ownedToken: UUID?

    var summaryText: String {
        "读取 \(snapshot.papers.count) 篇文献、\(snapshot.collections.count) 个文集、\(snapshot.tags.count) 个标签、\(snapshot.papers.reduce(0) { $0 + $1.annotations.count }) 条标注；拷贝 \(copiedAttachments) 个附件。"
    }
}

/// A local SQLite migration, independent of Zotero's API, profile discovery, or network services.
/// Source connections are SQLITE_OPEN_READONLY. sqlite3_backup captures committed WAL data;
/// all schema inspection and decoding then use the private snapshot, never the live connection.
enum ZoteroImportService {
    static func prepare(from selectedURL: URL,
                        attachmentMode: ZoteroAttachmentImportMode = .metadataOnly,
                        settings: AppSettings = .defaults) throws -> ZoteroImportResult {
        let access = selectedURL.startAccessingSecurityScopedResource()
        defer { if access { selectedURL.stopAccessingSecurityScopedResource() } }
        var directory: ObjCBool = false
        let source = FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &directory) && directory.boolValue
            ? selectedURL.appendingPathComponent("zotero.sqlite") : selectedURL
        guard source.isFileURL, FileManager.default.isReadableFile(atPath: source.path) else {
            throw failure("所选位置没有可读取的 zotero.sqlite。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-Zotero-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshotURL = temporary.appendingPathComponent("snapshot.sqlite")
        try makeSnapshot(from: source, to: snapshotURL)
        let database = try ZoteroSQLite(snapshotURL, readOnly: true)
        let available = Set(try database.rows("SELECT name FROM sqlite_master WHERE type IN ('table','view')").compactMap { $0.text("name") })
        let fieldTable = available.contains("fieldsCombined") ? "fieldsCombined" : "fields"
        let typeTable = available.contains("itemTypesCombined") ? "itemTypesCombined" : "itemTypes"
        for name in ["items", "itemData", "itemDataValues", fieldTable, typeTable] where !available.contains(name) {
            throw failure("Zotero 数据库缺少 \(name)，无法可靠读取文献。")
        }
        let tableNames = ["items", "itemData", "itemDataValues", "fields", "fieldsCombined", "itemTypes", "itemTypesCombined", "creators", "creatorTypes",
                          "itemCreators", "collections", "collectionItems", "tags", "itemTags", "itemNotes",
                          "itemAttachments", "itemAnnotations", "deletedItems", "deletedCollections", "baseFieldMappings",
                          "libraries", "version", "settings", "syncedSettings", "customFields", "customItemTypes", "customBaseFieldMappings", "itemTypeCreatorTypes"]
        var tables: [String: [ZoteroRow]] = [:]
        for name in Set(tableNames).sorted() where available.contains(name) {
            try Task.checkCancellation()
            tables[name] = try database.rows("SELECT * FROM \"\(name)\"")
        }
        var warnings: [String] = []
        let absent = ["creators", "creatorTypes", "itemCreators", "collections", "collectionItems", "tags", "itemTags", "itemNotes", "itemAttachments", "itemAnnotations"].filter { !available.contains($0) }
        if !absent.isEmpty { warnings.append("数据库未提供以下可选表，相关数据无法迁移：" + absent.joined(separator: ", ")) }
        let allItems = try index(tables["items"] ?? [], key: "itemID")
        var types = try index(tables["itemTypes"] ?? [], key: "itemTypeID")
        for (key, value) in try index(tables["itemTypesCombined"] ?? [], key: "itemTypeID") { types[key] = value }
        var fields = try index(tables["fields"] ?? [], key: "fieldID")
        for (key, value) in try index(tables["fieldsCombined"] ?? [], key: "fieldID") { fields[key] = value }
        let values = try index(tables["itemDataValues"] ?? [], key: "valueID")
        let deleted = Set((tables["deletedItems"] ?? []).compactMap { $0.text("itemID") })
        var itemFields: [String: [String: String]] = [:]
        for row in tables["itemData"] ?? [] {
            guard let itemID = row.text("itemID"), let fieldID = row.text("fieldID"), let valueID = row.text("valueID"),
                  let fieldName = fields[fieldID]?.text("fieldName"), let value = values[valueID]?.text("value") else {
                warnings.append("有无法解析的 itemData 关系；原始记录保留在来源记录。")
                continue
            }
            itemFields[itemID, default: [:]][fieldName] = value
        }
        var snapshot = LibrarySnapshot.empty
        snapshot.settings = settings
        var paperIndex: [String: Int] = [:]
        for (itemID, row) in allItems.sorted(by: { $0.key.compare($1.key, options: .numeric) == .orderedAscending }) where !deleted.contains(itemID) {
            let typeName = types[row.text("itemTypeID") ?? ""]?.text("typeName") ?? "unknown"
            if ["attachment", "note", "annotation"].contains(typeName) { continue }
            let data = itemFields[itemID] ?? [:]
            var paper = Paper()
            paper.id = stableID("item", row: row, fallback: itemID)
            paper.paperType = paperType(typeName)
            paper.title = data["title"] ?? ""
            paper.dateAdded = date(row.text("dateAdded")) ?? Date(timeIntervalSince1970: 0)
            paper.dateModified = date(row.text("dateModified")) ?? paper.dateAdded
            if date(row.text("dateAdded")) == nil { warnings.append("文献 \(itemID) 的添加日期无法解析，原值保留在来源记录。") }
            apply(data, to: &paper)
            if typeName == "unknown" || paper.paperType == .misc && typeName != "document" {
                warnings.append("Zotero 类型 \(typeName) 以其他类型保存，原始类型保留在自定义字段。")
            }
            paper.customFields.append(CustomField(key: "zotero:itemType", value: typeName))
            paper.customFields.append(CustomField(key: "zotero:key", value: row.text("key") ?? itemID))
            let candidate = data["citationKey"] ?? citationKey(in: data["extra"] ?? "")
            paper.citekey = candidate ?? ""
            paperIndex[itemID] = snapshot.papers.count
            snapshot.papers.append(paper)
        }
        let creators = try index(tables["creators"] ?? [], key: "creatorID")
        let creatorTypes = try index(tables["creatorTypes"] ?? [], key: "creatorTypeID")
        for row in (tables["itemCreators"] ?? []).sorted(by: { $0.integer("orderIndex") < $1.integer("orderIndex") }) {
            guard let itemID = row.text("itemID"), let p = paperIndex[itemID], let creator = creators[row.text("creatorID") ?? ""] else { continue }
            let role = creatorTypes[row.text("creatorTypeID") ?? ""]?.text("creatorType") ?? creatorTypes[row.text("creatorTypeID") ?? ""]?.text("creatorTypeName") ?? "unknown"
            let first = creator.text("firstName") ?? "", last = creator.text("lastName") ?? ""
            let name = creator.integer("fieldMode") == 1 ? last : [last, first].filter { !$0.isEmpty }.joined(separator: ", ")
            guard !name.isEmpty else { continue }
            switch role {
            case "author": snapshot.papers[p].authors.append(name)
            case "editor": snapshot.papers[p].editors = (snapshot.papers[p].editors ?? []) + [name]
            case "translator": snapshot.papers[p].translators = (snapshot.papers[p].translators ?? []) + [name]
            default: snapshot.papers[p].customFields.append(CustomField(key: "zotero:creator:\(role)", value: name))
            }
        }
        var usedCitekeys: Set<String> = []
        for p in snapshot.papers.indices {
            if snapshot.papers[p].citekey.isEmpty {
                snapshot.papers[p].citekey = CitekeyGenerator.generate(for: snapshot.papers[p], format: settings.citekeyFormat, existing: usedCitekeys)
            } else {
                let base = snapshot.papers[p].citekey
                var suffix = 2
                while usedCitekeys.contains(snapshot.papers[p].citekey.lowercased()) { snapshot.papers[p].citekey = base + "_\(suffix)"; suffix += 1 }
            }
            usedCitekeys.insert(snapshot.papers[p].citekey.lowercased())
        }
        let deletedCollections = Set((tables["deletedCollections"] ?? []).compactMap { $0.text("collectionID") })
        let collectionRows = try index((tables["collections"] ?? []).filter { !deletedCollections.contains($0.text("collectionID") ?? "") }, key: "collectionID")
        var collectionIDs: [String: UUID] = [:]
        for (id, row) in collectionRows { collectionIDs[id] = stableID("collection", row: row, fallback: id) }
        for (order, pair) in collectionRows.sorted(by: { $0.key.compare($1.key, options: .numeric) == .orderedAscending }).enumerated() {
            let (id, row) = pair
            let parent = row.text("parentCollectionID").flatMap { collectionIDs[$0] }
            if let sourceParent = row.text("parentCollectionID"), parent == nil { warnings.append("文集 \(id) 的父节点 \(sourceParent) 不存在，已作为顶层文集保留。") }
            snapshot.collections.append(PaperCollection(id: collectionIDs[id]!, name: row.text("collectionName") ?? "", parentID: parent,
                                                        sortIndex: order, createdAt: date(row.text("clientDateModified")) ?? Date(timeIntervalSince1970: 0)))
        }
        let parents = Dictionary(uniqueKeysWithValues: snapshot.collections.map { ($0.id, $0.parentID) })
        for collection in snapshot.collections {
            var seen: Set<UUID> = [], current: UUID? = collection.id
            while let id = current { guard seen.insert(id).inserted else { throw failure("Zotero 文集存在循环关系，未写入目标文库。") }; current = parents[id] ?? nil }
        }
        for row in tables["collectionItems"] ?? [] {
            guard let p = paperIndex[row.text("itemID") ?? ""], let id = collectionIDs[row.text("collectionID") ?? ""] else { continue }
            if !snapshot.papers[p].collectionIDs.contains(id) { snapshot.papers[p].collectionIDs.append(id) }
        }
        var tagIDs: [String: UUID] = [:]
        var tagColors: [String: String] = [:]
        for row in tables["syncedSettings"] ?? [] where row.text("setting") == "tagColors" {
            guard let value = row.text("value"), let entries = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]] else {
                warnings.append("Zotero 标签颜色配置无法解析，原始设置已保留。")
                continue
            }
            for entry in entries {
                guard let name = entry["name"] as? String, let color = entry["color"] as? String,
                      color.range(of: "^#[A-Fa-f0-9]{6}$", options: .regularExpression) != nil else { continue }
                if let previous = tagColors[name], previous != color { warnings.append("标签 \(name) 在不同库中颜色不同，已保留其中一种；完整配置保留在来源记录。") }
                else { tagColors[name] = color }
            }
        }
        for row in tables["tags"] ?? [] {
            guard let id = row.text("tagID"), let name = row.text("name") else { continue }
            let uuid = identifier("zotero:tag:\(name)")
            tagIDs[id] = uuid
            snapshot.tags.append(PaperTag(id: uuid, name: name, colorHex: tagColors[name] ?? "#5B8DEF", createdAt: Date(timeIntervalSince1970: 0)))
        }
        for row in tables["itemTags"] ?? [] {
            guard let p = paperIndex[row.text("itemID") ?? ""], let id = tagIDs[row.text("tagID") ?? ""] else { continue }
            if !snapshot.papers[p].tagIDs.contains(id) { snapshot.papers[p].tagIDs.append(id) }
        }
        let attachmentRows = try index((tables["itemAttachments"] ?? []).filter { !deleted.contains($0.text("itemID") ?? "") }, key: "itemID")
        for row in tables["itemNotes"] ?? [] where !deleted.contains(row.text("itemID") ?? "") {
            let parent = row.text("parentItemID") ?? ""
            guard let p = paperIndex[parent] ?? attachmentRows[parent]?.text("parentItemID").flatMap({ paperIndex[$0] }) else {
                if !(row.text("note") ?? "").isEmpty { warnings.append("独立或孤立笔记未转成论文，原始 HTML 保留在来源记录。") }
                continue
            }
            let note = row.text("note") ?? ""
            if !note.isEmpty { snapshot.papers[p].notes += (snapshot.papers[p].notes.isEmpty ? "" : "\n\n") + note }
        }
        for row in (tables["itemAnnotations"] ?? []).sorted(by: { ($0.text("sortIndex") ?? "") < ($1.text("sortIndex") ?? "") }) where !deleted.contains(row.text("itemID") ?? "") {
            guard let itemID = row.text("itemID"), let parent = row.text("parentItemID"),
                  let p = paperIndex[parent] ?? attachmentRows[parent]?.text("parentItemID").flatMap({ paperIndex[$0] }) else {
                warnings.append("孤立标注保留在来源记录，未附加至其他论文。")
                continue
            }
            var annotation = ResearchAnnotation(id: stableID("item", row: allItems[itemID] ?? row, fallback: itemID))
            annotation.kind = annotationKind(row.integer("type"))
            annotation.selectedText = row.text("text") ?? ""
            annotation.note = row.text("comment") ?? ""
            annotation.pageLabel = row.text("pageLabel") ?? ""
            annotation.colorHex = row.text("color") ?? "#FFD166"
            annotation.createdAt = date(allItems[itemID]?.text("dateAdded"))
            if let raw = row.text("position"), let position = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                let page = (position["pageIndex"] as? NSNumber)?.intValue ?? 0
                annotation.page = max(0, page) + 1
                let rects = position["rects"] as? [[Double]] ?? []
                var union: CGRect?
                for r in rects where r.count == 4 && r.allSatisfy(\.isFinite) && r[2] >= r[0] && r[3] >= r[1] {
                    let rect = CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1])
                    union = union.map { $0.union(rect) } ?? rect
                }
                annotation.bounds = union.map(CGRectCodable.init)
                if rects.count > 1 { warnings.append("标注 \(itemID) 的多个矩形合并为包围框；原始位置保留在来源记录。") }
                if position["paths"] != nil || position["width"] != nil { warnings.append("标注 \(itemID) 的墨迹/图像几何保留在来源记录，未生成批注图片。") }
            } else { warnings.append("标注 \(itemID) 的位置无法解析，文字和备注已保留。") }
            if ![1, 2, 3, 5, 6].contains(row.integer("type")) { warnings.append("标注 \(itemID) 的类型仅迁移文字，原始类型和几何保留在来源记录。") }
            snapshot.papers[p].annotations.append(annotation)
        }
        var ownedDirectory: URL?, ownedToken: UUID?, copied = 0, success = false
        defer { if !success, let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) } }
        switch attachmentMode {
        case .metadataOnly:
            if !attachmentRows.isEmpty { warnings.append("已选择不导入文件，未打开或探测任何附件路径；原始附件记录保留在来源记录。") }
        case .copy(let destination, let externalAllowed):
            try createOwnedDirectory(destination)
            ownedDirectory = destination
            ownedToken = UUID()
            try Data(ownedToken!.uuidString.utf8).write(to: destination.appendingPathComponent(".papermanager-zotero-import"), options: .withoutOverwriting)
            // Reuse the shared organization/rename/layout rules inside a new
            // owned namespace. The returned user settings retain their real root.
            var placementSnapshot = snapshot
            placementSnapshot.settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: destination.path,
                layout: FileLibraryService.preferences(for: settings).layout)
            var totalBytes: Int64 = 0
            for (itemID, row) in attachmentRows.sorted(by: { $0.key.compare($1.key, options: .numeric) == .orderedAscending }) {
                try Task.checkCancellation()
                guard let parent = row.text("parentItemID"), let p = paperIndex[parent] else {
                    warnings.append("独立附件 \(itemID) 保留在来源记录，未创建无元数据论文。")
                    continue
                }
                guard let item = allItems[itemID] else { warnings.append("附件 \(itemID) 缺少项目记录。") ; continue }
                guard let resolved = attachmentURL(row: row, item: item, sourceDirectory: source.deletingLastPathComponent(), allowExternal: externalAllowed) else {
                    warnings.append("附件 \(itemID) 的路径未授权或无法解析，未读取文件。")
                    continue
                }
                do {
                    let info = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= 512 * 1_048_576,
                          totalBytes + Int64(size) <= 20 * 1_073_741_824 else { throw failure("文件不是普通文件或超过迁移大小限制。") }
                    let attachmentID = stableID("item", row: item, fallback: itemID)
                    let suffix = resolved.pathExtension.lowercased()
                    let isPDF = (row.text("contentType") ?? "").lowercased() == "application/pdf" || suffix == "pdf"
                    placementSnapshot.papers = snapshot.papers
                    let plan = try FileLibraryService.plan(source: resolved, paper: snapshot.papers[p], snapshot: placementSnapshot,
                        attachmentID: isPDF && snapshot.papers[p].primaryPDF == nil ? nil : attachmentID,
                        kind: isPDF ? .pdf : .file, managedImport: true)
                    let receipt = try FileLibraryService.execute(plan)
                    do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.destination.path) }
                    catch { try? receipt.rollback(); throw error }
                    snapshot.papers[p].attachments.append(Attachment(id: attachmentID, kind: isPDF ? .pdf : .file,
                        filePath: plan.destination.path, displayName: plan.destination.lastPathComponent, fileSize: Int64(size),
                        addedAt: date(item.text("dateAdded")) ?? snapshot.papers[p].dateAdded))
                    copied += 1
                    totalBytes += Int64(size)
                } catch { warnings.append("附件 \(itemID) 未拷贝：\(error.localizedDescription)") }
            }
        }
        let digest = SHA256.hash(data: try Data(contentsOf: snapshotURL, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        let raw: [String: Any] = ["format": "PaperManager.ZoteroSource.v1", "sourcePath": source.path,
                                  "snapshotSHA256": digest, "tables": tables.mapValues { $0.map(\.values) },
                                  "limitations": ["Attachment paths are read only in explicit copy mode.", "Raw notes retain HTML.", "Unrepresented fields/geometry remain in these source rows."]]
        let sidecarData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        guard sidecarData.count <= 128 * 1_048_576 else { throw failure("Zotero 来源元数据超过 128 MiB，未写入目标文库。") }
        success = true
        return ZoteroImportResult(snapshot: snapshot, sourceSnapshotSHA256: digest, rawSidecarData: sidecarData,
                                  warnings: Array(Set(warnings)).sorted(), discoveredAttachments: attachmentRows.count,
                                  copiedAttachments: copied, ownedDirectory: ownedDirectory, ownedToken: ownedToken)
    }

    /// Called on preview cancellation or after persist to remove skipped copies.
    /// Existing library references always win over cleanup, including partial-save errors.
    static func cleanupPreparedFiles(_ result: ZoteroImportResult, keepingReferencedBy library: LibrarySnapshot = .empty) throws {
        guard let directory = result.ownedDirectory, let token = result.ownedToken else { return }
        func clean() throws {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            let marker = directory.appendingPathComponent(".papermanager-zotero-import")
            guard try Data(contentsOf: marker) == Data(token.uuidString.utf8) else { throw failure("迁移副本的归属标记已变化，已保留文件以供检查。") }
            let retained = Set(library.papers.flatMap(\.attachments).map(\.filePath))
            if !retained.contains(where: { $0.hasPrefix(directory.path + "/") }) {
                try FileManager.default.removeItem(at: directory)
                return
            }
            for attachment in result.snapshot.papers.flatMap(\.attachments) where !retained.contains(attachment.filePath) {
                guard attachment.filePath.hasPrefix(directory.path + "/") else { continue }
                if FileManager.default.fileExists(atPath: attachment.filePath) { try FileManager.default.removeItem(at: attachment.url) }
            }
        }
        if FileLibraryService.status(for: result.snapshot.settings).isAvailable {
            try FileLibraryService.withRoot(settings: result.snapshot.settings) { _ in try clean() }
        } else { try clean() }
    }

    @MainActor
    @discardableResult
    static func persist(_ result: ZoteroImportResult, into store: LibraryStore) throws -> Int {
        guard store.loadError == nil else { throw failure("目标文库无法读取，已停止导入。") }
        var merged = store.snapshot
        for collection in result.snapshot.collections where !merged.collections.contains(where: { $0.id == collection.id }) { merged.collections.append(collection) }
        var tagMap: [UUID: UUID] = [:]
        for tag in result.snapshot.tags {
            if let existing = merged.tags.first(where: { $0.id == tag.id || $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }) { tagMap[tag.id] = existing.id }
            else { merged.tags.append(tag); tagMap[tag.id] = tag.id }
        }
        var imported = 0
        for var paper in result.snapshot.papers where !merged.papers.contains(where: { $0.id == paper.id }) {
            paper.tagIDs = paper.tagIDs.compactMap { tagMap[$0] }
            merged.papers.append(paper)
            imported += 1
        }
        let sourceDirectory = store.persistenceURL.deletingLastPathComponent().appendingPathComponent("ZoteroSources/\(UUID().uuidString)")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: sourceDirectory) } }
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try result.rawSidecarData.write(to: sourceDirectory.appendingPathComponent("source.json"), options: .withoutOverwriting)
        try Data("*\n!.gitignore\n".utf8).write(to: sourceDirectory.deletingLastPathComponent().appendingPathComponent(".gitignore"), options: .atomic)
        if FileManager.default.fileExists(atPath: store.persistenceURL.path) {
            let backup = store.persistenceURL.deletingLastPathComponent().appendingPathComponent("library-before-zotero-\(UUID().uuidString).papermanager")
            try FileManager.default.copyItem(at: store.persistenceURL, to: backup)
        }
        try store.replaceSnapshotDurably(merged)
        committed = true
        store.statusMessage = "Zotero 导入 \(imported) 篇，跳过已有 \(result.snapshot.papers.count - imported) 篇。"
        return imported
    }

    private static func makeSnapshot(from source: URL, to destination: URL) throws {
        let input = try ZoteroSQLite(source, readOnly: true)
        let output = try ZoteroSQLite(destination, readOnly: false)
        defer { withExtendedLifetime(input) {}; withExtendedLifetime(output) {} }
        guard sqlite3_db_readonly(input.handle, "main") == 1,
              let backup = sqlite3_backup_init(output.handle, "main", input.handle, "main") else {
            throw failure("无法准备 Zotero 只读数据库快照。")
        }
        let deadline = Date().addingTimeInterval(30)
        var code: Int32
        repeat {
            do { try Task.checkCancellation() } catch { sqlite3_backup_finish(backup); throw error }
            code = sqlite3_backup_step(backup, 256)
            if code == SQLITE_BUSY || code == SQLITE_LOCKED { sqlite3_sleep(10) }
        } while [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(code) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finished == SQLITE_OK else { throw failure("Zotero 数据库快照失败或持续繁忙，请稍后重试。") }
        // A WAL source's header can leave the private copy in WAL mode. Normalize
        // only our destination before reopening it read-only, with no WAL dependency.
        guard sqlite3_exec(output.handle, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw failure("无法完成私有 Zotero 快照的日志转换。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func index(_ rows: [ZoteroRow], key: String) throws -> [String: ZoteroRow] {
        var result: [String: ZoteroRow] = [:]
        for row in rows { guard let value = row.text(key), result[value] == nil else { throw failure("Zotero 表的 \(key) 缺失或重复。") }; result[value] = row }
        return result
    }
    private static func identifier(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func stableID(_ entity: String, row: ZoteroRow, fallback: String) -> UUID {
        identifier("zotero:\(entity):\(row.text("libraryID") ?? "1"):\(row.text("key") ?? fallback)")
    }
    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let sql = DateFormatter(); sql.locale = Locale(identifier: "en_US_POSIX"); sql.timeZone = TimeZone(secondsFromGMT: 0); sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: value)
    }
    private static func paperType(_ type: String) -> PaperType {
        switch type {
        case "journalArticle", "magazineArticle", "newspaperArticle": return .article
        case "book": return .book
        case "bookSection": return .inCollection
        case "conferencePaper": return .inProceedings
        case "thesis": return .thesis
        case "report": return .report
        case "patent": return .patent
        case "dataset": return .dataset
        case "computerProgram": return .software
        case "webpage", "blogPost", "forumPost": return .online
        case "preprint": return .preprint
        case "manuscript": return .manuscript
        default: return .misc
        }
    }
    private static func annotationKind(_ type: Int) -> AnnotationKind {
        switch type { case 1: return .highlight; case 2: return .note; case 3: return .square; case 5: return .underline; default: return .freeText }
    }
    private static func citationKey(in extra: String) -> String? {
        extra.split(separator: "\n").first { $0.lowercased().hasPrefix("citation key:") }.map { String($0.dropFirst("citation key:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private static func apply(_ fields: [String: String], to paper: inout Paper) {
        let mapping: [String: WritableKeyPath<Paper, String>] = ["publicationTitle": \.journal, "proceedingsTitle": \.bookTitle, "bookTitle": \.bookTitle,
            "publisher": \.publisher, "institution": \.institution, "university": \.school, "series": \.series, "volume": \.volume, "issue": \.issue,
            "pages": \.pages, "DOI": \.doi, "ISBN": \.isbn, "url": \.url, "language": \.language, "abstractNote": \.abstract,
            "conferenceName": \.event, "edition": \.edition, "section": \.chapter, "archiveID": \.eprint, "archive": \.eprintType,
            "reportType": \.typeNonOptionalForZotero]
        for (key, value) in fields {
            if let keyPath = mapping[key] { paper[keyPath: keyPath] = value }
            else if !["title", "date", "citationKey", "accessDate", "place"].contains(key) { paper.customFields.append(CustomField(key: "zotero:\(key)", value: value)) }
        }
        paper.address = fields["place"]
        paper.urlDate = fields["accessDate"]
        if let raw = fields["date"], let range = raw.range(of: "(?:^|[^0-9])([12][0-9]{3})(?:[^0-9]|$)", options: .regularExpression) {
            paper.year = Int(raw[range].filter(\.isNumber))
        }
    }
    private static func attachmentURL(row: ZoteroRow, item: ZoteroRow, sourceDirectory: URL, allowExternal: Bool) -> URL? {
        guard let path = row.text("path"), !path.isEmpty, !path.contains("\0") else { return nil }
        if path.hasPrefix("storage:"), let key = item.text("key"), key.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil {
            let relative = String(path.dropFirst(8))
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.isEmpty else { return nil }
            let storage = sourceDirectory.resolvingSymlinksInPath().appendingPathComponent("storage/\(key)")
            let candidate = storage.appendingPathComponent(relative).standardizedFileURL
            guard candidate.resolvingSymlinksInPath().path.hasPrefix(storage.path + "/") else { return nil }
            return candidate
        }
        guard allowExternal, row.integer("linkMode") == 2 else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let url = URL(string: path), url.isFileURL { return url }
        return nil // Relative attachments: requires Zotero's separate linked-base-directory preference.
    }
    private static func createOwnedDirectory(_ directory: URL) throws {
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else { throw failure("附件目标必须是尚不存在的新文件夹。") }
        var ancestor = directory.deletingLastPathComponent()
        while ancestor.path != "/" {
            let values = try ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("附件目标的父目录必须存在且不可为符号链接。") }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    private static func failure(_ message: String) -> PaperManagerError { .message(message) }
}

private extension Paper {
    var typeNonOptionalForZotero: String { get { type ?? "" } set { type = newValue } }
}

private struct ZoteroRow {
    var values: [String: Any]
    func text(_ key: String) -> String? {
        if let value = values[key] as? String { return value }
        if let value = values[key] as? NSNumber { return value.stringValue }
        return nil
    }
    func integer(_ key: String) -> Int { text(key).flatMap(Int.init) ?? 0 }
}

private final class ZoteroSQLite {
    private(set) var handle: OpaquePointer?
    init(_ url: URL, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw PaperManagerError.message("无法打开 Zotero 数据库：\(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
        if readOnly { _ = sqlite3_exec(handle, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func rows(_ sql: String) throws -> [ZoteroRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PaperManagerError.message("无法读取 Zotero 表：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        var output: [ZoteroRow] = [], code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            try Task.checkCancellation()
            guard output.count < 250_000 else { throw PaperManagerError.message("Zotero 表超过 250,000 条记录，未继续导入。") }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    guard sqlite3_column_bytes(statement, index) <= 16 * 1_048_576 else { throw PaperManagerError.message("Zotero 文本字段超过 16 MiB。") }
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[name] = String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, index), count: count), as: UTF8.self)
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, index))
                    guard length <= 16 * 1_048_576 else { throw PaperManagerError.message("Zotero 二进制字段超过 16 MiB。") }
                    let data = length == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: length)
                    row[name] = ["base64": data.base64EncodedString()]
                default: row[name] = NSNull()
                }
            }
            output.append(ZoteroRow(values: row)); code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw PaperManagerError.message("Zotero 查询失败：\(String(cString: sqlite3_errmsg(handle)))") }
        return output
    }
}
