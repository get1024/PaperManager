import Foundation

enum CitekeyGenerator {
    static func generate(for paper: Paper, format: String, existing: Set<String>) -> String {
        let rendered = render(format: format, paper: paper)
        let base = rendered
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "", options: .regularExpression)
            .trimmed

        let fallback = fallbackBase(for: paper)
        let stem = base.isEmpty ? fallback : base
        if !existing.contains(stem) { return stem }

        var suffix = UnicodeScalar("a").value
        while suffix <= UnicodeScalar("z").value {
            let candidate = "\(stem)\(Character(UnicodeScalar(suffix)!))"
            if !existing.contains(candidate) { return candidate }
            suffix += 1
        }

        var index = 2
        while existing.contains("\(stem)\(index)") {
            index += 1
        }
        return "\(stem)\(index)"
    }

    static func render(format: String, paper: Paper) -> String {
        var value = format
        let replacements: [String: String] = [
            "citekey": paper.citekey,
            "author": firstAuthorLastName(paper).capitalized,
            "authorLower": firstAuthorLastName(paper).lowercased(),
            "authorInitial": firstAuthorLastName(paper).prefix(1).uppercased(),
            "year": paper.year.map(String.init) ?? "",
            "year2": paper.year.map { String(String($0).suffix(2)) } ?? "",
            "title": paper.title,
            "titleWord": firstMeaningfulTitleWord(paper.title).lowercased(),
            "journal": paper.journal,
            "doi": paper.doi
        ]
        for (key, replacement) in replacements {
            value = value.replacingOccurrences(of: "{{\(key)}}", with: replacement)
        }
        return value
    }

    static func firstAuthorLastName(_ paper: Paper) -> String {
        guard let first = paper.authors.first?.trimmed, !first.isEmpty else { return "unknown" }
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmed ?? "unknown"
        }
        let parts = first.split(separator: " ")
        return parts.last.map(String.init) ?? first
    }

    static func firstMeaningfulTitleWord(_ title: String) -> String {
        let stopWords: Set<String> = ["a", "an", "the", "of", "on", "in", "for", "to", "and", "or", "with"]
        let words = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        return words.first ?? "untitled"
    }

    private static func fallbackBase(for paper: Paper) -> String {
        "\(firstAuthorLastName(paper).lowercased())\(paper.year.map(String.init) ?? "")\(firstMeaningfulTitleWord(paper.title).lowercased())"
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "", options: .regularExpression)
    }
}
