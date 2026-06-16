import AppKit
import Foundation

enum ExportService {
    static func bibTeX(for papers: [Paper]) -> String {
        papers.map(bibTeXEntry).joined(separator: "\n\n")
    }

    static func ris(for papers: [Paper]) -> String {
        papers.map(risRecord).joined(separator: "\n")
    }

    static func detailedMarkdown(for papers: [Paper], snapshot: LibrarySnapshot) -> [(filename: String, text: String)] {
        papers.map { paper in
            let filename = (paper.citekey.nilIfBlank ?? paper.displayTitle).sanitizedFileName()
            return (filename + ".md", TemplateRenderer.renderMetadata(paper: paper, snapshot: snapshot))
        }
    }

    static func writeBibTeX(_ papers: [Paper], to url: URL) throws {
        try bibTeX(for: papers).write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeRIS(_ papers: [Paper], to url: URL) throws {
        try ris(for: papers).write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeDetailedMarkdown(_ papers: [Paper], snapshot: LibrarySnapshot, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for paper in papers {
            if paper.annotations.contains(where: { $0.imageFilePath?.nilIfBlank != nil }) {
                try writeTextBundle(paper: paper, snapshot: snapshot, to: folder)
            } else {
                let filename = (paper.citekey.nilIfBlank ?? paper.displayTitle).sanitizedFileName() + ".md"
                let text = TemplateRenderer.renderMetadata(paper: paper, snapshot: snapshot)
                try text.write(to: uniqueFileURL(folder.appendingPathComponent(filename)), atomically: true, encoding: .utf8)
            }
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func bibTeXEntry(_ paper: Paper) -> String {
        let key = paper.citekey.nilIfBlank ?? CitekeyGenerator.generate(for: paper, format: "{{authorLower}}{{year}}{{titleWord}}", existing: [])
        let fields = bibFields(for: paper)
        let body = fields.map { "  \($0.key) = {\(escapeBib($0.value))}" }.joined(separator: ",\n")
        return "@\(paper.paperType.bibTeXType){\(key),\n\(body)\n}"
    }

    private static func bibFields(for paper: Paper) -> [(key: String, value: String)] {
        var fields: [(String, String)] = []
        add("title", paper.title, to: &fields)
        add("subtitle", paper.subtitle ?? "", to: &fields)
        if !paper.authors.isEmpty {
            add("author", paper.authors.joined(separator: " and "), to: &fields)
        }
        if let editors = paper.editors, !editors.isEmpty {
            add("editor", editors.joined(separator: " and "), to: &fields)
        }
        if let translators = paper.translators, !translators.isEmpty {
            add("translator", translators.joined(separator: " and "), to: &fields)
        }
        add("year", paper.year.map(String.init) ?? "", to: &fields)
        add("journal", paper.journal, to: &fields)
        add("booktitle", paper.bookTitle, to: &fields)
        add("publisher", paper.publisher, to: &fields)
        add("address", paper.address ?? "", to: &fields)
        add("edition", paper.edition, to: &fields)
        add("institution", paper.institution, to: &fields)
        add("school", paper.school, to: &fields)
        add("series", paper.series, to: &fields)
        add("chapter", paper.chapter, to: &fields)
        add("type", paper.type ?? "", to: &fields)
        add("howpublished", paper.howPublished, to: &fields)
        add("organization", paper.organization ?? "", to: &fields)
        add("language", paper.language, to: &fields)
        add("volume", paper.volume, to: &fields)
        add("number", paper.issue, to: &fields)
        add("pages", paper.pages, to: &fields)
        add("month", paper.month, to: &fields)
        add("doi", paper.doi, to: &fields)
        add("isbn", paper.isbn, to: &fields)
        add("url", paper.url, to: &fields)
        add("urldate", paper.urlDate ?? "", to: &fields)
        add("eprint", paper.eprint, to: &fields)
        add("eprinttype", paper.eprintType, to: &fields)
        add("eprintclass", paper.eprintClass, to: &fields)
        add("pubstate", paper.publicationState, to: &fields)
        add("eventtitle", paper.event, to: &fields)
        add("eventdate", paper.eventDate, to: &fields)
        add("venue", paper.venue, to: &fields)
        add("abstract", paper.abstract, to: &fields)
        add("note", paper.notes, to: &fields)
        for field in paper.customFields where !field.key.trimmed.isEmpty {
            add(field.key, field.value, to: &fields)
        }
        return fields
    }

    private static func risRecord(_ paper: Paper) -> String {
        var lines: [String] = ["TY  - \(paper.paperType.risType)"]
        appendRIS("ID", paper.citekey, to: &lines)
        appendRIS("T1", paper.title, to: &lines)
        appendRIS("ST", paper.subtitle ?? "", to: &lines)
        for author in paper.authors {
            appendRIS("AU", author, to: &lines)
        }
        for editor in paper.editors ?? [] {
            appendRIS("ED", editor, to: &lines)
        }
        appendRIS("PY", paper.year.map(String.init) ?? "", to: &lines)
        appendRIS("JO", paper.journal, to: &lines)
        appendRIS("T2", paper.bookTitle, to: &lines)
        appendRIS("PB", paper.publisher, to: &lines)
        appendRIS("CY", paper.address ?? "", to: &lines)
        appendRIS("ET", paper.edition, to: &lines)
        appendRIS("VL", paper.volume, to: &lines)
        appendRIS("IS", paper.issue, to: &lines)
        let pageParts = splitPages(paper.pages)
        appendRIS("SP", pageParts.start, to: &lines)
        appendRIS("EP", pageParts.end, to: &lines)
        appendRIS("DO", paper.doi, to: &lines)
        appendRIS("SN", paper.isbn, to: &lines)
        appendRIS("UR", paper.url, to: &lines)
        appendRIS("Y2", paper.urlDate ?? "", to: &lines)
        appendRIS("LA", paper.language, to: &lines)
        appendRIS("M3", paper.type ?? "", to: &lines)
        appendRIS("AB", paper.abstract, to: &lines)
        appendRIS("N1", paper.notes, to: &lines)
        lines.append("ER  -")
        return lines.joined(separator: "\n")
    }

    private static func add(_ key: String, _ value: String, to fields: inout [(String, String)]) {
        let clean = value.trimmed
        if !clean.isEmpty {
            fields.append((key, clean))
        }
    }

    private static func appendRIS(_ tag: String, _ value: String, to lines: inout [String]) {
        let clean = value.trimmed
        if !clean.isEmpty {
            lines.append("\(tag)  - \(clean)")
        }
    }

    private static func escapeBib(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
    }

    private static func splitPages(_ pages: String) -> (start: String, end: String) {
        let separators = ["--", "-", "–", "—"]
        for separator in separators where pages.contains(separator) {
            let parts = pages.components(separatedBy: separator)
            return (parts.first?.trimmed ?? "", parts.dropFirst().joined(separator: separator).trimmed)
        }
        return (pages.trimmed, "")
    }

    private static func writeTextBundle(paper: Paper, snapshot: LibrarySnapshot, to folder: URL) throws {
        let baseName = (paper.citekey.nilIfBlank ?? paper.displayTitle).sanitizedFileName()
        let bundleURL = uniqueDirectoryURL(folder.appendingPathComponent(baseName).appendingPathExtension("textbundle"))
        let assetsURL = bundleURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        var relativeImagePaths: [UUID: String] = [:]
        var imageIndex = 1
        for annotation in paper.annotations {
            guard let path = annotation.imageFilePath?.nilIfBlank else { continue }
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let ext = source.pathExtension.nilIfBlank ?? "png"
            let destinationName = "annotation-\(imageIndex).\(ext)"
            try FileManager.default.copyItem(at: source, to: assetsURL.appendingPathComponent(destinationName))
            relativeImagePaths[annotation.id] = "assets/\(destinationName)"
            imageIndex += 1
        }

        let text = TemplateRenderer.renderMetadata(
            paper: paper,
            snapshot: snapshot,
            annotationImagePath: { annotation in
                relativeImagePaths[annotation.id] ?? annotation.imageFilePath ?? ""
            }
        )
        try text.write(to: bundleURL.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
    }

    private static func uniqueFileURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private static func uniqueDirectoryURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
