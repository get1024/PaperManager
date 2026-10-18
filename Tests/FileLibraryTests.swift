import Foundation

private struct FileLibraryTestFailure: Error, CustomStringConvertible { var description: String }

@main
@MainActor
struct FileLibraryTests {
    static var passed = 0
    static var failed: [String] = []

    static func main() throws {
        let root = FileLibraryService.canonicalURL(FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-FileLibrary-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        run("Old settings decode and migrate a single root without guessing two conflicting roots") {
            let first = try directory(root, "legacy-first"), second = try directory(root, "legacy-second")
            var settings = AppSettings.defaults
            settings.pdfOrganizationFolder = first.path
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            try expect(decoded.fileLibrary == nil && FileLibraryService.preferences(for: decoded).rootPath == first.path, "Older settings did not preserve their selected root")
            settings.browserUploadFolder = second.path
            try expect(FileLibraryService.status(for: settings).availability == .legacyConflict, "Distinct legacy roots were silently merged")
            settings.browserUploadFolder = first.path
            try expect(FileLibraryService.status(for: settings).isAvailable, "Identical legacy roots were treated as a conflict")
            settings.fileLibrary = FileLibraryPreferences(decision: .declined)
            try expect(FileLibraryService.status(for: settings).availability == .declined, "Explicit decline was overridden by old paths")
        }
        run("Folder authorization, unavailable roots and invalid bookmarks produce actual states") {
            let folder = try directory(root, "availability")
            var settings = AppSettings.defaults
            settings.fileLibrary = try FileLibraryService.authorizedPreferences(root: folder)
            try expect(settings.fileLibrary?.rootBookmark != nil && FileLibraryService.status(for: settings).isAvailable, "Authorized existing root is not available")
            settings.fileLibrary?.rootBookmark = Data("invalid bookmark".utf8)
            try expect(FileLibraryService.status(for: settings).availability == .unavailable, "Corrupt authorization silently fell back to a raw path")
            settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: folder.path)
            try FileManager.default.removeItem(at: folder)
            try expect(FileLibraryService.status(for: settings).availability == .unavailable, "Missing configured folder was reported available")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            settings.fileLibrary = try FileLibraryService.authorizedPreferences(root: folder)
            try expect(FileLibraryService.status(for: settings).isAvailable, "Reauthorization did not repair the root")
        }
        run("Copy handles primary PDFs and arbitrary attachments with separate layout and Unsorted grouping") {
            let store = try fixtureStore(root, "copy"), folder = try directory(root, "copy-managed")
            configure(store, folder: folder, mode: .copy, grouping: .year)
            let paper = store.addPaper(Paper(title: "File fixture"))
            let pdf = try file(root, "copy-source.pdf", "PDF fixture"), extra = try file(root, "copy-source.csv", "a,b\n1,2")
            try store.attachFile(pdf, to: paper, kind: .pdf)
            try store.attachFile(extra, to: paper, kind: .file)
            let saved = store.paper(with: paper)!
            try expect(saved.attachments.count == 2 && saved.primaryPDF?.filePath == folder.appendingPathComponent("Unsorted/copy-source.pdf").path, "Primary PDF placement did not use stable Unsorted")
            try expect(saved.attachments.first { $0.kind == .file }?.filePath == folder.appendingPathComponent("Attachments/Unsorted/\(paper)/copy-source.csv").path, "Non-PDF attachment did not use the managed namespace")
            try expect(FileManager.default.fileExists(atPath: pdf.path) && FileManager.default.fileExists(atPath: extra.path), "Copy removed a local source")
            let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
            try expect(reloaded.paper(with: paper)?.attachments.map(\.filePath) == saved.attachments.map(\.filePath), "Attachment placement was not persisted")
        }
        run("Move uses one paper container and the first collection in sidebar order") {
            let store = try fixtureStore(root, "move"), folder = try directory(root, "move-managed")
            configure(store, folder: folder, mode: .move, grouping: .collection, layout: .byPaper)
            let first = store.addCollection(name: "First"), second = store.addCollection(name: "Second")
            var paper = Paper(title: "Moved fixture")
            paper.collectionIDs = [second, first]
            let id = store.addPaper(paper)
            let pdf = try file(root, "move-source.pdf", "PDF fixture"), extra = try file(root, "move-source.json", "{}")
            try store.attachFile(pdf, to: id, kind: .pdf)
            try store.attachFile(extra, to: id, kind: .file)
            let attachments = store.paper(with: id)!.attachments
            try expect(attachments.allSatisfy { $0.filePath.hasPrefix(folder.appendingPathComponent("First/\(id)").path + "/") }, "Placement used relationship insertion order instead of sidebar order")
            try expect(!FileManager.default.fileExists(atPath: pdf.path) && !FileManager.default.fileExists(atPath: extra.path), "Move did not handle both file kinds")
        }
        run("Read-only source references cannot move or rename and copy retains source bytes") {
            let store = try fixtureStore(root, "protected"), folder = try directory(root, "protected-managed")
            configure(store, folder: folder, mode: .move)
            let source = try file(root, "protected.pdf", "immutable source")
            var paper = Paper(title: "Protected fixture")
            paper.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: "protected.pdf", isReadOnlyReference: true)]
            let id = store.addPaper(paper), another = store.addPaper(Paper(title: "Another fixture"))
            try expectThrows { try store.attachFile(source, to: another) }
            store.updateSetting(\.autoRenamePDFs, value: true)
            store.updateSetting(\.pdfRenameTemplate, value: "{{citekey}}")
            let renamed = try store.renameFiles(paperIDs: [id])
            try expect(renamed.completed == 0 && !renamed.messages.isEmpty, "Read-only source was renamed")
            store.updateSetting(\.pdfOrganizationMode, value: .copy)
            try store.attachFile(source, to: another)
            try expect(try String(contentsOf: source) == "immutable source" && store.paper(with: another)?.primaryPDF?.isReadOnlyReference == false, "Copy changed source authority or bytes")
        }
        run("Shared source relationships block destructive relocation") {
            let store = try fixtureStore(root, "shared"), folder = try directory(root, "shared-managed")
            configure(store, folder: folder, mode: .move)
            let source = try file(root, "shared.txt", "shared bytes")
            for title in ["Shared one", "Shared two"] {
                var paper = Paper(title: title)
                paper.attachments = [Attachment(kind: .file, filePath: source.path, displayName: "shared.txt")]
                _ = store.addPaper(paper)
            }
            let summary = try store.organizeFiles(paperIDs: Set(store.papers.map(\.id)))
            try expect(summary.completed == 0 && summary.messages.count == 2 && FileManager.default.fileExists(atPath: source.path), "Shared source was moved or a relationship invalidated")
        }
        run("Destination races and symlink escapes never overwrite existing files") {
            let store = try fixtureStore(root, "collision"), folder = try directory(root, "collision-managed")
            configure(store, folder: folder, mode: .copy)
            let source = try file(root, "collision.txt", "source bytes"), paper = Paper(title: "Collision fixture")
            let plan = try FileLibraryService.plan(source: source, paper: paper, snapshot: store.snapshot, kind: .file)
            try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("destination created after plan".utf8).write(to: plan.destination)
            try expectThrows { _ = try FileLibraryService.execute(plan) }
            try expect(try String(contentsOf: plan.destination) == "destination created after plan" && String(contentsOf: source) == "source bytes", "A race overwrote source or destination")
            let outside = try directory(root, "outside"), escaped = try directory(root, "escape-managed")
            try FileManager.default.createSymbolicLink(at: escaped.appendingPathComponent("Attachments"), withDestinationURL: outside)
            configure(store, folder: escaped, mode: .copy)
            try expectThrows { _ = try FileLibraryService.plan(source: source, paper: paper, snapshot: store.snapshot, kind: .file) }
            try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Placement escaped through a symlink")
        }
        run("Placement receipts restore moves and reject changed sources") {
            let store = try fixtureStore(root, "rollback"), folder = try directory(root, "rollback-managed")
            configure(store, folder: folder, mode: .move)
            let source = try file(root, "rollback.pdf", "rollback source"), paper = Paper(title: "Rollback fixture")
            let plan = try FileLibraryService.plan(source: source, paper: paper, snapshot: store.snapshot)
            let receipt = try FileLibraryService.execute(plan)
            try receipt.rollback()
            try expect(try String(contentsOf: source) == "rollback source" && !FileManager.default.fileExists(atPath: plan.destination.path), "Rollback did not restore the source")
            let changed = try FileLibraryService.plan(source: source, paper: paper, snapshot: store.snapshot)
            try Data("changed source with different size".utf8).write(to: source)
            try expectThrows { _ = try FileLibraryService.execute(changed) }
            try expect(!FileManager.default.fileExists(atPath: changed.destination.path), "Changed source was copied using a stale plan")
        }
        run("A failed library write rolls back moved files and retains in-memory relationships") {
            let parent = try directory(root, "blocked-persistence")
            let store = LibraryStore(persistenceURL: parent.appendingPathComponent("library.json"))
            let folder = try directory(root, "failed-save-managed")
            configure(store, folder: folder, mode: .move)
            let id = store.addPaper(Paper(title: "Persistence fixture"))
            let source = try file(root, "failed-save.pdf", "original bytes")
            try FileManager.default.removeItem(at: parent)
            try Data("block parent directory".utf8).write(to: parent)
            try expectThrows { try store.attachFile(source, to: id, kind: .pdf) }
            try expect(try String(contentsOf: source) == "original bytes" && store.paper(with: id)?.attachments.isEmpty == true, "Persistence failure left a missing source or changed relationship")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Persistence failure retained an untracked managed copy")
        }
        run("Switching roots is future-only and explicit organization applies the new layout") {
            let store = try fixtureStore(root, "future"), first = try directory(root, "future-first"), second = try directory(root, "future-second")
            configure(store, folder: first, mode: .copy)
            let id = store.addPaper(Paper(title: "Future fixture")), source = try file(root, "future.pdf", "future bytes")
            try store.attachFile(source, to: id)
            let old = store.paper(with: id)!.primaryPDF!.filePath
            configure(store, folder: second, mode: .copy, layout: .byPaper)
            try expect(store.paper(with: id)!.primaryPDF!.filePath == old && FileManager.default.fileExists(atPath: old), "Changing root silently moved an existing file")
            let result = try store.organizeFiles(paperIDs: [id])
            let new = store.paper(with: id)!.primaryPDF!.filePath
            try expect(result.completed == 1 && new.hasPrefix(second.appendingPathComponent(id.uuidString).path) && FileManager.default.fileExists(atPath: old), "Explicit new-root copy did not preserve existing source")
            configure(store, folder: second, mode: .none, layout: .separate)
            let changed = try store.organizeFiles(paperIDs: [id])
            try expect(changed.completed == 1 && store.paper(with: id)!.primaryPDF!.filePath == second.appendingPathComponent("future.pdf").path, "Managed layout was not applied independently of local Do Nothing")
        }
        run("Managed imports copy regardless of local Move and naming preserves missing required variables") {
            let store = try fixtureStore(root, "managed"), folder = try directory(root, "managed-root")
            configure(store, folder: folder, mode: .move)
            let id = store.addPaper(Paper(title: "Managed fixture")), source = try file(root, "managed-source.csv", "a,b")
            try store.attachManagedFile(source, to: id, kind: .file)
            try expect(FileManager.default.fileExists(atPath: source.path) && store.paper(with: id)?.attachments.first?.filePath != source.path, "Managed import moved its source according to the local action")
            let paper = Paper(title: "A very long title", authors: ["Einstein, Albert", "Bohr, Niels"], year: 1905)
            try expect(FileLibraryService.filenameStem(paper: paper, template: "{year} - {authEtAl} - {title:5}", fallback: "source") == "1905 - Einstein et al. - A ver", "Current naming tokens were not rendered")
            var missing = paper; missing.year = nil
            try expect(FileLibraryService.filenameStem(paper: missing, template: "{year} - {title}", fallback: "source") == "source", "A missing required variable produced a partial filename")
        }
        failed.forEach { print("FAIL: \($0)") }
        print("File Library tests: \(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { exit(1) }
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS: \(name)") }
        catch { failed.append("\(name): \(error)") }
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw FileLibraryTestFailure(description: message) }
    }
    static func expectThrows(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw FileLibraryTestFailure(description: "Expected operation to fail safely")
    }
    static func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func file(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    static func fixtureStore(_ root: URL, _ name: String) throws -> LibraryStore {
        LibraryStore(persistenceURL: try directory(root, name).appendingPathComponent("library.json"))
    }
    static func configure(_ store: LibraryStore, folder: URL, mode: PDFOrganizationMode, grouping: PDFSubfolderGrouping = .none, layout: FileLibraryLayout = .separate) {
        var settings = store.settings
        settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: folder.path, layout: layout)
        settings.pdfOrganizationMode = mode
        settings.pdfSubfolderGrouping = grouping
        settings.confirmBeforeMovingFiles = false
        settings.autoRenamePDFs = false
        store.updateSettings(settings)
    }
}
