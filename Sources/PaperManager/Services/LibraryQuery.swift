import Foundation

struct LibrarySidebarCounts {
    var all = 0
    var unfiled = 0
    var missingPDF = 0
    var missingIDs = 0
    var collections: [UUID: Int] = [:]
    var tags: [UUID: Int] = [:]
}

/// Pure snapshot queries keep list presentation independent of persistence and
/// background jobs. Per-query lookup tables cannot outlive an edited snapshot.
enum LibraryQuery {
    static func sidebarCounts(in snapshot: LibrarySnapshot, includeSubcollections: Bool) -> LibrarySidebarCounts {
        let collectionsByID = Dictionary(snapshot.collections.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        var counts = LibrarySidebarCounts()
        for paper in snapshot.papers {
            counts.all += 1
            if paper.collectionIDs.isEmpty { counts.unfiled += 1 }
            if !paper.hasPDF { counts.missingPDF += 1 }
            if !paper.hasIdentifier { counts.missingIDs += 1 }
            for id in Set(paper.tagIDs) { counts.tags[id, default: 0] += 1 }
            var memberships = Set(paper.collectionIDs)
            if includeSubcollections {
                for id in paper.collectionIDs {
                    var parent = collectionsByID[id]?.parentID
                    while let ancestor = parent, memberships.insert(ancestor).inserted {
                        parent = collectionsByID[ancestor]?.parentID
                    }
                }
            }
            // A paper assigned to siblings or to both parent and child counts
            // once in their shared ancestor, just as a collection filter does.
            for id in memberships { counts.collections[id, default: 0] += 1 }
        }
        return counts
    }

    static func papers(in snapshot: LibrarySnapshot, filter: LibraryFilter, searchText: String,
                       includeSubcollections: Bool, sortDescriptor: PaperSortDescriptor,
                       now: Date = Date()) -> [Paper] {
        let query = searchText.trimmed.lowercased()
        let collectionIDs: Set<UUID>
        if case .collection(let id) = filter {
            collectionIDs = includeSubcollections ? snapshot.collections.descendantIDs(of: id) : [id]
        } else { collectionIDs = [] }
        let tagNames = query.isEmpty ? [:] : Dictionary(snapshot.tags.map { ($0.id, $0.name) },
                                                       uniquingKeysWith: { first, _ in first })
        var collectionPaths: [UUID: String] = [:]
        let filtered = snapshot.papers.filter { paper in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .recentlyAdded: matchesFilter = now.timeIntervalSince(paper.dateAdded) <= 60 * 60 * 24 * 30
            case .recentlyOpened: matchesFilter = paper.lastOpenedAt != nil
            case .unfiled: matchesFilter = paper.collectionIDs.isEmpty
            case .missingPDF: matchesFilter = !paper.hasPDF
            case .missingIDs: matchesFilter = !paper.hasIdentifier
            case .noTags: matchesFilter = paper.tagIDs.isEmpty
            case .rating(let value): matchesFilter = paper.rating == value
            case .collection: matchesFilter = paper.collectionIDs.contains { collectionIDs.contains($0) }
            case .tag(let id): matchesFilter = paper.tagIDs.contains(id)
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            let collectionText = paper.collectionIDs.map { id in
                if let path = collectionPaths[id] { return path }
                let path = snapshot.collections.path(for: id)
                collectionPaths[id] = path
                return path
            }.joined(separator: " ")
            let tagText = paper.tagIDs.compactMap { tagNames[$0] }.joined(separator: " ")
            return [
                paper.title,
                paper.subtitle ?? "",
                paper.authorsDisplay,
                (paper.editors ?? []).joined(separator: " "),
                (paper.translators ?? []).joined(separator: " "),
                paper.sourceDisplay,
                paper.year.map(String.init) ?? "",
                paper.doi,
                paper.isbn,
                paper.eprint,
                paper.citekey,
                paper.abstract,
                paper.notes,
                collectionText,
                tagText,
                paper.customFields.map { "\($0.key) \($0.value)" }.joined(separator: " ")
            ].joined(separator: " ").lowercased().contains(query)
        }
        // Filter the stored order directly and perform only the requested sort.
        return sort(filtered, by: sortDescriptor)
    }

    private static func sort(_ papers: [Paper], by descriptor: PaperSortDescriptor) -> [Paper] {
        papers.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch descriptor.field {
            case .title: comparison = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            case .authors: comparison = lhs.authorsDisplay.localizedStandardCompare(rhs.authorsDisplay)
            case .year: comparison = compareOptional(lhs.year, rhs.year)
            case .source: comparison = lhs.sourceDisplay.localizedStandardCompare(rhs.sourceDisplay)
            case .rating: comparison = compareValues(lhs.rating, rhs.rating)
            case .dateAdded: comparison = compareValues(lhs.dateAdded, rhs.dateAdded)
            case .lastOpened: comparison = compareOptional(lhs.lastOpenedAt, rhs.lastOpenedAt)
            }
            if comparison == .orderedSame {
                let titleOrder = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
                // Preserve the previous newest-first order for identical labels,
                // without sorting the whole library before filtering it.
                return titleOrder == .orderedSame ? lhs.dateAdded > rhs.dateAdded : titleOrder == .orderedAscending
            }
            return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none): return .orderedSame
        case (.none, .some): return .orderedAscending
        case (.some, .none): return .orderedDescending
        case (.some(let lhs), .some(let rhs)): return compareValues(lhs, rhs)
        }
    }
}
