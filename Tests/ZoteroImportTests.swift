import CryptoKit
import Darwin
import Foundation
import SQLite3

@main
struct ZoteroImportTests {
    @MainActor
    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let fixture = try Fixture(root.appendingPathComponent("main"))
        defer { fixture.close() }
        let source = fixture.source
        var passed = 0, failed = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String = "assertion failed") throws {
            if !(try value()) { throw PaperManagerError.message(message) }
        }
        func check(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        func rejected(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        let sourceBefore = try Data(contentsOf: source)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        let sourceMode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as! NSNumber
        var metadata: ZoteroImportResult!
        check("SQLite backup includes committed WAL while source stays read-only") {
            metadata = try ZoteroImportService.prepare(from: source)
            try require(metadata.snapshot.papers.count == 2)
            try require(metadata.snapshot.papers.contains { $0.title == "Committed only in WAL" })
            try require(try Data(contentsOf: source) == sourceBefore)
            try require(try Data(contentsOf: wal) == walBefore)
            let afterMode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as! NSNumber
            try require(afterMode == sourceMode && afterMode.intValue == 0o444)
            try require(metadata.sourceSnapshotSHA256.count == 64)
        }
        guard metadata != nil else { exit(1) }
        check("metadata, creator order, corporate names, roles and unknown field") {
            let p = metadata.snapshot.papers.first { $0.title == "Synthetic article" }!
            try require(p.authors == ["Lovelace, Ada", "Synthetic Research Group"])
            try require(p.editors == ["Hopper, Grace"] && p.translators == ["Turing, Alan"])
            try require(p.year == 2024 && p.journal == "Fixture Journal" && p.doi == "10.1234/fixture")
            try require(p.customFields.contains { $0.key == "zotero:unknownFixtureField" && $0.value == "preserved custom value" })
            try require(p.citekey == "OriginalFixtureKey")
            let chapter = metadata.snapshot.papers.first { $0.title == "Committed only in WAL" }!
            try require(chapter.paperType == .inCollection && chapter.bookTitle == "Fixture Book")
            try require(chapter.citekey == "lovelace2025")
        }
        check("nested/multiple collections, tags and exact source dates") {
            let p = metadata.snapshot.papers.first { $0.title == "Synthetic article" }!
            try require(p.collectionIDs.count == 2 && p.tagIDs.count == 2)
            try require(metadata.snapshot.tags.first { $0.name == "Fixture Tag" }?.colorHex == "#AABBCC")
            let child = metadata.snapshot.collections.first { $0.name == "Child" }!
            try require(child.parentID == metadata.snapshot.collections.first { $0.name == "Root" }!.id)
            let iso = ISO8601DateFormatter()
            try require(p.dateAdded == iso.date(from: "2024-01-02T03:04:05Z"))
            try require(p.dateModified == iso.date(from: "2024-06-07T08:09:10Z"))
        }
        check("Import Without PDFs keeps notes and annotations without attachment I/O") {
            let p = metadata.snapshot.papers.first { $0.title == "Synthetic article" }!
            try require(p.notes == "<p>Original <b>HTML note</b></p>")
            try require(p.annotations.count == 1 && p.annotations[0].page == 3 && p.annotations[0].pageLabel == "iii")
            try require(p.annotations[0].selectedText == "Selected fixture text" && p.annotations[0].note == "Annotation comment")
            try require(p.annotations[0].bounds?.x == 10 && p.annotations[0].bounds?.width == 30)
            try require(metadata.snapshot.papers.allSatisfy { $0.attachments.isEmpty } && metadata.ownedDirectory == nil)
            try require(metadata.warnings.contains { $0.contains("未打开或探测任何附件路径") })
        }
        check("stable imported IDs and raw metadata/geometry sidecar") {
            let again = try ZoteroImportService.prepare(from: fixture.directory)
            try require(again.snapshot.papers.map(\.id) == metadata.snapshot.papers.map(\.id))
            try require(again.snapshot.papers[0].annotations.map(\.id) == metadata.snapshot.papers[0].annotations.map(\.id))
            let object = try JSONSerialization.jsonObject(with: metadata.rawSidecarData) as! [String: Any]
            let tables = object["tables"] as! [String: [[String: Any]]]
            try require(tables["items"]!.first { ($0["itemID"] as? NSNumber)?.intValue == 1 }?["futureSourceColumn"] as? String == "kept verbatim")
            let annotation = tables["itemAnnotations"]![0]
            try require((annotation["position"] as? String)?.contains("rects") == true)
            try require(tables["itemAttachments"]!.count == 4)
        }
        check("copy imported storage file only; reject external, traversal and escaping symlink") {
            let destination = root.appendingPathComponent("internal-copy")
            let result = try ZoteroImportService.prepare(from: source, attachmentMode: .copy(to: destination))
            let attachments = result.snapshot.papers.flatMap(\.attachments)
            try require(result.copiedAttachments == 1 && attachments.count == 1)
            try require(attachments[0].kind == .pdf && !attachments[0].isReadOnlyReference && !attachments[0].missing)
            try require(try Data(contentsOf: attachments[0].url) == fixture.pdfData)
            try require(try Data(contentsOf: fixture.storedPDF) == fixture.pdfData)
            try require(try Data(contentsOf: fixture.externalPDF) == fixture.externalData)
            let permission = try FileManager.default.attributesOfItem(atPath: attachments[0].filePath)[.posixPermissions] as! NSNumber
            try require(permission.intValue == 0o600)
            try require(result.warnings.filter { $0.contains("未授权或无法解析") }.count == 3)
        }
        check("external linked file copies only after explicit opt-in; source is retained") {
            let destination = root.appendingPathComponent("external-copy")
            let result = try ZoteroImportService.prepare(from: source, attachmentMode: .copy(to: destination, includeExternalLinkedFiles: true))
            try require(result.copiedAttachments == 2)
            try require(FileManager.default.fileExists(atPath: fixture.externalPDF.path))
            try require(try Data(contentsOf: fixture.externalPDF) == fixture.externalData)
            try require(result.snapshot.papers.flatMap(\.attachments).allSatisfy { $0.filePath.hasPrefix(destination.path + "/") })
        }
        check("shared layout/grouping/rename rules copy once and preview cleanup respects references") {
            var settings = AppSettings.defaults
            settings.pdfOrganizationMode = .move // Zotero must still copy.
            settings.autoRenamePDFs = true
            settings.pdfRenameTemplate = "{citekey}"
            settings.pdfSubfolderGrouping = .year
            settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: root.path, layout: .byPaper)
            let destination = root.appendingPathComponent("rule-copy")
            let result = try ZoteroImportService.prepare(from: source, attachmentMode: .copy(to: destination), settings: settings)
            let paper = result.snapshot.papers.first { $0.title == "Synthetic article" }!
            let attachment = paper.attachments[0]
            try require(attachment.filePath == destination.appendingPathComponent("2024/\(paper.id.uuidString)/OriginalFixtureKey.pdf").path)
            try require(result.snapshot.settings == settings)
            try require(try Data(contentsOf: fixture.storedPDF) == fixture.pdfData)
            try ZoteroImportService.cleanupPreparedFiles(result, keepingReferencedBy: result.snapshot)
            try require(FileManager.default.fileExists(atPath: attachment.filePath))
            try ZoteroImportService.cleanupPreparedFiles(result)
            try require(!FileManager.default.fileExists(atPath: destination.path))
        }
        check("copy destination cannot overwrite or follow symlinked parent") {
            let existing = root.appendingPathComponent("internal-copy")
            let before = try FileManager.default.contentsOfDirectory(atPath: existing.path)
            try require(rejected { _ = try ZoteroImportService.prepare(from: source, attachmentMode: .copy(to: existing)) })
            let link = root.appendingPathComponent("destination-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
            try require(rejected { _ = try ZoteroImportService.prepare(from: source, attachmentMode: .copy(to: link.appendingPathComponent("child"))) })
            try require(try FileManager.default.contentsOfDirectory(atPath: existing.path) == before)
        }
        check("deleted items are excluded and source metadata remains intact after copies") {
            try require(!metadata.snapshot.papers.contains { $0.title == "Deleted fixture" })
            try require(try Data(contentsOf: source) == sourceBefore && Data(contentsOf: wal) == walBefore)
            try require(metadata.discoveredAttachments == 4)
        }
        check("cyclic collections fail before creating a file destination") {
            let cycle = try Fixture(root.appendingPathComponent("cycle"), readOnly: false)
            defer { cycle.close() }
            try cycle.exec("UPDATE collections SET parentCollectionID=101 WHERE collectionID=100")
            let target = root.appendingPathComponent("cycle-copy")
            try require(rejected { _ = try ZoteroImportService.prepare(from: cycle.source, attachmentMode: .copy(to: target)) })
            try require(!FileManager.default.fileExists(atPath: target.path))
        }
        check("non-Zotero databases fail without replacing a target library") {
            let bad = root.appendingPathComponent("not-zotero.sqlite")
            var handle: OpaquePointer?
            sqlite3_open(bad.path, &handle); defer { sqlite3_close(handle) }
            sqlite3_exec(handle, "CREATE TABLE example(value TEXT)", nil, nil, nil)
            try require(rejected { _ = try ZoteroImportService.prepare(from: bad) })
        }
        check("persist merges independently, keeps existing data, and repeated imports are idempotent") {
            let store = LibraryStore(persistenceURL: root.appendingPathComponent("destination/library.json"))
            var prior = LibrarySnapshot.empty
            var existing = Paper(); existing.title = "Existing local reference"; existing.notes = "keep"
            prior.papers = [existing]
            prior.tags = [PaperTag(name: "fixture tag")]
            store.replaceSnapshot(prior)
            try require(try ZoteroImportService.persist(metadata, into: store) == 2)
            try require(store.papers.count == 3 && store.papers.first { $0.id == existing.id }?.notes == "keep")
            try require(store.snapshot.tags.count == 2)
            try require(try ZoteroImportService.persist(metadata, into: store) == 0 && store.papers.count == 3)
            let sourceDirectories = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("destination/ZoteroSources"), includingPropertiesForKeys: nil)
            try require(sourceDirectories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.json").path) })
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: store.persistenceURL))
            try require(saved.papers.count == 3 && saved.papers.contains { $0.annotations.count == 1 })
        }
        check("failed durable persist retains current library and removes only its new raw sidecar") {
            let folder = root.appendingPathComponent("failed-persist")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let store = LibraryStore(persistenceURL: folder.appendingPathComponent("library.json"))
            var existing = Paper(); existing.title = "Persisted local paper"
            _ = try store.addPaperDurably(existing)
            let before = try store.snapshotRevisionToken()
            try FileManager.default.removeItem(at: store.persistenceURL)
            try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
            let sentinel = store.persistenceURL.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: sentinel)
            try require(rejected { _ = try ZoteroImportService.persist(metadata, into: store) })
            try require(try store.snapshotRevisionToken() == before)
            try require(try Data(contentsOf: sentinel) == Data("keep".utf8))
            let sidecars = folder.appendingPathComponent("ZoteroSources")
            if FileManager.default.fileExists(atPath: sidecars.path) {
                try require(try FileManager.default.contentsOfDirectory(at: sidecars, includingPropertiesForKeys: nil)
                    .allSatisfy { $0.lastPathComponent == ".gitignore" })
            }
        }
        print("Zotero checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

private final class Fixture {
    let directory: URL
    var source: URL { directory.appendingPathComponent("zotero.sqlite") }
    var storedPDF: URL { directory.appendingPathComponent("storage/ATTACH01/paper.pdf") }
    let externalPDF: URL
    let pdfData = Data("%PDF-1.4\nSynthetic storage fixture\n%%EOF\n".utf8)
    let externalData = Data("%PDF-1.4\nSynthetic external fixture\n%%EOF\n".utf8)
    var db: OpaquePointer?

    init(_ root: URL, readOnly: Bool = true) throws {
        directory = root.appendingPathComponent("ZoteroData")
        externalPDF = root.appendingPathComponent("External/external.pdf")
        try FileManager.default.createDirectory(at: storedPDF.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalPDF.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdfData.write(to: storedPDF)
        try externalData.write(to: externalPDF)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("storage/ESCAPE01"), withDestinationURL: externalPDF.deletingLastPathComponent())
        guard sqlite3_open(source.path, &db) == SQLITE_OK else { throw PaperManagerError.message("fixture open failed") }
        try exec("""
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE items(itemID INTEGER PRIMARY KEY,itemTypeID INT,libraryID INT,key TEXT,dateAdded TEXT,dateModified TEXT,futureSourceColumn TEXT);
        CREATE TABLE itemTypes(itemTypeID INTEGER PRIMARY KEY,typeName TEXT);
        CREATE TABLE itemTypesCombined(itemTypeID INTEGER PRIMARY KEY,typeName TEXT);
        CREATE TABLE fields(fieldID INTEGER PRIMARY KEY,fieldName TEXT);
        CREATE TABLE fieldsCombined(fieldID INTEGER PRIMARY KEY,fieldName TEXT);
        CREATE TABLE itemDataValues(valueID INTEGER PRIMARY KEY,value TEXT);
        CREATE TABLE itemData(itemID INT,fieldID INT,valueID INT);
        CREATE TABLE creators(creatorID INTEGER PRIMARY KEY,firstName TEXT,lastName TEXT,fieldMode INT);
        CREATE TABLE creatorTypes(creatorTypeID INTEGER PRIMARY KEY,creatorType TEXT);
        CREATE TABLE itemCreators(itemID INT,creatorID INT,creatorTypeID INT,orderIndex INT);
        CREATE TABLE collections(collectionID INTEGER PRIMARY KEY,collectionName TEXT,parentCollectionID INT,libraryID INT,key TEXT,clientDateModified TEXT);
        CREATE TABLE collectionItems(collectionID INT,itemID INT,orderIndex INT);
        CREATE TABLE tags(tagID INTEGER PRIMARY KEY,name TEXT);
        CREATE TABLE itemTags(itemID INT,tagID INT,type INT);
        CREATE TABLE syncedSettings(setting TEXT,libraryID INT,value TEXT);
        CREATE TABLE itemNotes(itemID INTEGER PRIMARY KEY,parentItemID INT,note TEXT,title TEXT);
        CREATE TABLE itemAttachments(itemID INTEGER PRIMARY KEY,parentItemID INT,linkMode INT,contentType TEXT,path TEXT);
        CREATE TABLE itemAnnotations(itemID INTEGER PRIMARY KEY,parentItemID INT,type INT,text TEXT,comment TEXT,color TEXT,pageLabel TEXT,sortIndex TEXT,position TEXT,isExternal INT);
        CREATE TABLE deletedItems(itemID INTEGER PRIMARY KEY,dateDeleted TEXT);
        INSERT INTO itemTypes VALUES(1,'journalArticle'),(2,'bookSection'),(3,'attachment'),(4,'note'),(5,'annotation');
        INSERT INTO fields VALUES(1,'title'),(2,'date'),(3,'publicationTitle'),(4,'DOI'),(5,'unknownFixtureField'),(6,'extra'),(7,'bookTitle');
        INSERT INTO items VALUES(1,1,1,'PAPER001','2024-01-02 03:04:05','2024-06-07 08:09:10','kept verbatim');
        INSERT INTO items VALUES(3,1,1,'DELETED1','2024-01-02 03:04:05','2024-01-02 03:04:05',NULL);
        INSERT INTO items VALUES(10,3,1,'ATTACH01','2024-01-02 03:04:05','2024-01-02 03:04:05',NULL);
        INSERT INTO items VALUES(11,3,1,'EXTERN01','2024-01-02 03:04:05','2024-01-02 03:04:05',NULL);
        INSERT INTO items VALUES(12,3,1,'TRAVER01','2024-01-02 03:04:05','2024-01-02 03:04:05',NULL);
        INSERT INTO items VALUES(14,3,1,'ESCAPE01','2024-01-02 03:04:05','2024-01-02 03:04:05',NULL);
        INSERT INTO items VALUES(20,5,1,'ANNOT001','2024-02-03 04:05:06','2024-02-03 04:05:06',NULL);
        INSERT INTO items VALUES(30,4,1,'NOTE0001','2024-02-03 04:05:06','2024-02-03 04:05:06',NULL);
        INSERT INTO creators VALUES(1,'Ada','Lovelace',0),(2,NULL,'Synthetic Research Group',1),(3,'Grace','Hopper',0),(4,'Alan','Turing',0);
        INSERT INTO creatorTypes VALUES(1,'author'),(2,'editor'),(3,'translator');
        INSERT INTO itemCreators VALUES(1,1,1,0),(1,2,1,1),(1,3,2,2),(1,4,3,3),(2,1,1,0);
        INSERT INTO collections VALUES(100,'Root',NULL,1,'COLLECT1','2024-01-01 00:00:00'),(101,'Child',100,1,'COLLECT2','2024-01-01 00:00:00');
        INSERT INTO collectionItems VALUES(100,1,0),(101,1,0),(101,2,1);
        INSERT INTO tags VALUES(200,'Fixture Tag'),(201,'Second Tag');
        INSERT INTO itemTags VALUES(1,200,0),(1,201,1),(2,200,0);
        INSERT INTO syncedSettings VALUES('tagColors',1,'[{"name":"Fixture Tag","color":"#AABBCC"}]');
        INSERT INTO itemNotes VALUES(30,1,'<p>Original <b>HTML note</b></p>','Note');
        INSERT INTO itemAttachments VALUES(10,1,0,'application/pdf','storage:paper.pdf');
        INSERT INTO itemAttachments VALUES(11,1,2,'application/pdf','\(quote(externalPDF.path))');
        INSERT INTO itemAttachments VALUES(12,1,0,'application/pdf','storage:../../external.pdf');
        INSERT INTO itemAttachments VALUES(14,1,0,'application/pdf','storage:external.pdf');
        INSERT INTO itemAnnotations VALUES(20,10,1,'Selected fixture text','Annotation comment','#FFD166','iii','00002|000001','{"pageIndex":2,"rects":[[10,20,20,30],[25,20,40,30]]}',0);
        INSERT INTO deletedItems VALUES(3,'2024-01-01 00:00:00');
        """)
        try add(item: 1, field: 1, value: "Synthetic article")
        try add(item: 1, field: 2, value: "2024-05-06")
        try add(item: 1, field: 3, value: "Fixture Journal")
        try add(item: 1, field: 4, value: "10.1234/fixture")
        try add(item: 1, field: 5, value: "preserved custom value")
        try add(item: 1, field: 6, value: "Citation Key: OriginalFixtureKey")
        try add(item: 3, field: 1, value: "Deleted fixture")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try exec("INSERT INTO items VALUES(2,2,1,'PAPER002','2025-01-01 00:00:00','2025-01-01 00:00:00',NULL)")
        try add(item: 2, field: 1, value: "Committed only in WAL")
        try add(item: 2, field: 2, value: "2025")
        try add(item: 2, field: 7, value: "Fixture Book")
        if readOnly {
            for file in [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-shm"), storedPDF, externalPDF] {
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            }
        }
    }
    func add(item: Int, field: Int, value: String) throws {
        let id = item * 100 + field
        try exec("INSERT INTO itemDataValues VALUES(\(id),'\(quote(value))'); INSERT INTO itemData VALUES(\(item),\(field),\(id))")
    }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PaperManagerError.message(String(cString: sqlite3_errmsg(db))) }
    }
    func close() { if let db { sqlite3_close(db); self.db = nil } }
    deinit { close() }
    private func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}
