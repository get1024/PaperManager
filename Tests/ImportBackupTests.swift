import CoreGraphics
import CryptoKit
import Foundation

@main
@MainActor
struct ImportBackupTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-ImportBackup-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func main() async {
        var passed = 0
        var failed = 0
        let tests: [(String, () async throws -> Void)] = [
            ("BibTeX macros preserve spaces, concatenation and literal hashes", testMacros),
            ("BibTeX comments and escaped literals", testComments),
            ("PDF ISBN-10 and ISBN-13 checksum validation", testISBN),
            ("Preparation and deselection leave the library untouched", testPrepare),
            ("Duplicate replacement preserves local work and identity", testReplacement),
            ("Fresh commit detects duplicates within one batch", testBatchDuplicates),
            ("Repeated UUID in a batch never creates duplicate identities", testBatchIdentity),
            ("PDF replacement with automatic extraction retains manual annotations", testReplacementAnnotations),
            ("Deleted preview destinations never leave dangling membership", testDeletedTarget),
            ("Deleting a paper protects shared and read-only file references", testSharedDeletion),
            ("Failed persistence never reports a completed import", testImportPersistenceFailure),
            ("Durable update and restore failures retain published state", testDurableFailure),
            ("Restore detects another window's edits before replacing data", testRestoreRevision),
            ("Unreadable library is preserved before explicit durable recovery", testUnreadableRecovery),
            ("Read-only and shared protection follows moved file bookmarks", testResolvedProtection),
            ("Damaged PDF produces a preview error without insertion", testInvalidPDF),
            ("Portable backup retains attachment and annotation bytes", testPortable),
            ("Metadata-only backup retains original reference policy", testMetadataOnly),
            ("Tampered payload fails and removes only new extraction files", testTamper),
            ("Traversal manifest is rejected before extraction", testTraversal),
            ("Archive wildcard cannot concatenate members into one attachment", testArchiveWildcard),
            ("Portable metadata rejects duplicate identities and broken relationships", testArchiveIdentities),
            ("Portable file manifest must cover every declared file exactly once", testArchiveCoverage),
            ("All fifteen Lattice paper types retain chapter containers", testLatticeTypes),
            ("Custom template fields cannot replace standard metadata keys", testTemplateKeys),
            ("Legacy JSON readable and future portable version rejected", testVersions),
            ("Backup refuses directory and symlink destinations", testDestination)
        ]
        for (name, test) in tests {
            do { try await test(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    static func testMacros() async throws {
        let text = #"""
        @string{prefix = "Journal of "}
        @string{journal = prefix # "Science"}
        @article(a, title={A {nested # literal} title}, journal=JOURNAL,
          year=20 # 26, month=jan, author="Ada" # " and Alan")
        @string{prefix = "Changed "}
        @article{b,title=prefix # {Second},journal=unknownMacro}
        """#
        let papers = BibTeXParser.parse(text)
        try expect(papers.count == 2, "@string was imported as a paper")
        try expect(papers[0].journal == "Journal of Science", "Macro spacing/expansion lost")
        try expect(papers[0].title == "A {nested # literal} title", "Literal hash expanded")
        try expect(papers[0].authors == ["Ada", "Alan"] && papers[0].year == 2026, "Concatenation failed")
        try expect(papers[0].month == "January", "Standard month macro absent")
        try expect(papers[1].title == "Changed Second" && papers[1].journal == "unknownMacro", "Redefinition or unknown token lost")
    }

    static func testComments() async throws {
        let text = #"""
        % @article{fake,title={Ignore this}}
        @comment{ignored}
        @preamble{"ignored"}
        @article{real,
          % field comments contain unmatched " and }
          title="A # quoted" # % comment after concatenation
            { value},
          note={A \% and \& mark}, year=2026}
        """#
        let papers = BibTeXParser.parse(text)
        try expect(papers.count == 1 && papers[0].title == "A # quoted value", "Comment altered expression")
        try expect(papers[0].notes == "A % and & mark", "Escaped literal changed")
    }

    static func testISBN() async throws {
        try expect(PDFMetadataExtractor.extractISBN(from: "ISBN-13: 978-0-306-40615-7") == "9780306406157", "ISBN13 missing")
        try expect(PDFMetadataExtractor.extractISBN(from: "ISBN 0-8044-2957-X") == "080442957X", "ISBN10 missing")
        try expect(PDFMetadataExtractor.extractISBN(from: "ISBN: 978-0-306-40615-8") == nil, "Bad checksum accepted")
    }

    static func testPrepare() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bib")
        try "@article{test,title={Preview only},year={2026}}".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        let before = try Data(contentsOf: store.persistenceURL)
        var plan = await ImportService.prepare([source], store: store)
        try expect(plan.candidates.count == 1 && store.papers.isEmpty, "Preparation inserted a paper")
        try expect(try Data(contentsOf: store.persistenceURL) == before, "Preparation wrote the library")
        plan.candidates[0].isSelected = false
        let summary = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(summary.skipped == 1 && store.papers.isEmpty, "Deselected candidate imported")
    }

    static func testReplacement() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        var original = Paper(); original.title = "Original title"; original.doi = "10.5555/same"
        original.notes = "My local note"; original.rating = 4
        original.attachments = [Attachment(filePath: root.appendingPathComponent("owned.pdf").path, displayName: "Retain me", isReadOnlyReference: true)]
        original.annotations = [ResearchAnnotation(selectedText: "A local highlight")]
        let id = store.addPaper(original)
        let originalAdded = store.paper(with: id)!.dateAdded
        let tag = store.addTag(name: "Target")
        var incoming = Paper(); incoming.title = "Updated title"; incoming.doi = original.doi
        incoming.authors = ["New Author"]; incoming.notes = "Incoming note"; incoming.paperType = .report
        var plan = ImportService.prepare(papers: [incoming], store: store)
        try expect(plan.candidates[0].duplicateID == id, "Preview did not flag duplicate")
        let skip = await ImportService.commit(plan, into: store, targetFilter: .tag(tag))
        try expect(skip.skipped == 1 && store.paper(with: id)?.title == original.title, "Skip changed existing metadata")
        plan.candidates[0].duplicateAction = .replace
        let summary = await ImportService.commit(plan, into: store, targetFilter: .tag(tag))
        let updated = store.paper(with: id)!
        try expect(summary.replaced == 1 && store.papers.count == 1, "Replacement appended or lost the paper")
        try expect(updated.title == incoming.title && updated.authors == incoming.authors && updated.paperType == .report, "Metadata did not update")
        try expect(updated.dateAdded == originalAdded && updated.notes == original.notes && updated.rating == 4, "Local work overwritten")
        try expect(updated.attachments == original.attachments && updated.annotations == original.annotations && updated.tagIDs.contains(tag), "Attachments/annotations/target membership lost")
    }

    static func testBatchDuplicates() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var first = Paper(); first.title = "First"; first.doi = "10.5555/batch"
        var second = first; second.id = UUID(); second.title = "Second"
        let summary = await ImportService.commit(ImportService.prepare(papers: [first, second], store: store), into: store, targetFilter: nil)
        try expect(summary.imported == 1 && summary.skipped == 1 && store.papers.count == 1, "Batch duplicates inserted twice")
    }

    static func testBatchIdentity() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var paper = Paper(); paper.title = "One source item repeated"; paper.doi = "10.5555/same-identity"
        let plan = ImportService.prepare(papers: [paper, paper], store: store)
        let first = await ImportService.commit(plan, into: store, targetFilter: nil)
        let replay = await ImportService.commit(plan, into: store, targetFilter: nil)
        try expect(first.imported == 1 && first.skipped == 1, "Same UUID inserted twice within one batch")
        try expect(replay.imported == 0 && replay.skipped == 2, "Replaying the same plan inserted its identities again")
        try expect(store.papers.map(\.id) == [paper.id], "Store contains repeated paper UUIDs")
    }

    static func blankPDF(at url: URL) throws {
        var media = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else { throw Failure(message: "Cannot create fixture PDF") }
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
    }

    static func testReplacementAnnotations() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let oldPDF = root.appendingPathComponent("original.pdf"), newPDF = root.appendingPathComponent("incoming.pdf")
        try blankPDF(at: oldPDF); try blankPDF(at: newPDF)
        let originalBytes = try Data(contentsOf: oldPDF), incomingBytes = try Data(contentsOf: newPDF)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        store.updateSetting(\.autoExtractAnnotationsAfterImport, value: true)
        var original = Paper(); original.title = "Original"; original.doi = "10.5555/manual-annotations"
        original.attachments = [Attachment(kind: .pdf, filePath: oldPDF.path, displayName: "original.pdf")]
        original.annotations = [ResearchAnnotation(selectedText: "Hand-maintained excerpt", note: "Must survive metadata replacement")]
        let id = store.addPaper(original)
        var incoming = Paper(); incoming.title = "Updated"; incoming.doi = original.doi
        var plan = ImportService.prepare(papers: [incoming], store: store)
        plan.candidates[0].sourceURL = newPDF
        plan.candidates[0].duplicateAction = .replace
        let summary = await ImportService.commit(plan, into: store, targetFilter: nil)
        let updated = store.paper(with: id)!
        try expect(summary.replaced == 1 && summary.failed == 0, "Replacement failed")
        try expect(updated.primaryPDF?.id == original.primaryPDF?.id, "Replacement unexpectedly changed the existing primary PDF")
        try expect(updated.annotations == original.annotations, "Automatic extraction erased manual annotations during replacement")
        try expect(try Data(contentsOf: oldPDF) == originalBytes && Data(contentsOf: newPDF) == incomingBytes, "Replacement changed source PDF bytes")
    }

    static func testDeletedTarget() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let collection = store.addCollection(name: "Deleted while preview was open")
        let tag = store.addTag(name: "Deleted tag")
        var first = Paper(); first.title = "Collection target"
        var second = Paper(); second.title = "Tag target"
        let firstPlan = ImportService.prepare(papers: [first], store: store)
        let secondPlan = ImportService.prepare(papers: [second], store: store)
        store.deleteCollection(id: collection); store.deleteTag(id: tag)
        _ = await ImportService.commit(firstPlan, into: store, targetFilter: .collection(collection))
        _ = await ImportService.commit(secondPlan, into: store, targetFilter: .tag(tag))
        try expect(store.paper(with: first.id)?.collectionIDs.isEmpty == true, "Deleted collection UUID attached to imported record")
        try expect(store.paper(with: second.id)?.tagIDs.isEmpty == true, "Deleted tag UUID attached to imported record")
        try expect(store.filteredPapers(for: .unfiled, searchText: "", includeSubcollections: true).count == 2 &&
                   store.filteredPapers(for: .noTags, searchText: "", includeSubcollections: true).count == 2, "Dangling membership hid records from smart filters")
    }

    static func testSharedDeletion() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared.pdf"), unique = root.appendingPathComponent("unique.pdf")
        try Data("shared".utf8).write(to: shared); try Data("unique".utf8).write(to: unique)
        let alias = root.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        var trashed: [URL] = []
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"), trashFile: { trashed.append($0) })
        store.updateSetting(\.deleteAttachmentsToTrash, value: true)
        var deleting = Paper(); deleting.title = "Delete me"
        deleting.attachments = [Attachment(kind: .pdf, filePath: shared.path, displayName: "shared"),
                                Attachment(kind: .file, filePath: unique.path, displayName: "unique"),
                                Attachment(kind: .file, filePath: unique.path, displayName: "same unique file again")]
        var retained = Paper(); retained.title = "Retain me"
        retained.attachments = [Attachment(kind: .pdf, filePath: alias.path, displayName: "alias")]
        let deletingID = store.addPaper(deleting), retainedID = store.addPaper(retained)
        store.deletePapers(ids: [deletingID])
        try expect(trashed.map(\.path) == [unique.path] && store.paper(with: retainedID) != nil, "Shared file was trashed or repeated reference handled twice")
        var protected = Paper(); protected.title = "Read-only shared reference"
        protected.attachments = [Attachment(kind: .pdf, filePath: shared.path, displayName: "read only", isReadOnlyReference: true)]
        let protectedID = store.addPaper(protected)
        store.deletePapers(ids: [retainedID, protectedID])
        try expect(trashed.map(\.path) == [unique.path], "Read-only alias did not protect the same physical source")
        try expect(try Data(contentsOf: shared) == Data("shared".utf8), "Test modified the shared source")
    }

    static func testImportPersistenceFailure() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        // A regular file as the parent gives a deterministic write error even
        // when the test user has broad permissions. No production library is used.
        let blocked = root.appendingPathComponent("blocked-parent")
        let sentinel = Data("unrelated file must survive".utf8)
        try sentinel.write(to: blocked)
        let store = LibraryStore(persistenceURL: blocked.appendingPathComponent("library.json"))
        var paper = Paper(); paper.title = "Cannot be persisted"
        let summary = await ImportService.commit(ImportService.prepare(papers: [paper], store: store), into: store, targetFilter: nil)
        try expect(summary.imported == 0 && summary.failed == 1 && store.papers.isEmpty,
                   "Write failure reported imported=\(summary.imported), failed=\(summary.failed), in-memory rows=\(store.papers.count), status=\(store.statusMessage ?? "")")
        try expect(try Data(contentsOf: blocked) == sentinel, "Write failure damaged the blocking file")
    }

    static func testDurableFailure() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var original = Paper(); original.title = "Persisted title"
        let id = try store.addPaperDurably(original)
        let baseline = try store.snapshotRevisionToken()
        try FileManager.default.removeItem(at: store.persistenceURL)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: false)
        let sentinel = store.persistenceURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var edited = store.paper(with: id)!; edited.title = "Unsaved title"
        var updateRejected = false, replacementRejected = false, templateRejected = false
        do { try store.updatePaperDurably(edited) } catch { updateRejected = true }
        do { try store.replaceSnapshotDurably(.empty) } catch { replacementRejected = true }
        do { try MetadataTemplateService.update(in: store) { _ = try $0.addMetadataTemplate(name: "Unsaved template") } }
        catch { templateRejected = true }
        try expect(updateRejected && replacementRejected && templateRejected, "A directory at the save path was accepted")
        try expect(try store.snapshotRevisionToken() == baseline, "Failed write changed published metadata")
        try expect(try Data(contentsOf: sentinel) == Data("keep".utf8), "Failed write replaced unrelated directory contents")
    }

    static func testRestoreRevision() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var paper = Paper(); paper.title = "Initial"
        let id = try store.addPaperDurably(paper)
        let initial = try store.snapshotRevisionToken()
        var anotherWindow = store.paper(with: id)!; anotherWindow.notes = "Edited while restore was preparing"
        try store.updatePaperDurably(anotherWindow)
        let persisted = try Data(contentsOf: store.persistenceURL)
        var rejected = false
        do { try store.replaceSnapshotDurably(.empty, expectedRevision: initial) } catch { rejected = true }
        try expect(rejected && store.paper(with: id)?.notes == anotherWindow.notes, "Restore overwrote another window's edits")
        try expect(try Data(contentsOf: store.persistenceURL) == persisted, "Rejected restore changed saved data")
        let current = try store.snapshotRevisionToken()
        try store.replaceSnapshotDurably(.empty, expectedRevision: current)
        try expect(store.papers.isEmpty, "Unchanged snapshot could not be restored")
    }

    static func testUnreadableRecovery() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("library.json"), damaged = Data("{unreadable original".utf8)
        try damaged.write(to: location)
        let store = LibraryStore(persistenceURL: location)
        try expect(store.loadError != nil, "Unreadable library did not establish protection")
        var denied = false
        do { _ = try store.addPaperDurably(Paper()) } catch { denied = true }
        try expect(try Data(contentsOf: location) == damaged && denied && store.papers.isEmpty, "Mutation bypassed unreadable-file protection")
        var recovered = LibrarySnapshot(); var paper = Paper(); paper.title = "Recovered"; recovered.papers = [paper]
        try store.replaceSnapshotDurably(recovered)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-unreadable-") }
        try expect(store.loadError == nil && store.papers.count == 1 && preserved.count == 1, "Explicit recovery did not commit safely")
        try expect(try Data(contentsOf: preserved[0]) == damaged, "Original unreadable bytes were lost")
    }

    static func testResolvedProtection() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("old.pdf"), moved = root.appendingPathComponent("moved.pdf")
        let payload = Data("only a synthetic source".utf8)
        try payload.write(to: original)
        let bookmark = try original.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        try FileManager.default.moveItem(at: original, to: moved)
        let attachment = Attachment(kind: .pdf, filePath: original.path, displayName: "old.pdf",
                                    bookmarkData: bookmark, isReadOnlyReference: true)
        try expect(try FileLibraryService.canonicalURL(attachment.resolvedURL()).path == FileLibraryService.canonicalURL(moved).path,
                   "Fixture bookmark failed to follow the move")
        var protected = Paper(); protected.title = "Source reference"; protected.citekey = "renamed2026"; protected.attachments = [attachment]
        var snapshot = LibrarySnapshot(); snapshot.papers = [protected]; snapshot.settings.autoRenamePDFs = true
        snapshot.settings.pdfRenameTemplate = "{citekey}"
        var renameDenied = false
        do { _ = try FileLibraryService.renamePlan(attachment: attachment, paper: protected, snapshot: snapshot) }
        catch { renameDenied = true }
        try expect(renameDenied, "Stale literal path let a read-only bookmark source be renamed")
        var writable = attachment; writable.isReadOnlyReference = false
        snapshot.papers[0].attachments = [writable]
        var shared = Paper(); shared.title = "Another bookmark reference"; var alias = writable; alias.id = UUID()
        shared.attachments = [alias]; snapshot.papers.append(shared)
        var sharedRenameDenied = false
        do { _ = try FileLibraryService.renamePlan(attachment: writable, paper: snapshot.papers[0], snapshot: snapshot) }
        catch { sharedRenameDenied = true }
        try expect(sharedRenameDenied, "Resolved shared bookmark source could be renamed out from under another paper")
        snapshot.papers = [protected]
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let libraryRoot = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: false)
        snapshot.settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: libraryRoot.path)
        snapshot.settings.pdfOrganizationMode = .move; snapshot.settings.confirmBeforeMovingFiles = false
        try store.replaceSnapshotDurably(snapshot)
        var receiving = Paper(); receiving.title = "Receiver"
        let receivingID = try store.addPaperDurably(receiving)
        var attachDenied = false
        do { try store.attachFile(moved, to: receivingID, kind: .pdf) } catch { attachDenied = true }
        try expect(attachDenied && store.paper(with: receivingID)?.attachments.isEmpty == true, "Attachment move bypassed resolved read-only source protection")
        try expect(try Data(contentsOf: moved) == payload, "Protected source was changed")
    }

    static func testInvalidPDF() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("damaged.pdf")
        try Data("not a PDF".utf8).write(to: source)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let plan = await ImportService.prepare([source], store: store)
        try expect(plan.candidates.isEmpty && plan.failures.count == 1 && store.papers.isEmpty, "Damaged PDF created a phantom record")
    }

    static func fixture(_ root: URL) throws -> LibrarySnapshot {
        let pdf = root.appendingPathComponent("source.pdf")
        let image = root.appendingPathComponent("annotation.png")
        try Data("Preserved PDF bytes".utf8).write(to: pdf)
        try Data("Preserved annotation image".utf8).write(to: image)
        var paper = Paper(); paper.title = "Portable fixture"
        paper.attachments = [Attachment(kind: .pdf, filePath: pdf.path, displayName: "source.pdf", isReadOnlyReference: true)]
        paper.annotations = [ResearchAnnotation(selectedText: "Highlight", imageFilePath: image.path)]
        var snapshot = LibrarySnapshot(); snapshot.papers = [paper]
        return snapshot
    }

    static func testPortable() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let backup = root.appendingPathComponent("library.papermanager")
        try BackupService.writeBackup(snapshot: snapshot, to: backup)
        let restored = try BackupService.readBackup(from: backup, filesDirectory: root.appendingPathComponent("restored"))
        let attachment = restored.papers[0].attachments[0]
        try expect(attachment.filePath != snapshot.papers[0].attachments[0].filePath && !attachment.isReadOnlyReference, "Restored file retained original ownership/path")
        try expect(try Data(contentsOf: attachment.url) == Data("Preserved PDF bytes".utf8), "PDF bytes changed")
        try expect(try Data(contentsOf: URL(fileURLWithPath: restored.papers[0].annotations[0].imageFilePath!)) == Data("Preserved annotation image".utf8), "Annotation image lost")
        try expect(try Data(contentsOf: snapshot.papers[0].attachments[0].url) == Data("Preserved PDF bytes".utf8), "Backup modified source")
    }

    static func testMetadataOnly() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let backup = root.appendingPathComponent("metadata.papermanager")
        try BackupService.writeBackup(snapshot: snapshot, to: backup, includeFiles: false)
        let output = root.appendingPathComponent("should-not-exist")
        let restored = try BackupService.readBackup(from: backup, filesDirectory: output)
        try expect(restored.papers[0].attachments == snapshot.papers[0].attachments, "Reference policy changed")
        try expect(!FileManager.default.fileExists(atPath: output.path), "Metadata-only restore created file directory")
    }

    static func modifyManifest(_ backup: URL, root: URL, change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", backup.path, "manifest.json"]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        var manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        change(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", backup.path, "manifest.json"]; zip.currentDirectoryURL = root
        try zip.run(); zip.waitUntilExit()
        return manifest
    }

    static func testTamper() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("tampered.papermanager")
        try BackupService.writeBackup(snapshot: fixture(root), to: backup)
        _ = try modifyManifest(backup, root: root) { manifest in
            var records = manifest["files"] as! [[String: Any]]
            records[0]["sha256"] = String(repeating: "0", count: 64)
            manifest["files"] = records
        }
        let output = root.appendingPathComponent("extract")
        do { _ = try BackupService.readBackup(from: backup, filesDirectory: output); throw Failure(message: "Tamper accepted") }
        catch is Failure { throw Failure(message: "Tamper accepted") }
        catch { try expect(!FileManager.default.fileExists(atPath: output.path), "Failed extraction left owned files") }
    }

    static func testTraversal() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("traversal.papermanager")
        try BackupService.writeBackup(snapshot: fixture(root), to: backup)
        _ = try modifyManifest(backup, root: root) { manifest in
            var records = manifest["files"] as! [[String: Any]]
            records[0]["entry"] = "../escape"
            manifest["files"] = records
        }
        do { _ = try BackupService.readBackup(from: backup); throw Failure(message: "Traversal accepted") }
        catch is Failure { throw Failure(message: "Traversal accepted") }
        catch { try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path), "Traversal escaped") }
    }

    static func writeArchive(_ root: URL, snapshot: LibrarySnapshot, includesFiles: Bool,
                             records: [[String: Any]] = [], files: [String: Data] = [:]) throws -> URL {
        let staging = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("files"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(snapshot).write(to: staging.appendingPathComponent("snapshot.json"))
        let manifest: [String: Any] = ["format": "papermanager", "version": 2, "includesFiles": includesFiles, "files": records]
        try JSONSerialization.data(withJSONObject: manifest).write(to: staging.appendingPathComponent("manifest.json"))
        for (name, data) in files { try data.write(to: staging.appendingPathComponent("files/" + name)) }
        let archive = root.appendingPathComponent(UUID().uuidString + ".papermanager")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]; zip.currentDirectoryURL = staging
        try zip.run(); zip.waitUntilExit()
        try expect(zip.terminationStatus == 0, "Fixture ZIP failed")
        return archive
    }

    static func expectRejectedArchive(_ archive: URL, root: URL, reason: String) throws {
        let destination = root.appendingPathComponent("extract-" + UUID().uuidString)
        var rejected = false
        do { _ = try BackupService.readBackup(from: archive, filesDirectory: destination) }
        catch { rejected = true }
        try expect(rejected, reason)
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Rejected archive left extraction files")
    }

    static func testArchiveWildcard() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        var paper = Paper(); paper.title = "Glob payload"
        let attachment = Attachment(kind: .pdf, filePath: "previous.pdf", displayName: "combined.pdf")
        paper.attachments = [attachment]
        var snapshot = LibrarySnapshot(); snapshot.papers = [paper]
        let payload = Data("AB".utf8)
        let record: [String: Any] = ["paperID": paper.id.uuidString, "itemID": attachment.id.uuidString,
            "annotationImage": false, "entry": "files/*", "byteCount": payload.count,
            "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
        let archive = try writeArchive(root, snapshot: snapshot, includesFiles: true, records: [record],
                                       files: ["first": Data("A".utf8), "second": Data("B".utf8)])
        try expectRejectedArchive(archive, root: root, reason: "Wildcard member concatenation accepted with a matching combined checksum")
    }

    static func testArchiveIdentities() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        var paper = Paper(); paper.title = "Metadata identity fixture"
        let collection = PaperCollection(name: "Root"), tag = PaperTag(name: "Tag")
        paper.collectionIDs = [collection.id]; paper.tagIDs = [tag.id]
        paper.attachments = [Attachment(filePath: "reference.pdf", displayName: "reference")]
        paper.annotations = [ResearchAnnotation(selectedText: "Note")]
        paper.customFields = [CustomField(key: "extra", value: "value")]
        var valid = LibrarySnapshot(); valid.papers = [paper]; valid.collections = [collection]; valid.tags = [tag]
        let variants: [(String, (inout LibrarySnapshot) -> Void)] = [
            ("future snapshot schema", { $0.schemaVersion = 99 }),
            ("paper identity", { $0.papers.append($0.papers[0]) }),
            ("collection identity", { $0.collections.append($0.collections[0]) }),
            ("tag identity", { $0.tags.append($0.tags[0]) }),
            ("attachment identity", { $0.papers[0].attachments.append($0.papers[0].attachments[0]) }),
            ("annotation identity", { $0.papers[0].annotations.append($0.papers[0].annotations[0]) }),
            ("custom field identity", { $0.papers[0].customFields.append($0.papers[0].customFields[0]) }),
            ("metadata template identity", {
                let template = MetadataTemplate(name: "Repeated template", content: "{{title}}")
                $0.metadataTemplates = [template, template]
            }),
            ("missing collection", { $0.papers[0].collectionIDs = [UUID()] }),
            ("missing tag", { $0.papers[0].tagIDs = [UUID()] }),
            ("missing parent", { $0.collections[0].parentID = UUID() }),
            ("cyclic collection", { $0.collections[0].parentID = $0.collections[0].id }),
            ("four collection levels", { snapshot in
                let second = PaperCollection(name: "Second", parentID: collection.id)
                let third = PaperCollection(name: "Third", parentID: second.id)
                let fourth = PaperCollection(name: "Fourth", parentID: third.id)
                snapshot.collections += [second, third, fourth]
            })
        ]
        for (label, mutate) in variants {
            var invalid = valid; mutate(&invalid)
            let archive = try writeArchive(root, snapshot: invalid, includesFiles: false)
            try expectRejectedArchive(archive, root: root, reason: "Invalid \(label) accepted")
            let legacy = root.appendingPathComponent(UUID().uuidString + ".json")
            try BackupService.writeBackup(snapshot: invalid, to: legacy)
            try expectRejectedArchive(legacy, root: root, reason: "Legacy JSON bypassed integrity validation for \(label)")
        }
    }

    static func testArchiveCoverage() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let incomplete = root.appendingPathComponent("incomplete.papermanager")
        try BackupService.writeBackup(snapshot: snapshot, to: incomplete)
        _ = try modifyManifest(incomplete, root: root) { manifest in
            var records = manifest["files"] as! [[String: Any]]; records.removeLast(); manifest["files"] = records
        }
        try expectRejectedArchive(incomplete, root: root, reason: "Partial file backup silently mixed restored and original paths")
        let contradictory = root.appendingPathComponent("contradictory.papermanager")
        try BackupService.writeBackup(snapshot: snapshot, to: contradictory)
        _ = try modifyManifest(contradictory, root: root) { $0["includesFiles"] = false }
        try expectRejectedArchive(contradictory, root: root, reason: "Metadata-only manifest accepted file records")

        // A count alone is insufficient: an image record for another annotation
        // must not stand in for the annotation which actually declares a file.
        var redirected = snapshot
        let imageWithoutSource = ResearchAnnotation(selectedText: "No image in snapshot")
        redirected.papers[0].annotations.append(imageWithoutSource)
        let paper = redirected.papers[0], attachment = paper.attachments[0]
        let pdf = Data("PDF payload".utf8), image = Data("image payload".utf8)
        let pdfName = "\(paper.id)-attachment-\(attachment.id).pdf"
        let imageName = "\(paper.id)-image-\(imageWithoutSource.id).png"
        func record(id: UUID, isImage: Bool, name: String, payload: Data) -> [String: Any] {
            ["paperID": paper.id.uuidString, "itemID": id.uuidString, "annotationImage": isImage,
             "entry": "files/" + name, "byteCount": payload.count,
             "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
        }
        let redirectedArchive = try writeArchive(root, snapshot: redirected, includesFiles: true,
            records: [record(id: attachment.id, isImage: false, name: pdfName, payload: pdf),
                      record(id: imageWithoutSource.id, isImage: true, name: imageName, payload: image)],
            files: [pdfName: pdf, imageName: image])
        try expectRejectedArchive(redirectedArchive, root: root, reason: "Equal record count hid a missing image and redirected bytes to an annotation without an image")
    }

    static func testLatticeTypes() async throws {
        try expect(PaperType.allCases.count == 15, "Expected fifteen source paper types")
        for type in PaperType.allCases {
            let source: [String: Any] = ["id": UUID().uuidString, "title": "Type fixture", "authors": [],
                "paperType": type.rawValue, "cslItem": ["container-title": "Edited Volume"]]
            let paper = try JSONDecoder().decode(LatticePaperMetadata.self, from: JSONSerialization.data(withJSONObject: source)).asPaper
            try expect(paper.paperType == type, "Lattice type \(type.rawValue) was lost")
            if [.inBook, .inCollection, .inProceedings].contains(type) {
                try expect(paper.bookTitle == "Edited Volume", "Chapter container missing for \(type.rawValue)")
            }
        }
    }

    static func testTemplateKeys() async throws {
        var paper = Paper(); paper.title = "Real title"; paper.doi = "10.5555/real"; paper.citekey = "real2026"
        paper.customFields = [CustomField(key: "title", value: "Forged title"), CustomField(key: "doi", value: "forged DOI"),
                              CustomField(key: "pdfURL", value: "forged URL"), CustomField(key: "special", value: "User extension")]
        let snapshot = LibrarySnapshot()
        let context = TemplateRenderer.context(for: paper, snapshot: snapshot)
        let rendered = TemplateRenderer.render(template: "{{title}}|{{doi}}|{{pdfURL}}|{{special}}", context: context)
        try expect(rendered == "Real title|10.5555/real||User extension", "Custom field replaced standard metadata (including an intentionally empty standard field)")
    }

    static func testVersions() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try fixture(root)
        let legacy = root.appendingPathComponent("legacy.json")
        try BackupService.writeBackup(snapshot: snapshot, to: legacy)
        try expect(try BackupService.readBackup(from: legacy).papers[0].id == snapshot.papers[0].id, "Legacy JSON unreadable")
        let backup = root.appendingPathComponent("future.papermanager")
        try BackupService.writeBackup(snapshot: snapshot, to: backup, includeFiles: false)
        _ = try modifyManifest(backup, root: root) { $0["version"] = 99 }
        do { _ = try BackupService.readBackup(from: backup); throw Failure(message: "Future version accepted") }
        catch is Failure { throw Failure(message: "Future version accepted") }
        catch { }
    }

    static func testDestination() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("directory.papermanager")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        do { try BackupService.writeBackup(snapshot: LibrarySnapshot(), to: target); throw Failure(message: "Directory replaced") }
        catch is Failure { throw Failure(message: "Directory replaced") }
        catch { try expect(FileManager.default.fileExists(atPath: sentinel.path), "Directory data lost") }
        let link = root.appendingPathComponent("link.papermanager")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        do { try BackupService.writeBackup(snapshot: LibrarySnapshot(), to: link); throw Failure(message: "Symlink replaced") }
        catch is Failure { throw Failure(message: "Symlink replaced") }
        catch { try expect(try Data(contentsOf: sentinel) == Data("keep".utf8), "Symlink target modified") }
    }
}
