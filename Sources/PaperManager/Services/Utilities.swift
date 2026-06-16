import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    func sanitizedFileName(fallback: String = "Untitled") -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = parts.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.isEmpty ? fallback : collapsed
    }

    func strippingSimpleHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmed
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

extension Array where Element == PaperCollection {
    func children(of parentID: UUID?) -> [PaperCollection] {
        filter { $0.parentID == parentID }
            .sorted { lhs, rhs in
                if lhs.sortIndex == rhs.sortIndex {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sortIndex < rhs.sortIndex
            }
    }

    func descendantIDs(of collectionID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [collectionID]
        var queue = [collectionID]
        while let current = queue.first {
            queue.removeFirst()
            let children = filter { $0.parentID == current }.map(\.id)
            for child in children where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }
        return result
    }

    func path(for collectionID: UUID) -> String {
        var names: [String] = []
        var currentID: UUID? = collectionID
        var seen = Set<UUID>()
        while let id = currentID,
              let collection = first(where: { $0.id == id }),
              !seen.contains(id) {
            seen.insert(id)
            names.insert(collection.name, at: 0)
            currentID = collection.parentID
        }
        return names.joined(separator: "/")
    }
}

extension URL {
    var lowercasePathExtension: String {
        pathExtension.lowercased()
    }

    var isPDF: Bool { lowercasePathExtension == "pdf" }
    var isBibTeX: Bool { lowercasePathExtension == "bib" || lowercasePathExtension == "bibtex" }
    var isRIS: Bool { lowercasePathExtension == "ris" }
}

enum PaperManagerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
