import Foundation

private struct LocalizationTestFailure: Error, CustomStringConvertible { var description: String }

@main
@MainActor
struct LocalizationTemplateTests {
    static var passed = 0
    static var failed: [String] = []

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManager-Localization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); PMLocalization.configure("system") }

        run("English and Chinese UI resource lookups and dynamic enums actually change") {
            PMLocalization.configure("en")
            try expect(PMLocalization.text("全部文献") == "All Papers", "English resource was not loaded from the executable bundle")
            try expect(PaperType.article.label == "Journal Article" && LibraryFilter.all.title == "All Papers", "Dynamic model UI labels were not translated")
            try expect(FileLibraryLayout.byPaper.label == "One Folder per Paper" && AppearanceChoice.dark.label == "Dark", "Settings enum labels did not change")
            try expect(PMLocalization.format("%lld 星", 4) == "4 Stars", "Formatted AppKit labels were not translated")
            PMLocalization.configure("zh-Hans")
            try expect(PMLocalization.text("全部文献") == "全部文献" && PaperType.article.label == "期刊论文", "Chinese resources did not restore labels")
            try expect(PMLocalization.text("Highlight") == "高亮", "English-key annotation labels were not translated into Chinese")
        }
        run("Language changes never translate bibliography, user names, or machine values") {
            PMLocalization.configure("en")
            var snapshot = LibrarySnapshot.empty
            let collection = PaperCollection(name: "文集"), tag = PaperTag(name: "标签")
            snapshot.collections = [collection]; snapshot.tags = [tag]
            var paper = Paper(title: "全部文献", authors: ["作者"], year: 2026, notes: "备注")
            paper.collectionIDs = [collection.id]; paper.tagIDs = [tag.id]
            let context = TemplateRenderer.context(for: paper, snapshot: snapshot)
            try expect(context["title"] == "全部文献" && context["authors"] == "作者" && context["collections"] == "文集" && context["tags"] == "标签", "User data was translated as UI")
            try expect(context["type"] == "article" && paper.paperType.bibTeXType == "article", "A machine type changed with UI language")
            try expect(ExportService.bibTeX(for: [paper]).contains("title = {全部文献}"), "Export translated a paper title")
        }
        run("Old snapshots retain independent metadata and annotation template strings") {
            var original = LibrarySnapshot.empty
            original.settings.metadataTemplate = "Legacy {{title}}"
            original.settings.annotationTemplate = "Legacy annotation {{page}}"
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            object.removeValue(forKey: "metadataTemplates")
            let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            try expect(decoded.metadataTemplates == nil && decoded.availableMetadataTemplates.count == 1, "Older snapshots no longer supply a usable template")
            try expect(decoded.selectedMetadataTemplate.id == MetadataTemplate.legacyID && decoded.selectedMetadataTemplate.content == "Legacy {{title}}", "Legacy content or stable identity changed")
            try expect(decoded.settings.annotationTemplate == original.settings.annotationTemplate, "Annotation template was overwritten by metadata migration")
        }
        run("Multiple templates select, edit, render, and delete without altering another template") {
            var snapshot = LibrarySnapshot.empty
            snapshot.settings.metadataTemplate = "Original {{title}}"
            let first = snapshot.selectedMetadataTemplate.id
            let second = try snapshot.addMetadataTemplate(name: "中文模板", content: "Second {{title}}")
            try expect(snapshot.selectedMetadataTemplate.id == second && snapshot.settings.metadataTemplate == "Second {{title}}", "Selecting a new template did not keep legacy renderers aligned")
            try snapshot.updateMetadataTemplate(id: first, content: "Edited first {{title}}")
            try expect(snapshot.settings.metadataTemplate == "Second {{title}}", "Editing an inactive template replaced the active one")
            let paper = Paper(title: "Fixture")
            try expect(TemplateRenderer.renderMetadata(paper: paper, snapshot: snapshot) == "Second Fixture", "Default renderer did not use the active template")
            try expect(TemplateRenderer.renderMetadata(paper: paper, snapshot: snapshot, templateID: first) == "Edited first Fixture", "Explicit template rendering ignored its ID")
            try snapshot.deleteMetadataTemplate(id: second)
            try expect(snapshot.selectedMetadataTemplate.id == first && snapshot.availableMetadataTemplates.count == 1, "Deleting the active template did not select a surviving default")
            try expectThrows { try snapshot.deleteMetadataTemplate(id: first) }
        }
        run("Template selection, IDs, names, contents, and source dates survive persistence") {
            let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
            var snapshot = store.snapshot
            let date = Date(timeIntervalSince1970: 1_700_000_000), sourceID = UUID()
            snapshot.metadataTemplates = [MetadataTemplate(id: sourceID, name: "源模板", content: "Source {{title}}", isDefault: true, dateCreated: date)]
            try snapshot.selectMetadataTemplate(id: sourceID)
            let active = try snapshot.addMetadataTemplate(name: "User template", content: "User {{title}}")
            snapshot.settings.languageIdentifier = "en"
            store.replaceSnapshot(snapshot)
            let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
            try expect(reloaded.snapshot.settings.activeMetadataTemplateID == active && reloaded.snapshot.selectedMetadataTemplate.content == "User {{title}}", "Active template selection did not persist")
            let source = reloaded.snapshot.metadataTemplate(withID: sourceID)
            try expect(source?.name == "源模板" && source?.dateCreated == date && source?.isDefault == true, "Source template fields were lost")
            try expect(reloaded.settings.languageIdentifier == "en", "Language preference did not persist")
        }
        run("Lattice schema-2 archives map every observed template and retain raw unknown fields") {
            let first = UUID(), second = UUID()
            let payload: [String: Any] = ["papers": [], "collections": [], "tags": [], "annotations": [], "templates": [
                ["id": first.uuidString, "name": "原始默认", "content": "First {{title}}", "isDefault": true, "dateCreated": "2020-01-02T03:04:05Z", "unknownTemplateField": "retain me"],
                ["id": second.uuidString, "name": "Second", "content": "Second {{title}}", "isDefault": false, "dateCreated": "2021-02-03T04:05:06Z"]
            ]]
            let manifest: [String: Any] = ["version": 1, "schemaVersion": 2, "appVersion": "3.0", "includesPDFs": false,
                                          "counts": ["papers": 0, "collections": 0, "tags": 0, "annotations": 0, "templates": 2, "pdfs": 0, "attachmentFiles": 0]]
            let directory = root.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: directory.appendingPathComponent("data.json"))
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
            let archive = root.appendingPathComponent("templates.lattice")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = directory
            process.arguments = ["-q", archive.path, "manifest.json", "data.json"]
            try process.run(); process.waitUntilExit()
            try expect(process.terminationStatus == 0, "Could not create synthetic archive fixture")
            let result = try LatticeArchiveService.readArchive(at: archive)
            try expect(result.snapshot.availableMetadataTemplates.map(\.id) == [first, second], "Only the default source template was recovered")
            try expect(result.snapshot.selectedMetadataTemplate.id == first && result.snapshot.metadataTemplate(withID: second)?.content == "Second {{title}}", "Source selection or non-default content was lost")
            try expect(result.libraryData == data, "Raw unknown source fields were not retained")
        }
        failed.forEach { print("FAIL: \($0)") }
        print("Localization/template tests: \(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { exit(1) }
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS: \(name)") }
        catch { failed.append("\(name): \(error)") }
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw LocalizationTestFailure(description: message) }
    }
    static func expectThrows(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw LocalizationTestFailure(description: "Expected a safe error")
    }
}
