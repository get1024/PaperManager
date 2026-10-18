import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct ReconstructionTests {
    private static var failures: [String] = []
    private static var passed = 0

    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--fixture-cli" {
            do { try runCLIFixture(Array(CommandLine.arguments.dropFirst(2))) }
            catch {
                FileHandle.standardError.write(Data("Fixture failure: \(error)\n".utf8))
                exit(2)
            }
            return
        }

        await run("BibTeX import/export preserves metadata and nested text") { try testBibTeXRoundTrip() }
        await run("RIS imports standard records and survives export/import") { try testRISRoundTrip() }
        await run("Citation export switches preserve basics and load legacy settings") { try testCitationExportPolicy() }
        await run("Canonical citekeys track metadata and templates with stable suffixes") { try testCanonicalCitekeys() }
        await run("Deduplication and collection descendant filters") { try testLibraryFiltering() }
        await run("JSON persistence and deleting read-only references") { try testPersistenceAndReferences() }
        await run("Reattaching external PDFs preserves source authority") { try testReferenceReattachment() }
        await run("Inspector draft merges preserve concurrent native operations") { try testConcurrentDraft() }
        await run("Unreadable library cannot be overwritten by ordinary save") { try testUnreadableLibrary() }
        await run("Async file import reports additions and duplicates") { try await testAsyncImport() }
        await run("Lattice metadata snapshot DTO and cap warning") { try await testLatticeSnapshot() }
        await run("Lattice CLI discovers past the 50-result cap using read commands") { try await testCLICap() }

        for failure in failures { print("FAIL: \(failure)") }
        print("Reconstruction tests: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS: \(name)")
        } catch {
            failures.append("\(name): \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(description: message) }
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let bibFixture = #"""
    @book{lovelace2026,
      title = {A {Nested} Research Guide},
      subtitle = {Methods, Models and Evidence},
      author = {Lovelace, Ada and Turing, Alan},
      editor = {Hopper, Grace and Knuth, Donald},
      translator = {Li, Ming},
      year = {2026},
      publisher = {Research Press},
      address = {Shanghai},
      edition = {2},
      language = {en},
      type = {Technical guide},
      howpublished = {Digital edition},
      organization = {Research Lab},
      urldate = {2026-10-13},
      url = {https://example.invalid/research},
      doi = {10.5555/offline-test},
      pubstate = {published},
      eventtitle = {Vision Workshop},
      eventdate = {2026-10-13},
      venue = {Linz},
      abstract = {A comma, a {nested} term and quoted "text".},
      note = {Read the guide},
      custom = {kept value}
    }
    """#

    private static func testBibTeXRoundTrip() throws {
        let imported = BibTeXParser.parse(bibFixture)
        try expect(imported.count == 1, "Expected one standard BibTeX record, got \(imported.count)")
        let paper = imported[0]
        try expect(paper.title == "A {Nested} Research Guide", "Nested title changed")
        try expect(paper.authors == ["Lovelace, Ada", "Turing, Alan"], "Author list did not parse")
        try expect(paper.editors == ["Hopper, Grace", "Knuth, Donald"], "Editors lost on BibTeX import")
        try expect(paper.translators == ["Li, Ming"], "Translator lost on BibTeX import")
        try expect(paper.subtitle == "Methods, Models and Evidence", "Subtitle lost on import")
        try expect(paper.address == "Shanghai" && paper.urlDate == "2026-10-13", "Publication/access metadata lost")
        try expect(paper.organization == "Research Lab" && paper.institution.isEmpty, "Organization incorrectly moved to institution")
        try expect(paper.customFields.map(\.key) == ["custom"], "Standard fields incorrectly treated as custom fields")
        let exported = ExportService.bibTeX(for: imported)
        let roundTrip = BibTeXParser.parse(exported)
        try expect(roundTrip.count == 1, "Exported BibTeX no longer parses")
        let restored = roundTrip[0]
        try expect(restored.citekey == paper.citekey && restored.paperType == .book, "Bibliographic identity/type changed")
        try expect(restored.title == paper.title && restored.abstract == paper.abstract, "Text changed after round trip")
        try expect(restored.editors == paper.editors && restored.translators == paper.translators, "Name roles changed after round trip")
        try expect(restored.subtitle == paper.subtitle && restored.organization == paper.organization, "Extended fields lost after round trip")
        try expect(restored.publicationState == "published" && restored.event == "Vision Workshop" && restored.venue == "Linz", "Publication/event metadata lost")
        try expect(restored.customFields.first?.value == "kept value", "Unknown BibTeX field lost")

        let punctuation = BibTeXParser.parse(#"@article{punctuation, title={Quoted "word", literal \{brace\} and (group)}, author={Ada}, year={2026}}"#)
        try expect(punctuation.count == 1 && punctuation[0].title == #"Quoted "word", literal {brace} and (group)"#, "Escaped braces or quoted braced text corrupted entry boundaries")
    }

    private static func testRISRoundTrip() throws {
        let source = """
        TY  - CPAPER
        ID  - vision2026
        T1  - An Offline Vision Study
        ST  - Calibrated Evidence
        AU  - Ada Lovelace
        AU  - Alan Turing
        ED  - Grace Hopper
        PY  - 2026/10/13
        T2  - Proceedings of Vision
        PB  - Research Press
        CY  - Linz
        ET  - 2
        SP  - 10
        EP  - 20
        DO  - 10.5555/vision-fixture
        Y2  - 2026-10-13
        LA  - en
        AB  - First line
              continued abstract text
        ER  -

        TY  - PREPRINT
        T1  - A second record
        AU  - Research Group
        ER  -
        """
        let records = RISParser.parse(source)
        try expect(records.count == 2, "Expected two standard RIS records, got \(records.count)")
        let paper = records[0]
        try expect(paper.citekey == "vision2026" && paper.paperType == .inProceedings, "RIS identity/type lost")
        try expect(paper.authors == ["Ada Lovelace", "Alan Turing"] && paper.editors == ["Grace Hopper"], "RIS name roles lost")
        try expect(paper.bookTitle == "Proceedings of Vision" && paper.journal.isEmpty, "Conference container parsed as journal")
        try expect(paper.abstract == "First line continued abstract text", "RIS continuation line lost")
        try expect(records[1].paperType == .preprint, "PREPRINT round trip cannot preserve type")
        let restored = RISParser.parse(ExportService.ris(for: records))
        try expect(restored.count == 2, "Exported RIS lost record boundaries")
        try expect(restored[0].title == paper.title && restored[0].subtitle == paper.subtitle, "RIS title/subtitle changed")
        try expect(restored[0].bookTitle == paper.bookTitle && restored[0].pages == "10--20", "RIS container/page range changed")
        try expect(restored[0].editors == paper.editors && restored[0].address == "Linz" && restored[0].edition == "2", "RIS editor/publishing metadata lost")
        try expect(restored[0].urlDate == "2026-10-13" && restored[0].language == "en", "RIS access/language metadata lost")
        try expect(restored[1].paperType == .preprint, "RIS preprint type changed")
    }

    private static func testLibraryFiltering() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let parent = store.addCollection(name: "Panorama")
        let child = store.addCollection(name: "ERP", parentID: parent)
        let unrelated = store.addCollection(name: "Robotics")
        var first = Paper(title: "A projection study", authors: ["Ada"], year: 2026, doi: "10.5555/ERP")
        first.citekey = "authorSuppliedKey"
        let firstID = store.addPaper(first, targetFilter: .collection(child))
        var duplicate = Paper(title: "Changed title", authors: ["Different"], year: 2025, doi: " 10.5555/erp ")
        duplicate.notes = "Incoming metadata should not replace existing edits"
        try expect(store.addOrReplacePaper(duplicate) == firstID && store.papers.count == 1, "DOI normalization failed to deduplicate")
        try expect(store.paper(with: firstID)?.title == first.title, "Duplicate import overwrote existing metadata")
        try expect(store.paper(with: firstID)?.citekey == "ada2026", "Ordinary import did not generate the canonical citekey")
        _ = store.addPaper(Paper(title: "A parent paper", year: 2024), targetFilter: .collection(parent))
        _ = store.addPaper(Paper(title: "An unrelated paper", year: 2023), targetFilter: .collection(unrelated))
        let direct = store.filteredPapers(for: .collection(parent), searchText: "", includeSubcollections: false)
        let descendants = store.filteredPapers(for: .collection(parent), searchText: "", includeSubcollections: true)
        try expect(direct.count == 1 && descendants.count == 2, "Include subcollections does not affect membership correctly")
        try expect(store.filteredPapers(for: .collection(parent), searchText: "ERP", includeSubcollections: true).map(\.id) == [firstID], "Search does not include collection paths")
        store.deleteCollection(id: parent)
        try expect(store.collections.count == 1 && store.papers.count == 3, "Collection deletion removed papers or retained descendants")
        try expect(store.paper(with: firstID)?.collectionIDs.isEmpty == true, "Deleted collection relationship remains")
    }

    private static func testCitationExportPolicy() throws {
        var paper = Paper(title: "Projection evidence", authors: ["Lovelace, Ada"], year: 2026, doi: "10.5555/export-policy")
        paper.citekey = "lovelace2026"
        paper.journal = "Vision Journal"
        paper.volume = "3"
        paper.issue = "2"
        paper.pages = "10--20"
        paper.publisher = "Research Press"
        paper.abstract = "A retained abstract"
        paper.notes = "Reader note"
        paper.customFields = [CustomField(key: "method", value: "Calibrated projection")]
        let panorama = PaperTag(name: "Panorama")
        let erp = PaperTag(name: "ERP")
        paper.tagIDs = [panorama.id, erp.id, panorama.id, UUID()]
        let tags = [erp, panorama]
        let defaultBib = ExportService.bibTeX(for: [paper], tags: tags)
        let defaultRIS = ExportService.ris(for: [paper], tags: tags)
        try expect(defaultBib.contains("keywords = {Panorama, ERP}") && defaultBib.contains("method = {Calibrated projection}"), "Default BibTeX lost keywords/custom fields")
        try expect(defaultRIS.contains("KW  - Panorama") && defaultRIS.contains("KW  - ERP") && defaultRIS.components(separatedBy: "KW  - Panorama").count == 2, "RIS tag keywords were omitted or duplicated")
        let restoredCustom = RISParser.parse(defaultRIS).first?.customFields
        try expect(restoredCustom?.first?.key == "method" && restoredCustom?.first?.value == "Calibrated projection", "RIS custom-slot metadata did not round trip")

        let optionalBibKeys: [CitationExportField: String] = [.abstract: "abstract", .keywords: "keywords", .notes: "note", .customFields: "method"]
        let optionalRISTags: [CitationExportField: String] = [.abstract: "AB", .keywords: "KW", .notes: "N1", .customFields: "C1"]
        for disabledField in CitationExportField.allCases {
            var settings = AppSettings.defaults
            settings.setCitationExport(disabledField, included: false)
            let bib = ExportService.bibTeX(for: [paper], settings: settings, tags: tags)
            let ris = ExportService.ris(for: [paper], settings: settings, tags: tags)
            try expect(!bib.contains("\(optionalBibKeys[disabledField]!) = {") && !ris.contains("\(optionalRISTags[disabledField]!)  -"), "Disabled \(disabledField) still exported")
            for includedField in CitationExportField.allCases where includedField != disabledField {
                try expect(bib.contains("\(optionalBibKeys[includedField]!) = {") && ris.contains("\(optionalRISTags[includedField]!)  -"), "Switch \(disabledField) also removed \(includedField)")
            }
            for restored in [BibTeXParser.parse(bib).first, RISParser.parse(ris).first] {
                try expect(restored?.title == paper.title && restored?.authors == paper.authors && restored?.year == 2026 && restored?.doi == paper.doi, "An optional switch removed required bibliographic fields")
                try expect(restored?.volume == "3" && restored?.issue == "2" && restored?.pages == "10--20" && restored?.publisher == paper.publisher, "An optional switch removed other populated fields")
            }
        }

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as! [String: Any]
        legacy.removeValue(forKey: "disabledCitationExportFields")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(CitationExportField.allCases.allSatisfy { decoded.includesCitationExport($0) }, "Legacy settings did not default all export groups on")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var settings = decoded
        for field in CitationExportField.allCases { settings.setCitationExport(field, included: false) }
        store.updateSettings(settings)
        let reopened = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reopened.loadError == nil && CitationExportField.allCases.allSatisfy { !reopened.settings.includesCitationExport($0) }, "Export switches were lost on relaunch")
    }

    private static func testCanonicalCitekeys() throws {
        let unicodeOnly = Paper(title: "球面视觉研究", authors: ["张三"])
        try expect(!CitekeyGenerator.generate(for: unicodeOnly, format: "{auth}{year}", existing: []).isEmpty, "Non-Latin metadata without a year produced an empty canonical key")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var first = Paper(title: "A projection study", authors: ["Lovelace, Ada"], year: 2026)
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        first.citekey = "sourceShouldNotOverrideTemplate"
        first.dateAdded = Date(timeIntervalSince1970: 100)
        var second = Paper(title: "Another projection study", authors: ["Lovelace, Ada"], year: 2026)
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.dateAdded = first.dateAdded
        let firstID = store.addPaper(first)
        let secondID = store.addPaper(second)
        try expect(store.paper(with: firstID)?.citekey == "lovelace2026" && store.paper(with: secondID)?.citekey == "lovelace2026a", "Imported keys or duplicate suffixes ignored the current template")
        store.regenerateCitekeys()
        try expect(store.paper(with: secondID)?.citekey == "lovelace2026" && store.paper(with: firstID)?.citekey == "lovelace2026a", "Stable ID tie-breaking did not determine duplicate suffixes")
        store.regenerateCitekeys()
        try expect(store.paper(with: secondID)?.citekey == "lovelace2026" && store.paper(with: firstID)?.citekey == "lovelace2026a", "Repeated regeneration changed stable duplicate suffixes")
        var edited = store.paper(with: firstID)!
        edited.notes = "A saved reader note"
        edited.rating = 5
        store.updatePaper(edited)
        try expect(store.paper(with: firstID)?.citekey == "lovelace2026a", "Notes/rating unnecessarily changed the canonical key")
        edited = store.paper(with: firstID)!
        edited.authors = ["Turing, Alan"]
        store.updatePaper(edited)
        try expect(store.paper(with: firstID)?.citekey == "turing2026", "Author changes did not update the canonical key")
        edited = store.paper(with: firstID)!
        edited.year = 2027
        store.updatePaper(edited)
        try expect(store.paper(with: firstID)?.citekey == "turing2027", "Year changes did not update the canonical key")
        store.updateSetting(\.citekeyFormat, value: "{auth}{year}-{titleWord}")
        try expect(store.paper(with: firstID)?.citekey == "turing2027-projection", "Single-brace template changes did not update existing keys")
        edited = store.paper(with: firstID)!
        edited.title = "Spherical evidence"
        store.updatePaper(edited)
        try expect(store.paper(with: firstID)?.citekey == "turing2027-spherical", "Title-dependent template did not respond to title edits")
        var settings = store.settings
        settings.citekeyFormat = "{{authorLower}}{{year2}}{{titleWord}}"
        store.updateSettings(settings)
        try expect(store.paper(with: firstID)?.citekey == "turing27spherical", "Legacy double-brace templates or bulk settings updates failed")
        let reopened = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reopened.paper(with: firstID)?.citekey == "turing27spherical" && reopened.paper(with: firstID)?.notes == "A saved reader note", "Canonical key/settings edits were lost on relaunch")
    }

    private static func testPersistenceAndReferences() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePDF = root.appendingPathComponent("source.pdf")
        let originalBytes = Data("read-only external file fixture".utf8)
        try originalBytes.write(to: sourcePDF)
        let libraryURL = root.appendingPathComponent("library.json")
        let store = LibraryStore(persistenceURL: libraryURL)
        store.updateSetting(\.deleteAttachmentsToTrash, value: true)
        var paper = Paper(title: "Persistence fixture", authors: ["Ada"], year: 2026)
        paper.rating = 4
        paper.notes = "A local note"
        paper.customFields = [CustomField(key: "source", value: "offline")]
        paper.attachments = [Attachment(kind: .pdf, filePath: sourcePDF.path, displayName: "source.pdf", isReadOnlyReference: true)]
        paper.annotations = [ResearchAnnotation(page: 3, pageLabel: "iii", kind: .note, selectedText: "Annotation", note: "Inspection")]
        let id = store.addPaper(paper)
        let reopened = LibraryStore(persistenceURL: libraryURL)
        try expect(reopened.loadError == nil && reopened.papers.count == 1, "Saved JSON could not be reopened")
        try expect(reopened.paper(with: id)?.notes == "A local note" && reopened.paper(with: id)?.rating == 4, "Local edits lost during persistence")
        try expect(reopened.paper(with: id)?.annotations.first?.page == 3, "Annotation persistence failed")
        try expect(reopened.paper(with: id)?.attachments.first?.isReadOnlyReference == true, "Read-only reference authority was lost on reload")
        reopened.deletePapers(ids: [id])
        try expect(reopened.papers.isEmpty, "Paper deletion failed")
        try expect(try Data(contentsOf: sourcePDF) == originalBytes, "Deleting an imported read-only reference changed or trashed source PDF")
        let legacy = try JSONDecoder().decode(Attachment.self, from: Data(#"{"kind":"pdf","filePath":"/tmp/legacy.pdf","displayName":"legacy.pdf"}"#.utf8))
        try expect(!legacy.isReadOnlyReference, "Older attachment JSON no longer decodes with the original default")
    }

    private static func testUnreadableLibrary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let damaged = Data("{not valid JSON\n".utf8)
        try damaged.write(to: url)
        let store = LibraryStore(persistenceURL: url)
        try expect(store.loadError != nil, "Malformed library was silently treated as successful")
        store.addPaper(Paper(title: "Must not overwrite damaged source"))
        store.save()
        try expect(try Data(contentsOf: url) == damaged, "Ordinary save overwrote unreadable source library")
        store.replaceSnapshot(.empty)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-unreadable-") }
        try expect(backups.count == 1 && (try Data(contentsOf: backups[0])) == damaged, "Restore did not preserve unreadable original bytes")
        try expect(LibraryStore(persistenceURL: url).loadError == nil, "Explicit restore did not repair destination JSON")
    }

    private static func testReferenceReattachment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("lattice-original.pdf")
        let bytes = Data("PDF fixture: no parsing required".utf8)
        try bytes.write(to: original)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var imported = Paper(title: "Source reference")
        imported.attachments = [Attachment(kind: .pdf, filePath: original.path, displayName: original.lastPathComponent, isReadOnlyReference: true)]
        let importedID = store.addPaper(imported)
        try store.attachFile(original, to: importedID)
        try expect(store.paper(with: importedID)?.primaryPDF?.isReadOnlyReference == true, "Reattaching same PDF dropped its read-only flag")
        let destinationID = store.addPaper(Paper(title: "Another local paper"))
        store.updateSetting(\.pdfOrganizationMode, value: .move)
        store.updateSetting(\.pdfOrganizationFolder, value: root.appendingPathComponent("managed").path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("managed"), withIntermediateDirectories: true)
        store.updateSetting(\.confirmBeforeMovingFiles, value: false)
        do {
            try store.attachFile(original, to: destinationID)
            throw TestFailure(description: "A reference protected elsewhere in the library was moved")
        } catch is TestFailure { throw TestFailure(description: "A reference protected elsewhere in the library was moved") }
        catch { try expect(try Data(contentsOf: original) == bytes, "Rejected move altered original PDF") }
        store.updateSetting(\.pdfOrganizationMode, value: .copy)
        try store.attachFile(original, to: destinationID)
        guard let copied = store.paper(with: destinationID)?.primaryPDF else {
            throw TestFailure(description: "Copy mode did not attach a local copy")
        }
        try expect(!copied.isReadOnlyReference && copied.filePath != original.path, "Independent copy inherited external reference authority")
        try expect(try Data(contentsOf: copied.url) == bytes, "Managed copy content changed")
        try expect(try Data(contentsOf: original) == bytes, "Copy mode altered original PDF")
    }

    private static func testConcurrentDraft() throws {
        var baseline = Paper(title: "Concurrent edit fixture", notes: "Old note")
        let retained = Attachment(filePath: "/tmp/retained-fixture.pdf", displayName: "retained")
        let removed = Attachment(filePath: "/tmp/removed-fixture.pdf", displayName: "removed")
        baseline.attachments = [retained, removed]
        var draft = baseline
        draft.notes = "A note typed in the inspector"
        draft.subtitle = "Edited subtitle"
        var latest = baseline
        latest.rating = 5
        latest.attachments = [retained]
        let collectionID = UUID()
        latest.collectionIDs = [collectionID]
        let merged = draft.applyingEdits(to: latest, from: baseline)
        try expect(merged.notes == draft.notes && merged.subtitle == draft.subtitle, "Draft text was dropped")
        try expect(merged.rating == 5 && merged.collectionIDs == [collectionID], "Pending draft overwrote native rating/collection changes")
        try expect(merged.attachments == [retained], "Saving a pending draft resurrected a removed attachment")
        var anotherPaper = latest
        anotherPaper.id = UUID()
        try expect(draft.applyingEdits(to: anotherPaper, from: baseline) == anotherPaper, "A stale draft modified another paper")
    }

    private static func testAsyncImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try #"@article{ada2026, title={Import fixture one}, author={Ada}, year={2026}, doi={10.5555/import-one}}"#.write(to: files.appendingPathComponent("one.bib"), atomically: true, encoding: .utf8)
        try "TY  - JOUR\nT1  - Import fixture two\nAU  - Alan\nPY  - 2025\nDO  - 10.5555/import-two\nER  -\n".write(to: files.appendingPathComponent("two.ris"), atomically: true, encoding: .utf8)
        let ignored = root.appendingPathComponent("ignore.txt")
        try "not a bibliography".write(to: ignored, atomically: true, encoding: .utf8)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        store.updateSetting(\.autoExtractMetadataAfterImport, value: false)
        let tagID = store.addTag(name: "Offline import")
        let initial = await ImportService.importURLs([files, ignored], into: store, targetFilter: .tag(tagID))
        try expect(initial.imported == 2 && initial.skipped == 1 && initial.failed == 0, "Initial import counts do not match actual additions")
        try expect(store.papers.count == 2 && store.papers.allSatisfy { $0.tagIDs == [tagID] }, "Async import did not attach target tag")
        let repeated = await ImportService.importURLs([files], into: store, targetFilter: nil)
        try expect(repeated.imported == 0 && repeated.skipped == 2 && repeated.failed == 0, "Duplicate import reports additions despite adding zero papers")
        try expect(store.papers.count == 2, "Repeated file import created duplicates")
    }

    private static func testLatticeSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try Data("external reference fixture".utf8).write(to: source)
        let payload = fixtureLibrary(paperCount: 1, pdfPath: source.path, capped: true)
        let payloadURL = root.appendingPathComponent("metadata.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: payloadURL)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        let summary = try await LatticeImportService.importMetadataSnapshot(at: payloadURL, into: store)
        try expect(summary.imported == 1 && summary.pdfReferences == 1, "DTO snapshot import failed")
        try expect(summary.warnings.contains { $0.contains("50") }, "Capped snapshot was incorrectly claimed complete")
        let paper = store.papers[0]
        try expect(paper.citekey == "fixture1", "Lattice migration did not retain the source canonical key")
        try expect(paper.publisher == "Fixture Press" && paper.doi == "10.5555/lattice-1" && paper.pages == "1-9", "CSL fallback fields lost")
        try expect(paper.editors == ["Grace Hopper"] && paper.url == "https://example.invalid/fixture", "CSL name/URL mapping failed")
        try expect(paper.collectionIDs.count == 1 && paper.tagIDs.count == 1, "Lattice collection/tag relationships lost")
        try expect(store.collections.first { $0.name == "ERP" }?.parentID == store.collections.first { $0.name == "Vision" }?.id, "Lattice nested collection parent lost")
        try expect(paper.primaryPDF?.isReadOnlyReference == true && paper.primaryPDF?.filePath == source.path, "Lattice PDF was not imported as a read-only reference")
        let repeated = try await LatticeImportService.importMetadataSnapshot(at: payloadURL, into: store)
        try expect(repeated.imported == 0 && repeated.skipped == 1 && store.papers.count == 1, "Repeated metadata snapshot created duplicate")

        let duplicatePayload = fixtureLibrary(paperCount: 1, pdfPath: source.path, capped: false)
        var malformed = duplicatePayload
        let duplicates = malformed["papers"] as! [[String: Any]]
        malformed["papers"] = duplicates + duplicates
        try JSONSerialization.data(withJSONObject: malformed).write(to: payloadURL)
        do {
            _ = try await LatticeImportService.importMetadataSnapshot(at: payloadURL, into: store)
            throw TestFailure(description: "Duplicate source IDs were accepted")
        } catch is TestFailure { throw TestFailure(description: "Duplicate source IDs were accepted") }
        catch { try expect(store.papers.count == 1, "Rejected DTO modified the destination library") }
    }

    private static func testCLICap() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("source.pdf")
        try Data("readonly fixture".utf8).write(to: pdf)
        let library = fixtureLibrary(paperCount: 51, pdfPath: pdf.path, capped: true)
        try JSONSerialization.data(withJSONObject: library).write(to: root.appendingPathComponent("cli-library.json"))
        let wrapper = root.appendingPathComponent("LatticeCLIFixture")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let shellQuote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nexport PAPERMANAGER_TEST_FIXTURE_ROOT=\(shellQuote(root.path))\nexec \(shellQuote(executable)) --fixture-cli \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("destination.json"))
        let summary = try await LatticeImportService.importFromRunningLattice(into: store, expectedPaperCount: 51, cliExecutablePath: wrapper.path)
        try expect(summary.discovered == 51 && summary.imported == 51 && store.papers.count == 51, "50-result cap prevented discovery of the 51st paper")
        try expect(store.papers.allSatisfy { $0.primaryPDF?.isReadOnlyReference == true }, "CLI import lost read-only PDF authority")
        let invocations = try String(contentsOf: root.appendingPathComponent("cli-invocations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
        try expect(invocations.contains { $0.first == "search" && $0.contains("--query") }, "Capped search did not broaden discovery")
        try expect(!invocations.contains { $0.contains("--offset") || $0.contains("--page") }, "Importer assumes unsupported pagination")
        try expect(invocations.filter { $0.first == "get-paper" }.count == 51, "Not every discovered paper was read exactly once")
        try expect(invocations.allSatisfy { ["status", "collections", "tags", "search", "get-paper"].contains($0.first ?? "") }, "Importer called a write command")
    }

    private static func fixtureID(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
    }

    private static func fixtureLibrary(paperCount: Int, pdfPath: String, capped: Bool) -> [String: Any] {
        let parent: [String: Any] = ["id": fixtureID(1000), "name": "Vision", "path": "Vision", "depth": 0]
        let child: [String: Any] = ["id": fixtureID(1001), "name": "ERP", "path": "Vision/ERP", "depth": 1]
        let tag: [String: Any] = ["id": fixtureID(2000), "name": "Fixture", "colorHex": "#AABBCC"]
        let papers: [[String: Any]] = (1...paperCount).map { index in
            ["id": fixtureID(index), "title": "Fixture paper \(index)", "authors": ["Ada Lovelace"], "year": 2026,
             "paperType": "article", "citekey": "fixture\(index)", "pdfPath": pdfPath,
             "collections": [child], "tags": [tag], "abstract": "Offline metadata",
             "cslItem": ["container-title": "Fixture Journal", "DOI": "10.5555/lattice-\(index)", "page": "1-9",
                         "publisher": "Fixture Press", "publisher-place": "Shanghai", "URL": "https://example.invalid/fixture",
                         "language": "en", "editor": [["given": "Grace", "family": "Hopper"]]]]
        }
        return ["papers": papers, "collections": [parent, child], "tags": [tag], "discoveryWasCapped": capped]
    }

    private static func runCLIFixture(_ arguments: [String]) throws {
        guard ProcessInfo.processInfo.environment["LATTICE_CLI_READONLY"] == "1",
              let path = ProcessInfo.processInfo.environment["PAPERMANAGER_TEST_FIXTURE_ROOT"],
              let command = arguments.first else {
            throw TestFailure(description: "CLI did not enforce its read-only environment")
        }
        let root = URL(fileURLWithPath: path)
        let log = root.appendingPathComponent("cli-invocations.jsonl")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: arguments) + Data([10]))
        try handle.close()
        let library = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cli-library.json"))) as! [String: Any]
        let papers = library["papers"] as! [[String: Any]]
        let result: Any
        switch command {
        case "status": result = ["ok": true, "capabilities": ["search", "paper-detail"]] as [String: Any]
        case "collections": result = library["collections"]!
        case "tags": result = library["tags"]!
        case "search":
            let queryIndex = arguments.firstIndex(of: "--query")
            let query = queryIndex.map { arguments[$0 + 1] }
            let selected = query == nil ? Array(papers.prefix(50)) : (query == "a" ? Array(papers.suffix(1)) : [])
            result = ["papers": selected.map { ["id": $0["id"]!, "title": $0["title"]!, "authorsDisplay": "Ada Lovelace"] }]
        case "get-paper":
            guard let idIndex = arguments.firstIndex(of: "--id"),
                  let paper = papers.first(where: { ($0["id"] as? String)?.lowercased() == arguments[idIndex + 1].lowercased() }) else {
                throw TestFailure(description: "Unknown fixture paper ID")
            }
            result = paper
        default: throw TestFailure(description: "Write or unsupported command: \(command)")
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result) + Data([10]))
    }
}
