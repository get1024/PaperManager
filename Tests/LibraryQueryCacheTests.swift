import Foundation

@main
@MainActor
struct LibraryQueryCacheTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static var failures: [String] = []

    static func main() async {
        if CommandLine.arguments.contains("--benchmark") { benchmark(); return }
        await run("Indexed search preserves canonical Unicode, grapheme and cross-field matching", testSearchEquivalence)
        await run("Indexed queries preserve every filter and sort direction", testFiltersAndSorting)
        await run("Cached paper edits immediately change search, ordering and filter results", testPaperEdits)
        await run("Cached collection paths and tags reflect rename, move and membership edits", testMembershipEdits)
        await run("Add, delete, load and same-ID restore invalidate queries and sidebar counts", testSnapshotReplacement)
        await run("Failed persistence preserves committed cached search and counts", testFailedMutation)
        await run("Recently added results expire with the clock without snapshot edits", testRecencyExpiry)
        failures.forEach { print("FAIL: \($0)") }
        print("Library query cache: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    static func run(_ name: String, _ test: () async throws -> Void) async {
        do { try await test(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func temporaryStore() throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papermanager-query-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, LibraryStore(persistenceURL: root.appendingPathComponent("library.json")))
    }

    static func results(_ store: LibraryStore, _ text: String = "", filter: LibraryFilter = .all,
                        children: Bool = true, sort: PaperSortDescriptor = .defaultValue) -> [UUID] {
        store.filteredPapers(for: filter, searchText: text, includeSubcollections: children, sortDescriptor: sort).map(\.id)
    }

    // Keep the original searchable-field construction and String.contains as
    // an independent reference for the indexed Unicode implementation.
    static func referenceText(_ paper: Paper, snapshot: LibrarySnapshot) -> String {
        let tagNames = Dictionary(snapshot.tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return [paper.title, paper.subtitle ?? "", paper.authorsDisplay,
                (paper.editors ?? []).joined(separator: " "), (paper.translators ?? []).joined(separator: " "),
                paper.sourceDisplay, paper.year.map(String.init) ?? "", paper.doi, paper.isbn, paper.eprint,
                paper.citekey, paper.abstract, paper.notes,
                paper.collectionIDs.map { snapshot.collections.path(for: $0) }.joined(separator: " "),
                paper.tagIDs.compactMap { tagNames[$0] }.joined(separator: " "),
                paper.customFields.map { "\($0.key) \($0.value)" }.joined(separator: " ")].joined(separator: " ").lowercased()
    }

    static func testSearchEquivalence() async throws {
        let parent = PaperCollection(name: "Research"), child = PaperCollection(name: "机器人", parentID: parent.id)
        let tag = PaperTag(name: "Café")
        let texts = ["Café", "Cafe\u{301}", "a\u{308}\u{301}", "\u{1FB2}", "👨‍👩‍👧", "👩‍🔬",
                     "🇺🇸", "漢字与机器人", "İSTANBUL Straße", "x\0world", "z\u{301} z", "가", "가", "👍🏽",
                     "Line\r\nBreak", "Ångström", "1️⃣", "❤️", "\u{1F88}"]
        var papers = texts.map { text -> Paper in
            var paper = Paper(title: text, authors: ["Alice Researcher"])
            paper.subtitle = "Subtitle"; paper.editors = ["Editor Person"]; paper.translators = ["Translator Person"]
            paper.journal = "Journal"; paper.year = 2026; paper.doi = "10.1000/fixture"
            paper.isbn = "1234567890"; paper.eprint = "2601.00001"; paper.citekey = "Key2026"
            paper.abstract = text; paper.notes = "Private note"; paper.collectionIDs = [child.id]; paper.tagIDs = [tag.id]
            paper.customFields = [CustomField(key: "Project", value: "Linz")]
            return paper
        }
        papers.append(Paper(title: "Boundary", subtitle: "Field", authors: ["Author"]))
        let snapshot = LibrarySnapshot(papers: papers, collections: [parent, child], tags: [tag])
        let index = LibraryQuery.Index(snapshot: snapshot)
        var queries = texts + ["é", "e\u{301}", "a", "\u{301}", "👩", "👩‍👧", "🇺", "👍", "ᄀ", "가", "漢字", "机器人",
                              " FIELD AUTHOR ", "boundary field", "Research/机器人", "translator person", "project linz",
                              "private note", "journal 2026", "\0world", "zzzz-no-match", "", "  ", "1", "❤", "\n"]
        // Query scalar slices as well as whole characters, so fragments inside
        // flags, joined emoji, CRLF and combining sequences are checked too.
        for text in texts {
            let scalars = Array(text.unicodeScalars)
            for start in scalars.indices {
                for end in (start + 1)...min(start + 3, scalars.count) {
                    let fragment = String(String.UnicodeScalarView(scalars[start..<end]))
                    queries.append(fragment)
                    queries.append(fragment.decomposedStringWithCanonicalMapping)
                }
            }
        }
        for query in queries {
            let normalized = query.trimmed.lowercased()
            let expected = Set(papers.filter { normalized.isEmpty || referenceText($0, snapshot: snapshot).contains(normalized) }.map(\.id))
            let indexed = Set(index.papers(filter: .all, searchText: query, includeSubcollections: true,
                                           sortDescriptor: .defaultValue).map(\.id))
            let pure = Set(LibraryQuery.papers(in: snapshot, filter: .all, searchText: query, includeSubcollections: true,
                                              sortDescriptor: .defaultValue).map(\.id))
            try expect(indexed == expected && pure == expected, "Unicode/cross-field search changed for \(query.debugDescription)")
        }
    }

    static func testFiltersAndSorting() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parent = PaperCollection(name: "Research"), child = PaperCollection(name: "Robotics", parentID: parent.id)
        let tag = PaperTag(name: "Shared")
        var papers = (0..<50).map { position -> Paper in
            var paper = Paper(title: position % 3 == 0 ? "Identical" : "Paper \(position)", authors: ["Author \(position % 5)"],
                              year: position % 6 == 0 ? nil : 2000 + position % 4)
            paper.journal = "Journal \(position % 4)"; paper.abstract = "Vision \(position % 2)"
            paper.dateAdded = now.addingTimeInterval(-Double(position * 86_400)); paper.rating = position % 6
            if position % 2 == 0 { paper.collectionIDs = [child.id]; paper.tagIDs = [tag.id]; paper.doi = "10.1/\(position)" }
            if position % 3 == 0 { paper.lastOpenedAt = now.addingTimeInterval(-Double(position)) }
            if position % 4 == 0 { paper.attachments = [Attachment(kind: .pdf, filePath: "/fixture/\(position).pdf", displayName: "PDF")] }
            return paper
        }
        // Exact comparator ties verify that filtering cached library order
        // preserves the same stable order as sorting only matched papers.
        var tie = papers[0]; tie.id = UUID(); papers.insert(tie, at: 1)
        let snapshot = LibrarySnapshot(papers: papers, collections: [parent, child], tags: [tag])
        let index = LibraryQuery.Index(snapshot: snapshot)
        let filters: [LibraryFilter] = [.all, .recentlyAdded, .recentlyOpened, .unfiled, .missingPDF, .missingIDs,
                                        .noTags, .rating(0), .rating(4), .collection(parent.id), .tag(tag.id)]
        for field in PaperSortField.allCases {
            for ascending in [true, false] {
                let sort = PaperSortDescriptor(field: field, ascending: ascending)
                for filter in filters {
                    for children in [true, false] {
                        for query in ["", "vision 1", "paper 19", "zzzz-no-match"] {
                            let expected = LibraryQuery.papers(in: snapshot, filter: filter, searchText: query,
                                                              includeSubcollections: children, sortDescriptor: sort, now: now)
                            let actual = index.papers(filter: filter, searchText: query, includeSubcollections: children,
                                                      sortDescriptor: sort, now: now)
                            try expect(actual == expected, "Cached filter/sort changed for \(field), \(filter), \(query)")
                        }
                    }
                }
            }
        }
    }

    static func testPaperEdits() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let alpha = Paper(title: "Alpha", authors: ["Original Author"], year: 2024)
        let beta = Paper(title: "Beta", year: 2026)
        try store.replaceSnapshotDurably(LibrarySnapshot(papers: [alpha, beta]))
        let byYear = PaperSortDescriptor(field: .year, ascending: true)
        try expect(results(store, "original author") == [alpha.id] && results(store, sort: byYear) == [alpha.id, beta.id], "Warm-up failed")
        var edited = store.paper(with: alpha.id)!
        edited.title = "Edited Alpha"; edited.authors = ["New Author"]; edited.year = 2030; edited.rating = 5
        edited.notes = "Fresh note"; edited.customFields = [CustomField(key: "Fresh", value: "metadata")]; edited.doi = "10.1/edited"
        try store.updatePaperDurably(edited)
        try expect(results(store, "original author").isEmpty && results(store, "new author") == [alpha.id], "Search document survived an edit")
        try expect(results(store, "fresh metadata") == [alpha.id] && results(store, "fresh note") == [alpha.id], "Edited notes/custom fields missing")
        try expect(results(store, sort: byYear) == [beta.id, alpha.id], "Cached sort survived a sort-field edit")
        try expect(results(store, filter: .rating(5)) == [alpha.id] && results(store, filter: .missingIDs) == [beta.id], "Edited filters are stale")
        try expect(store.filteredPapers(for: .all, searchText: "edited alpha", includeSubcollections: true).first?.year == 2030,
                   "Returned cached Paper value is stale")
        _ = results(store, filter: .recentlyOpened); store.markOpened(alpha.id)
        try expect(results(store, filter: .recentlyOpened) == [alpha.id], "Opening a paper did not invalidate recency")
    }

    static func testMembershipEdits() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try store.createCollection(name: "Old Parent"), child = try store.createCollection(name: "Old Child", parentID: parent)
        let other = try store.createCollection(name: "New Parent"), tag = try store.createTag(name: "Old Tag")
        var paper = Paper(title: "Membership"); paper.collectionIDs = [child]; paper.tagIDs = [tag]
        try store.addPaperDurably(paper)
        try expect(results(store, "old parent/old child") == [paper.id] && results(store, "old tag") == [paper.id], "Membership warm-up failed")
        store.renameCollection(id: child, name: "New Child"); store.renameTag(id: tag, name: "New Tag")
        try expect(results(store, "old child").isEmpty && results(store, "old tag").isEmpty && results(store, "new tag") == [paper.id], "Rename reused cached names")
        try expect(store.moveCollection(id: child, toParentID: other, at: 0), "Move failed")
        try expect(results(store, "new parent/new child") == [paper.id] && results(store, filter: .collection(parent)).isEmpty,
                   "Collection move reused old path/descendants")
        try expect(store.sidebarCounts(includeSubcollections: true).collections[other] == 1 &&
                   store.sidebarCounts(includeSubcollections: false).collections[other] == nil, "Moved sidebar counts are stale")
        store.deleteTag(id: tag); store.deleteCollection(id: other)
        try expect(results(store, "new tag").isEmpty && results(store, filter: .noTags) == [paper.id] &&
                   results(store, filter: .unfiled) == [paper.id], "Deleted memberships remained indexed")
    }

    static func testSnapshotReplacement() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let paper = Paper(title: "Original")
        try store.addPaperDurably(paper)
        _ = results(store, "original"); _ = store.sidebarCounts(includeSubcollections: true)
        let added = Paper(title: "Added"); try store.addPaperDurably(added)
        try expect(results(store, "added") == [added.id] && store.sidebarCounts(includeSubcollections: true).all == 2, "Add left stale caches")
        try expect(store.deletePapers(ids: [added.id]), "Delete failed")
        try expect(results(store, "added").isEmpty && store.sidebarCounts(includeSubcollections: false).all == 1, "Delete left stale caches")
        var restored = paper; restored.title = "Same ID Restored"; restored.doi = "10.1/restored"
        try store.replaceSnapshotDurably(LibrarySnapshot(papers: [restored]))
        try expect(results(store, "original").isEmpty && results(store, "same id restored") == [paper.id] &&
                   store.sidebarCounts(includeSubcollections: true).missingIDs == 0, "Same-ID restore reused old caches")
        var loaded = restored; loaded.title = "Disk Reloaded"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LibrarySnapshot(papers: [loaded])).write(to: store.persistenceURL)
        store.load()
        try expect(results(store, "same id restored").isEmpty && results(store, "disk reloaded") == [paper.id], "Reload reused an old search index")
    }

    static func testFailedMutation() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let paper = Paper(title: "Committed"); try store.addPaperDurably(paper)
        _ = results(store, "committed"); _ = store.sidebarCounts(includeSubcollections: true)
        let saved = root.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: store.persistenceURL, to: saved)
        try FileManager.default.createDirectory(at: store.persistenceURL, withIntermediateDirectories: true)
        var edited = paper; edited.title = "Uncommitted"
        try expect(!store.updatePaper(edited), "Blocked write unexpectedly succeeded")
        try expect(results(store, "committed") == [paper.id] && results(store, "uncommitted").isEmpty &&
                   store.sidebarCounts(includeSubcollections: true).all == 1, "Failed mutation changed committed query results")
    }

    static func testRecencyExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var paper = Paper(title: "Almost expired"); paper.dateAdded = now.addingTimeInterval(-30 * 86_400 + 1)
        let index = LibraryQuery.Index(snapshot: LibrarySnapshot(papers: [paper]))
        try expect(index.papers(filter: .recentlyAdded, searchText: "", includeSubcollections: true,
                                sortDescriptor: .defaultValue, now: now).count == 1, "Recent fixture was already expired")
        try expect(index.papers(filter: .recentlyAdded, searchText: "", includeSubcollections: true,
                                sortDescriptor: .defaultValue, now: now.addingTimeInterval(2)).isEmpty, "Cached recent results did not expire")
    }

    static func benchmark() {
        let paragraph = "World models let embodied agents reason about spatial scenes and future actions. This synthetic abstract covers perception, planning, vision and language. "
        let abstract = String(repeating: paragraph, count: 12)
        for count in [1_000, 10_000] {
            var snapshot = LibrarySnapshot.empty
            snapshot.papers = (0..<count).map { index in
                var paper = Paper(title: "Synthetic research paper \(index)", authors: ["Alice Researcher", "Bob Scientist"], year: 2000 + index % 27)
                paper.journal = "Synthetic Journal"; paper.abstract = abstract
                return paper
            }
            let sort = PaperSortDescriptor(field: .year, ascending: true)
            for query in ["", "world", "zzzz-no-match"] {
                let coldStart = ProcessInfo.processInfo.systemUptime
                let index = LibraryQuery.Index(snapshot: snapshot)
                let coldCount = index.papers(filter: .all, searchText: query, includeSubcollections: true, sortDescriptor: sort).count
                let cold = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
                var durations: [Double] = []
                for _ in 0..<5 {
                    // A different request before each measurement prevents the
                    // last-result cache from hiding actual index scan/sort cost.
                    _ = index.papers(filter: .rating(5), searchText: "alternate", includeSubcollections: true, sortDescriptor: sort)
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = index.papers(filter: .all, searchText: query, includeSubcollections: true, sortDescriptor: sort)
                    durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                let repeatedStart = ProcessInfo.processInfo.systemUptime
                _ = index.papers(filter: .all, searchText: query, includeSubcollections: true, sortDescriptor: sort)
                let repeated = (ProcessInfo.processInfo.systemUptime - repeatedStart) * 1000
                print("indexed papers=\(count) query=\(query.isEmpty ? "<empty>" : query) results=\(coldCount) cold_ms=\(String(format: "%.2f", cold)) warm_scan_median_ms=\(String(format: "%.2f", durations.sorted()[2])) repeated_ms=\(String(format: "%.4f", repeated)) abstract_chars=\(abstract.count)")
            }
            let index = LibraryQuery.Index(snapshot: snapshot)
            _ = index.papers(filter: .all, searchText: "", includeSubcollections: true, sortDescriptor: sort)
            for query in ["w", "wo", "wor", "worl", "world", "world ", "world m", "zzzz-no-match"] {
                let start = ProcessInfo.processInfo.systemUptime
                _ = index.papers(filter: .all, searchText: query, includeSubcollections: true, sortDescriptor: sort)
                print("typing papers=\(count) query=\(query.debugDescription) elapsed_ms=\(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - start) * 1000))")
            }
        }
    }
}
