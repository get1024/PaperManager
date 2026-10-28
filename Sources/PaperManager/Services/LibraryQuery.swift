import Foundation
import Darwin

struct LibrarySidebarCounts {
    var all = 0
    var unfiled = 0
    var missingPDF = 0
    var missingIDs = 0
    var collections: [UUID: Int] = [:]
    var tags: [UUID: Int] = [:]
}

/// Pure snapshot queries keep list presentation independent of persistence and
/// background jobs. The reusable index belongs to one immutable snapshot.
enum LibraryQuery {
    /// Reuse this index while a snapshot is unchanged. The store discards it on
    /// every snapshot publication, including edits made by background jobs.
    final class Index {
        private let snapshot: LibrarySnapshot
        private let tagNames: [UUID: String]
        private var collectionPaths: [UUID: String] = [:]
        private var documents: [SearchDocument?]
        private var sortedOffsets: [PaperSortDescriptor: [Int]] = [:]
        private var lastRequest: Request?
        private var lastOffsets: [Int] = []
        private var lastResult: [Paper] = []

        private struct Request: Equatable {
            let filter: LibraryFilter
            let query: String
            let includeSubcollections: Bool
            let sortDescriptor: PaperSortDescriptor
        }

        init(snapshot: LibrarySnapshot) {
            self.snapshot = snapshot
            tagNames = Dictionary(snapshot.tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            documents = Array(repeating: nil, count: snapshot.papers.count)
        }

        func papers(filter: LibraryFilter, searchText: String, includeSubcollections: Bool,
                    sortDescriptor: PaperSortDescriptor, now: Date = Date()) -> [Paper] {
            let query = searchText.trimmed.lowercased().precomposedStringWithCanonicalMapping
            let request = Request(filter: filter, query: query, includeSubcollections: includeSubcollections,
                                  sortDescriptor: sortDescriptor)
            // Recently added changes as the clock crosses the 30-day boundary,
            // even without an edit. It must never reuse a cached result.
            if filter != .recentlyAdded, request == lastRequest { return lastResult }
            let collectionIDs: Set<UUID>
            if case .collection(let id) = filter {
                collectionIDs = includeSubcollections ? snapshot.collections.descendantIDs(of: id) : [id]
            } else { collectionIDs = [] }
            let queryBytes = Array(query.utf8)
            var offsets: [Int] = []
            for (offset, paper) in snapshot.papers.enumerated() {
                guard LibraryQuery.matches(paper, filter: filter, collectionIDs: collectionIDs, now: now) else { continue }
                if !query.isEmpty {
                    if documents[offset] == nil {
                        let collectionText = paper.collectionIDs.map { id -> String in
                            if let path = collectionPaths[id] { return path }
                            let path = snapshot.collections.path(for: id)
                            collectionPaths[id] = path
                            return path
                        }.joined(separator: " ")
                        let tagText = paper.tagIDs.compactMap { tagNames[$0] }.joined(separator: " ")
                        documents[offset] = SearchDocument(LibraryQuery.searchText(for: paper, collections: collectionText, tags: tagText))
                    }
                    guard documents[offset]!.contains(queryBytes) else { continue }
                }
                offsets.append(offset)
            }
            let result: [Paper]
            if lastRequest?.sortDescriptor == sortDescriptor, offsets == lastOffsets {
                // Typing the next character often leaves the same matches.
                // Keep the existing row array rather than copying every Paper.
                result = lastResult
            } else if offsets.count < 2 {
                result = offsets.map { snapshot.papers[$0] }
            } else if let order = sortedOffsets[sortDescriptor] {
                let matches = Set(offsets)
                result = order.compactMap { matches.contains($0) ? snapshot.papers[$0] : nil }
            } else if offsets.count < max(32, snapshot.papers.count / 8) {
                // A first query into a tiny collection should not need to sort
                // the entire library just to show a handful of matches.
                result = offsets.sorted {
                    LibraryQuery.isOrderedBefore(snapshot.papers[$0], snapshot.papers[$1], by: sortDescriptor)
                }.map { snapshot.papers[$0] }
            } else {
                let order = snapshot.papers.indices.sorted {
                    LibraryQuery.isOrderedBefore(snapshot.papers[$0], snapshot.papers[$1], by: sortDescriptor)
                }
                sortedOffsets[sortDescriptor] = order
                let matches = Set(offsets)
                result = order.compactMap { matches.contains($0) ? snapshot.papers[$0] : nil }
            }
            lastRequest = request
            lastOffsets = offsets
            lastResult = result
            return result
        }
    }

