import Foundation

enum RISParser {
    static func parse(_ text: String) -> [Paper] {
        var records: [[String: [String]]] = []
        var current: [String: [String]] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 6 else { continue }
            let tag = String(line.prefix(2))
            guard line.dropFirst(2).prefix(4) == "  -" else { continue }
            let value = String(line.dropFirst(6)).trimmed
            if tag == "TY", !current.isEmpty {
                records.append(current)
                current = [:]
            }
            current[tag, default: []].append(value)
            if tag == "ER" {
                records.append(current)
                current = [:]
            }
        }
        if !current.isEmpty { records.append(current) }

        return records.map(paper(from:))
    }

    private static func paper(from record: [String: [String]]) -> Paper {
        var paper = Paper()
        paper.paperType = paperType(from: record["TY"]?.first)
        paper.title = first(record, ["TI", "T1", "CT"]) ?? ""
        paper.authors = record["AU"] ?? record["A1"] ?? []
        paper.year = parseYear(first(record, ["PY", "Y1", "DA"]) ?? "")
        paper.journal = first(record, ["JO", "JF", "JA", "T2"]) ?? ""
        paper.publisher = first(record, ["PB"]) ?? ""
        paper.volume = first(record, ["VL"]) ?? ""
        paper.issue = first(record, ["IS"]) ?? ""
        paper.pages = pages(start: first(record, ["SP"]), end: first(record, ["EP"]))
        paper.doi = first(record, ["DO"]) ?? ""
        paper.isbn = first(record, ["SN"]) ?? ""
        paper.url = first(record, ["UR", "L1"]) ?? ""
        paper.abstract = first(record, ["AB", "N2"]) ?? ""
        paper.notes = first(record, ["N1"]) ?? ""
        return paper
    }

    private static func first(_ record: [String: [String]], _ tags: [String]) -> String? {
        for tag in tags {
            if let value = record[tag]?.first?.trimmed, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseYear(_ value: String) -> Int? {
        value.range(of: #"\d{4}"#, options: .regularExpression).flatMap { Int(value[$0]) }
    }

    private static func pages(start: String?, end: String?) -> String {
        switch (start?.trimmed.nilIfBlank, end?.trimmed.nilIfBlank) {
        case (.some(let start), .some(let end)): return "\(start)--\(end)"
        case (.some(let start), nil): return start
        default: return ""
        }
    }

    private static func paperType(from value: String?) -> PaperType {
        switch value?.uppercased() {
        case "JOUR": return .article
        case "BOOK": return .book
        case "CHAP": return .inBook
        case "CPAPER": return .inProceedings
        case "CONF": return .proceedings
        case "THES": return .thesis
        case "RPRT": return .report
        case "PAT": return .patent
        case "DATA": return .dataset
        case "COMP": return .software
        case "WEB": return .online
        case "UNPB": return .manuscript
        default: return .misc
        }
    }
}
