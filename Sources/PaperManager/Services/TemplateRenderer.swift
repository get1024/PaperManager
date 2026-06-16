import Foundation

enum TemplateRenderer {
    static func renderMetadata(paper: Paper, snapshot: LibrarySnapshot, includeAnnotations: Bool = true) -> String {
        var context = context(for: paper, snapshot: snapshot)
        if includeAnnotations {
            context["annotations"] = renderAnnotations(paper.annotations, template: snapshot.settings.annotationTemplate)
        } else {
            context["annotations"] = ""
        }
        return render(template: snapshot.settings.metadataTemplate, context: context)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmed
    }

    static func renderAnnotations(_ annotations: [ResearchAnnotation], template: String) -> String {
        annotations.map { annotation in
            let context: [String: String] = [
                "page": String(annotation.page),
                "pageLabel": annotation.pageLabel,
                "type": annotation.kind.rawValue,
                "color": annotation.colorHex,
                "selectedText": annotation.selectedText,
                "note": annotation.note
            ]
            return render(template: template, context: context).trimmed
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func context(for paper: Paper, snapshot: LibrarySnapshot) -> [String: String] {
        let collectionNames = paper.collectionIDs.compactMap { id in
            snapshot.collections.first(where: { $0.id == id }).map(\.name)
        }
        let collectionPaths = paper.collectionIDs.map { snapshot.collections.path(for: $0) }.filter { !$0.isEmpty }
        let tagNames = paper.tagIDs.compactMap { id in
            snapshot.tags.first(where: { $0.id == id }).map(\.name)
        }

        var context: [String: String] = [
            "id": paper.id.uuidString,
            "citekey": paper.citekey,
            "title": paper.displayTitle,
            "subtitle": paper.subtitle ?? "",
            "authors": paper.authors.joined(separator: "; "),
            "author": paper.authorsDisplay,
            "editors": (paper.editors ?? []).joined(separator: "; "),
            "translators": (paper.translators ?? []).joined(separator: "; "),
            "year": paper.year.map(String.init) ?? "",
            "type": paper.paperType.label,
            "bibtexType": paper.type ?? paper.paperType.bibTeXType,
            "source": paper.sourceDisplay,
            "journal": paper.journal,
            "booktitle": paper.bookTitle,
            "address": paper.address ?? "",
            "publisher": paper.publisher,
            "institution": paper.institution,
            "school": paper.school,
            "series": paper.series,
            "volume": paper.volume,
            "issue": paper.issue,
            "pages": paper.pages,
            "month": paper.month,
            "doi": paper.doi,
            "isbn": paper.isbn,
            "url": paper.url,
            "urlDate": paper.urlDate ?? "",
            "language": paper.language,
            "abstract": paper.abstract,
            "notes": paper.notes,
            "event": paper.event,
            "eventDate": paper.eventDate,
            "venue": paper.venue,
            "edition": paper.edition,
            "chapter": paper.chapter,
            "eprint": paper.eprint,
            "eprintType": paper.eprintType,
            "eprintClass": paper.eprintClass,
            "publicationState": paper.publicationState,
            "howPublished": paper.howPublished,
            "organization": paper.organization ?? "",
            "rating": paper.rating > 0 ? String(paper.rating) : "",
            "collections": collectionNames.joined(separator: ", "),
            "collectionPaths": collectionPaths.joined(separator: ", "),
            "tags": tagNames.joined(separator: ", "),
            "pdf": paper.primaryPDF?.filePath ?? ""
        ]

        for field in paper.customFields {
            context[field.key] = field.value
        }
        return context
    }

    static func render(template: String, context: [String: String]) -> String {
        var result = template
        let blockPattern = #"\{\{#([A-Za-z0-9_]+)\}\}([\s\S]*?)\{\{/\1\}\}"#
        let blockRegex = try? NSRegularExpression(pattern: blockPattern)

        while let regex = blockRegex {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: nsRange)
            if matches.isEmpty { break }
            for match in matches.reversed() {
                guard let fieldRange = Range(match.range(at: 1), in: result),
                      let bodyRange = Range(match.range(at: 2), in: result),
                      let fullRange = Range(match.range, in: result) else {
                    continue
                }
                let field = String(result[fieldRange])
                let body = String(result[bodyRange])
                let value = context[field]?.trimmed ?? ""
                let replacement = value.isEmpty ? "" : render(template: body, context: context)
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        let variablePattern = #"\{\{([A-Za-z0-9_]+)\}\}"#
        if let regex = try? NSRegularExpression(pattern: variablePattern) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let fieldRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else {
                    continue
                }
                let field = String(result[fieldRange])
                result.replaceSubrange(fullRange, with: context[field] ?? "")
            }
        }

        return result
    }
}