    /// Swift's substring search preserves canonical equivalence and complete
    /// grapheme boundaries, but scanning long abstracts with it is expensive.
    /// Normalize once, scan UTF-8, and let Swift validate candidate boundaries.
    private struct SearchDocument {
        let text: String
        let bytes: [UInt8]

        init(_ value: String) {
            text = value.lowercased().precomposedStringWithCanonicalMapping
            bytes = Array(text.utf8)
        }

        func contains(_ query: [UInt8]) -> Bool {
            guard !query.isEmpty else { return true }
            return query.withUnsafeBytes { needle in
                bytes.withUnsafeBytes { haystack in
                    guard let base = haystack.baseAddress, let pattern = needle.baseAddress else { return false }
                    var start = 0
                    while start <= haystack.count - needle.count {
                        guard let candidate = memmem(base.advanced(by: start), haystack.count - start, pattern, needle.count) else { return false }
                        let offset = base.distance(to: candidate)
                        let lower = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
                        let upper = text.utf8.index(lower, offsetBy: needle.count)
                        if String.Index(lower, within: text) != nil, String.Index(upper, within: text) != nil { return true }
                        start = offset + 1
                    }
                    return false
                }
            }
        }
    }

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
        let query = searchText.trimmed.lowercased().precomposedStringWithCanonicalMapping
        let queryBytes = Array(query.utf8)
        let collectionIDs: Set<UUID>
        if case .collection(let id) = filter {
            collectionIDs = includeSubcollections ? snapshot.collections.descendantIDs(of: id) : [id]
        } else { collectionIDs = [] }
        let tagNames = query.isEmpty ? [:] : Dictionary(snapshot.tags.map { ($0.id, $0.name) },
                                                       uniquingKeysWith: { first, _ in first })
        var collectionPaths: [UUID: String] = [:]
        let filtered = snapshot.papers.filter { paper in
            guard matches(paper, filter: filter, collectionIDs: collectionIDs, now: now) else { return false }
            guard !query.isEmpty else { return true }
            let collectionText = paper.collectionIDs.map { id in
                if let path = collectionPaths[id] { return path }
                let path = snapshot.collections.path(for: id)
                collectionPaths[id] = path
                return path
            }.joined(separator: " ")
            let tagText = paper.tagIDs.compactMap { tagNames[$0] }.joined(separator: " ")
            return SearchDocument(Self.searchText(for: paper, collections: collectionText, tags: tagText)).contains(queryBytes)
        }
        // Filter the stored order directly and perform only the requested sort.
        return sort(filtered, by: sortDescriptor)
    }

    private static func sort(_ papers: [Paper], by descriptor: PaperSortDescriptor) -> [Paper] {
        papers.sorted { isOrderedBefore($0, $1, by: descriptor) }
    }

    private static func isOrderedBefore(_ lhs: Paper, _ rhs: Paper, by descriptor: PaperSortDescriptor) -> Bool {
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
            // Preserve the previous newest-first order for identical labels.
            return titleOrder == .orderedSame ? lhs.dateAdded > rhs.dateAdded : titleOrder == .orderedAscending
        }
        return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private static func matches(_ paper: Paper, filter: LibraryFilter, collectionIDs: Set<UUID>, now: Date) -> Bool {
        switch filter {
        case .all: return true
        case .recentlyAdded: return now.timeIntervalSince(paper.dateAdded) <= 60 * 60 * 24 * 30
        case .recentlyOpened: return paper.lastOpenedAt != nil
        case .unfiled: return paper.collectionIDs.isEmpty
        case .missingPDF: return !paper.hasPDF
        case .missingIDs: return !paper.hasIdentifier
        case .noTags: return paper.tagIDs.isEmpty
        case .rating(let value): return paper.rating == value
        case .collection: return paper.collectionIDs.contains { collectionIDs.contains($0) }
        case .tag(let id): return paper.tagIDs.contains(id)
        }
    }

    private static func searchText(for paper: Paper, collections: String, tags: String) -> String {
        [paper.title, paper.subtitle ?? "", paper.authorsDisplay,
         (paper.editors ?? []).joined(separator: " "), (paper.translators ?? []).joined(separator: " "),
         paper.sourceDisplay, paper.year.map(String.init) ?? "", paper.doi, paper.isbn, paper.eprint,
         paper.citekey, paper.abstract, paper.notes, collections, tags,
         paper.customFields.map { "\($0.key) \($0.value)" }.joined(separator: " ")].joined(separator: " ")
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
