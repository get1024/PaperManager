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

    var looksLikeDOI: Bool {
        range(of: #"(?i)\b10\.\d{4,9}/\S+"#, options: .regularExpression) != nil ||
        lowercased().hasPrefix("https://doi.org/") ||
        lowercased().hasPrefix("http://doi.org/")
    }

    /// Compare DOI identities without changing the user's original metadata.
    /// Only complete DOI values qualify, so malformed hints cannot suppress a
    /// different work merely because they share a prefix or a title.
    var normalizedDOI: String? {
        var value = trimmed.replacingOccurrences(of: #"(?i)^doi:\s*"#, with: "", options: .regularExpression).trimmed
        let resolverPrefix = #"(?i)^https?://(?:dx\.)?doi\.org/"#
        if let prefix = value.range(of: resolverPrefix, options: .regularExpression) {
            value = String(value[prefix.upperBound...])
            value = value.removingPercentEncoding ?? value
        }
        value = value.trimmed.lowercased()
        guard value.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    var normalizedISBN: String? {
        let value = trimmed.replacingOccurrences(of: #"(?i)^isbn(?:[- ]1[03])?\s*:?\s*"#, with: "", options: .regularExpression)
        guard value.range(of: #"^[0-9Xx][0-9Xx\s-]+$"#, options: .regularExpression) != nil else { return nil }
        let digits = value.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression).uppercased()
        return digits.count == 10 || digits.count == 13 ? digits : nil
    }

    var normalizedISSN: String? {
        let value = trimmed.replacingOccurrences(of: #"(?i)^(?:e-?)?issn\s*:?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "").uppercased()
        guard value.range(of: #"^[0-9]{7}[0-9X]$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    var looksLikeArxivID: Bool {
        let clean = trimmed
            .replacingOccurrences(of: #"(?i)^arxiv:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.pdf$"#, with: "", options: .regularExpression)
        return clean.range(
            of: #"^([a-z.-]+/\d{7}|\d{4}\.\d{4,5})(v\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    var looksLikeISBN: Bool {
        let clean = replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression)
        guard clean.count == 10 || clean.count == 13 else { return false }
        return range(of: #"(?i)^(isbn(?:-1[03])?:?\s*)?[0-9Xx][0-9Xx\s-]+$"#, options: .regularExpression) != nil
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
