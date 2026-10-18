import AppIntents
import Darwin
import Foundation

@main
@MainActor
struct MetadataIntentRegression {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var failures: [String] = []
    private static var passed = 0

    static func main() async {
        await run("Paper entities query the current library by identity and text", testPaperQuery)
        await run("Template entities reflect the current editable metadata template", testTemplateQuery)
        await run("Template queries and explicit selection support multiple persisted templates", testMultipleTemplates)
        await run("Export output modes preserve annotations and isolate clipboard writes", testOutputModes)
        await run("The actual intent returns template-rendered text", testIntentPerform)
        await run("Missing entities and unreadable libraries fail without changing files", testInvalidInputs)
        for failure in failures { print("FAIL: \(failure)") }
        print("Metadata intent regression: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    private static func fixture(_ body: (URL, LibraryStore, Paper) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerIntents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("library.json")
        let previousPath = ProcessInfo.processInfo.environment["PAPERMANAGER_LIBRARY_PATH"]
        setenv("PAPERMANAGER_LIBRARY_PATH", path.path, 1)
        defer {
            if let previousPath { setenv("PAPERMANAGER_LIBRARY_PATH", previousPath, 1) }
            else { unsetenv("PAPERMANAGER_LIBRARY_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        let store = LibraryStore(persistenceURL: path)
        var paper = Paper()
        paper.title = "Intent fixture"
        paper.authors = ["Ada Lovelace"]
        paper.doi = "10.5555/intent"
        paper.annotations = [ResearchAnnotation(selectedText: "Important phrase")]
        store.addPaper(paper)
        var settings = store.settings
        settings.metadataTemplate = "{{title}}|{{annotations}}"
        settings.annotationTemplate = "{{selectedText}}"
        store.updateSettings(settings)
        try await body(root, store, paper)
    }

    private static func testPaperQuery() async throws {
        try await fixture { _, store, paper in
            let query = PaperEntityQuery()
            let matches = try await query.entities(matching: "Lovelace")
            try expect(matches.count == 1 && matches[0].id == paper.id.uuidString, "Author lookup did not resolve the paper")
            var updated = store.paper(with: paper.id)!
            updated.title = "Updated live title"
            store.updatePaper(updated)
            let resolved = try await query.entities(for: [UUID().uuidString, paper.id.uuidString, "invalid"])
            try expect(resolved.count == 1 && resolved[0].title == "Updated live title", "Entity resolution used stale metadata or accepted unknown IDs")
            let newMatches = try await query.entities(matching: "Updated live")
            try expect(newMatches.count == 1, "Text query did not reload current library data")
            let suggested = try await query.suggestedEntities()
            try expect(suggested.first?.id == paper.id.uuidString, "Suggested papers did not come from the current library")
        }
    }

    private static func testTemplateQuery() async throws {
        try await fixture { _, store, _ in
            let query = TemplateEntityQuery()
            let first = try await query.suggestedEntities()
            try expect(first.count == 1 && first[0].body == "{{title}}|{{annotations}}", "Current template is unavailable")
            var settings = store.settings; settings.metadataTemplate = "Changed {{title}}"
            store.updateSettings(settings)
            let refreshed = try await query.entities(for: [store.snapshot.selectedMetadataTemplate.id.uuidString, "missing"])
            try expect(refreshed.count == 1 && refreshed[0].body == "Changed {{title}}", "Template entity did not reload an edited template")
        }
    }

    private static func testOutputModes() async throws {
        try await fixture { _, store, paper in
            var copied: [String] = []
            let withoutAnnotations = try MetadataIntentLibrary.export(
                paperID: paper.id.uuidString, templateID: nil, includeAnnotations: false,
                output: .returnText, snapshot: store.snapshot, copyToClipboard: { copied.append($0) }
            )
            try expect(withoutAnnotations == "Intent fixture|" && copied.isEmpty, "Return Text changed the clipboard or included annotations")
            let withAnnotations = try MetadataIntentLibrary.export(
                paperID: paper.id.uuidString, templateID: store.snapshot.selectedMetadataTemplate.id.uuidString, includeAnnotations: true,
                output: .copyToClipboard, snapshot: store.snapshot, copyToClipboard: { copied.append($0) }
            )
            try expect(withAnnotations == "Intent fixture|Important phrase" && copied == [withAnnotations], "Clipboard mode did not copy the same rendered text exactly once")
        }
    }

    private static func testIntentPerform() async throws {
        try await fixture { _, store, paper in
            let intent = ExportPaperMetadataIntent()
            intent.paper = PaperEntity(paper: paper)
            intent.template = TemplateEntity(snapshot: store.snapshot)
            intent.includeAnnotations = true
            intent.output = .returnText
            let result = try await intent.perform()
            try expect(result.value == "Intent fixture|Important phrase", "Intent perform did not return the selected paper/template output")
        }
    }

    private static func testMultipleTemplates() async throws {
        try await fixture { _, store, paper in
            let first = MetadataTemplate(name: "First template", content: "First {{title}}", isDefault: true)
            let second = MetadataTemplate(name: "Second template", content: "Second {{title}}")
            var snapshot = store.snapshot
            snapshot.metadataTemplates = [first, second]
            snapshot.settings.activeMetadataTemplateID = second.id
            store.replaceSnapshot(snapshot)
            let query = TemplateEntityQuery()
            let suggestions = try await query.suggestedEntities()
            try expect(suggestions.map(\.id) == [first.id.uuidString, second.id.uuidString], "Persisted templates were collapsed into a single synthetic entity")
            let resolved = try await query.entities(for: [second.id.uuidString, first.id.uuidString])
            try expect(resolved.map(\.name) == ["Second template", "First template"], "Explicit template IDs were not resolved in input order")
            let matches = try await query.entities(matching: "Second")
            try expect(matches.first?.id == second.id.uuidString && matches.count == 1, "Template name query did not use persisted names")
            let active = try MetadataIntentLibrary.export(paperID: paper.id.uuidString, templateID: nil, includeAnnotations: false,
                                                         output: .returnText, snapshot: snapshot, copyToClipboard: { _ in })
            let explicit = try MetadataIntentLibrary.export(paperID: paper.id.uuidString, templateID: first.id.uuidString, includeAnnotations: false,
                                                           output: .returnText, snapshot: snapshot, copyToClipboard: { _ in })
            try expect(active == "Second Intent fixture" && explicit == "First Intent fixture", "Export ignored active or explicit template selection")
            snapshot.metadataTemplates?.removeAll { $0.id == first.id }
            var rejected = false
            do { _ = try MetadataIntentLibrary.export(paperID: paper.id.uuidString, templateID: first.id.uuidString, includeAnnotations: false,
                                                      output: .returnText, snapshot: snapshot, copyToClipboard: { _ in }) }
            catch { rejected = true }
            try expect(rejected, "A deleted explicitly selected template silently fell back to another template")
        }
    }

    private static func testInvalidInputs() async throws {
        try await fixture { _, store, paper in
            var rejected = 0
            for (id, template) in [(UUID().uuidString, nil), (paper.id.uuidString, "missing-template")] as [(String, String?)] {
                do {
                    _ = try MetadataIntentLibrary.export(
                        paperID: id, templateID: template, includeAnnotations: false,
                        output: .returnText, snapshot: store.snapshot,
                        copyToClipboard: { _ in }
                    )
                } catch { rejected += 1 }
            }
            try expect(rejected == 2, "Missing paper or stale template was silently accepted")
            let original = Data("unreadable library fixture".utf8)
            try original.write(to: store.persistenceURL)
            do {
                _ = try await PaperEntityQuery().suggestedEntities()
                throw Failure(description: "An unreadable library produced successful query results")
            } catch is Failure { throw Failure(description: "An unreadable library produced successful query results") }
            catch { }
            try expect(try Data(contentsOf: store.persistenceURL) == original, "An intent query overwrote the unreadable library")
        }
    }
}
