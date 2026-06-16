import Foundation

enum BibTeXParser {
    static func parse(_ text: String) -> [Paper] {
        entries(in: text).compactMap(parseEntry)
    }

    private static func entries(in text: String) -> [(type: String, body: String)] {
        let characters = Array(text)
        var result: [(String, String)] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "@" else {
                index += 1
                continue
            }
            index += 1
            let typeStart = index
            while index < characters.count, characters[index].isLetter {
                index += 1
            }
            let type = String(characters[typeStart..<index]).lowercased()
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            guard index < characters.count, characters[index] == "{" || characters[index] == "(" else {
                continue
            }
            let open = characters[index]
            let close: Character = open == "{" ? "}" : ")"
            index += 1
            let bodyStart = index
            var depth = 1
            var inQuote = false
            while index < characters.count, depth > 0 {
                let char = characters[index]
                if char == "\"" { inQuote.toggle() }
                if !inQuote {
                    if char == open { depth += 1 }
                    if char == close { depth -= 1 }
                }
                index += 1
            }
            let bodyEnd = max(bodyStart, index - 1)
            if !["comment", "preamble", "string"].contains(type), bodyEnd > bodyStart {
                result.append((type, String(characters[bodyStart..<bodyEnd])))
            }
        }

        return result
    }

    private static func parseEntry(type: String, body: String) -> Paper? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let key = String(body[..<comma]).trimmed
        let fieldsBody = String(body[body.index(after: comma)...])
        let fields = parseFields(fieldsBody)

        var paper = Paper()
        paper.paperType = PaperType.fromBibTeX(type)
        paper.citekey = key
        paper.title = fields["title"] ?? ""
        paper.authors = parseAuthors(fields["author"] ?? fields["editor"] ?? "")
        paper.year = parseYear(fields["year"] ?? fields["date"] ?? "")
        paper.journal = fields["journal"] ?? fields["journaltitle"] ?? ""
        paper.bookTitle = fields["booktitle"] ?? ""
        paper.publisher = fields["publisher"] ?? ""
        paper.institution = fields["institution"] ?? fields["organization"] ?? ""
        paper.school = fields["school"] ?? ""
        paper.volume = fields["volume"] ?? ""
        paper.issue = fields["number"] ?? fields["issue"] ?? ""
        paper.pages = fields["pages"] ?? ""
        paper.month = fields["month"] ?? ""
        paper.doi = fields["doi"] ?? ""
        paper.isbn = fields["isbn"] ?? ""
        paper.url = fields["url"] ?? ""
        paper.abstract = fields["abstract"] ?? ""
        paper.notes = fields["note"] ?? ""
        paper.series = fields["series"] ?? ""
        paper.edition = fields["edition"] ?? ""
        paper.chapter = fields["chapter"] ?? ""
        paper.eprint = fields["eprint"] ?? ""
        paper.eprintType = fields["eprinttype"] ?? fields["archiveprefix"] ?? ""
        paper.eprintClass = fields["eprintclass"] ?? fields["primaryclass"] ?? ""

        let standard = Set([
            "title", "author", "editor", "year", "date", "journal", "journaltitle",
            "booktitle", "publisher", "institution", "organization", "school",
            "volume", "number", "issue", "pages", "month", "doi", "isbn", "url",
            "abstract", "note", "series", "edition", "chapter", "eprint",
            "eprinttype", "archiveprefix", "eprintclass", "primaryclass"
        ])
        paper.customFields = fields
            .filter { !standard.contains($0.key) }
            .map { CustomField(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        return paper
    }

    private static func parseFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
            let keyStart = index
            while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "-" || characters[index] == "_" {
                index += 1
            }
            guard keyStart < index else { break }
            let key = String(characters[keyStart..<index]).lowercased()
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] == "=" else { break }
            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }

            let valueStart = index
            var depth = 0
            var inQuote = false
            while index < characters.count {
                let char = characters[index]
                if char == "\"" { inQuote.toggle() }
                if !inQuote {
                    if char == "{" || char == "(" { depth += 1 }
                    if char == "}" || char == ")" { depth = max(0, depth - 1) }
                    if char == "," && depth == 0 { break }
                }
                index += 1
            }
            let rawValue = String(characters[valueStart..<index])
            fields[key] = cleanValue(rawValue)
        }

        return fields
    }

    private static func cleanValue(_ value: String) -> String {
        var result = value.trimmed
        while (result.hasPrefix("{") && result.hasSuffix("}")) ||
                (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
                (result.hasPrefix("(") && result.hasSuffix(")")) {
            result = String(result.dropFirst().dropLast()).trimmed
        }
        return result
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "\\{", with: "{")
            .replacingOccurrences(of: "\\}", with: "}")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }

    private static func parseAuthors(_ value: String) -> [String] {
        value.replacingOccurrences(of: #"(?i)\s+and\s+"#, with: "|||", options: .regularExpression)
            .components(separatedBy: "|||")
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    private static func parseYear(_ value: String) -> Int? {
        value.range(of: #"\d{4}"#, options: .regularExpression).flatMap { Int(value[$0]) }
    }
}
