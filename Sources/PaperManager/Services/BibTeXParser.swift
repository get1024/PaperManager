import Foundation

enum BibTeXParser {
    static func parse(_ text: String) -> [Paper] {
        var macros = Dictionary(uniqueKeysWithValues: zip(
            ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"],
            ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        ))
        var papers: [Paper] = []
        for entry in entries(in: text) {
            if entry.type == "string" {
                for (name, value) in parseFields(entry.body, macros: macros, trimValues: false) { macros[name] = value }
            } else if let paper = parseEntry(type: entry.type, body: entry.body, macros: macros) {
                papers.append(paper)
            }
        }
        return papers
    }

    private static func entries(in text: String) -> [(type: String, body: String)] {
        let characters = Array(text)
        var result: [(String, String)] = []
        var index = 0

        while index < characters.count {
            if characters[index] == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
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
            var depth = open == "{" ? 1 : 0
            var inQuote = false
            var foundEnd = false
            while index < characters.count {
                let char = characters[index]
                if char == "\\", index + 1 < characters.count {
                    index += 2
                    continue
                }
                let outerDepth = open == "{" ? 1 : 0
                if char == "%", depth == outerDepth, !inQuote {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue
                }
                if char == "\"", depth == outerDepth { inQuote.toggle() }
                if !inQuote {
                    if char == "{" { depth += 1 }
                    if char == "}" { depth -= 1 }
                    if (close == "}" && depth == 0) || (close == ")" && char == ")" && depth == 0) {
                        foundEnd = true
                        break
                    }
                }
                index += 1
            }
            if foundEnd, !["comment", "preamble"].contains(type), index > bodyStart {
                result.append((type, String(characters[bodyStart..<index])))
            }
            index += foundEnd ? 1 : 0
        }

        return result
    }

    private static func parseEntry(type: String, body: String, macros: [String: String]) -> Paper? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let key = String(body[..<comma]).trimmed
        let fieldsBody = String(body[body.index(after: comma)...])
        let fields = parseFields(fieldsBody, macros: macros)

        var paper = Paper()
        paper.paperType = PaperType.fromBibTeX(type)
        paper.citekey = key
        paper.title = fields["title"] ?? ""
        paper.subtitle = fields["subtitle"]?.nilIfBlank
        paper.authors = parseAuthors(fields["author"] ?? "")
        paper.editors = fields["editor"].map(parseAuthors)
        paper.translators = fields["translator"].map(parseAuthors)
        paper.year = parseYear(fields["year"] ?? fields["date"] ?? "")
        paper.journal = fields["journal"] ?? fields["journaltitle"] ?? ""
        paper.bookTitle = fields["booktitle"] ?? ""
        paper.publisher = fields["publisher"] ?? ""
        paper.address = fields["address"]?.nilIfBlank
        paper.institution = fields["institution"] ?? ""
        paper.organization = fields["organization"]?.nilIfBlank
        paper.school = fields["school"] ?? ""
        paper.volume = fields["volume"] ?? ""
        paper.issue = fields["number"] ?? fields["issue"] ?? ""
        paper.pages = fields["pages"] ?? ""
        paper.month = fields["month"] ?? ""
        paper.doi = fields["doi"] ?? ""
        paper.isbn = fields["isbn"] ?? ""
        paper.url = fields["url"] ?? ""
        paper.urlDate = fields["urldate"]?.nilIfBlank
        paper.language = fields["language"] ?? ""
        paper.type = fields["type"]?.nilIfBlank
        paper.howPublished = fields["howpublished"] ?? ""
        paper.publicationState = fields["pubstate"] ?? ""
        paper.event = fields["eventtitle"] ?? ""
        paper.eventDate = fields["eventdate"] ?? ""
        paper.venue = fields["venue"] ?? ""
        paper.abstract = fields["abstract"] ?? ""
        paper.notes = fields["note"] ?? ""
        paper.series = fields["series"] ?? ""
        paper.edition = fields["edition"] ?? ""
        paper.chapter = fields["chapter"] ?? ""
        paper.eprint = fields["eprint"] ?? ""
        paper.eprintType = fields["eprinttype"] ?? fields["archiveprefix"] ?? ""
        paper.eprintClass = fields["eprintclass"] ?? fields["primaryclass"] ?? ""

        let standard = Set([
            "title", "subtitle", "author", "editor", "translator", "year", "date", "journal", "journaltitle",
            "booktitle", "publisher", "institution", "organization", "school",
            "volume", "number", "issue", "pages", "month", "doi", "isbn", "url",
            "abstract", "note", "series", "edition", "chapter", "eprint",
            "eprinttype", "archiveprefix", "eprintclass", "primaryclass",
            "address", "urldate", "language", "type", "howpublished", "pubstate", "eventtitle", "eventdate", "venue"
        ])
        paper.customFields = fields
            .filter { !standard.contains($0.key) }
            .map { CustomField(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        return paper
    }

    private static func parseFields(_ text: String, macros: [String: String], trimValues: Bool = true) -> [String: String] {
        var fields: [String: String] = [:]
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
            if index < characters.count, characters[index] == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
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

            var rawValue = ""
            var depth = 0
            var inQuote = false
            while index < characters.count {
                let char = characters[index]
                if char == "\\", index + 1 < characters.count {
                    rawValue.append(characters[index])
                    rawValue.append(characters[index + 1])
                    index += 2
                    continue
                }
                if char == "\"", depth == 0 { inQuote.toggle() }
                if !inQuote {
                    if char == "{" { depth += 1 }
                    if char == "}" { depth = max(0, depth - 1) }
                    if char == "," && depth == 0 { break }
                    if char == "%", depth == 0 {
                        while index < characters.count, characters[index] != "\n" { index += 1 }
                        continue
                    }
                }
                rawValue.append(char)
                index += 1
            }
            fields[key] = resolveExpression(rawValue, macros: macros, trimResult: trimValues)
        }

        return fields
    }

    private static func resolveExpression(_ value: String, macros: [String: String], trimResult: Bool) -> String {
        let characters = Array(value)
        var depth = 0
        var quoted = false
        var index = 0
        var start = 0
        var pieces: [String] = []
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count { index += 2; continue }
            if character == "\"", depth == 0 { quoted.toggle() }
            if !quoted {
                if character == "{" { depth += 1 }
                if character == "}" { depth = max(0, depth - 1) }
                if character == "#", depth == 0 {
                    pieces.append(String(characters[start..<index]))
                    start = index + 1
                }
            }
            index += 1
        }
        pieces.append(String(characters[start..<characters.count]))
        let result = pieces.map { piece in
            let token = piece.trimmed
            if token.hasPrefix("{") || token.hasPrefix("\"") { return cleanLiteral(token) }
            return macros[token.lowercased()] ?? token
        }.joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return trimResult ? result.trimmed : result
    }

    private static func cleanLiteral(_ value: String) -> String {
        var result = value.trimmed
        if (result.hasPrefix("{") && result.hasSuffix("}")) ||
                (result.hasPrefix("\"") && result.hasSuffix("\"")) {
            result = String(result.dropFirst().dropLast())
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
