import AppKit
import Foundation
import PDFKit

enum PDFMetadataExtractor {
    static func extract(from url: URL) -> Paper {
        var paper = Paper()
        paper.title = url.deletingPathExtension().lastPathComponent
        paper.attachments = [
            Attachment(kind: .pdf, filePath: url.path, displayName: url.lastPathComponent)
        ]

        guard let document = PDFDocument(url: url) else {
            return paper
        }

        if let attributes = document.documentAttributes {
            if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.trimmed.isEmpty {
                paper.title = title.trimmed
            }
            if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.trimmed.isEmpty {
                paper.authorsText = author
            }
            if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String, !subject.trimmed.isEmpty {
                paper.abstract = subject.trimmed
            }
        }

        let text = firstPagesText(document: document, maxPages: 3)
        if let doi = extractDOI(from: text) {
            paper.doi = doi
        }
        if let arxivID = extractArxivID(from: text) {
            paper.eprint = arxivID
            paper.eprintType = "arxiv"
        }
        return paper
    }

    static func firstPagesText(document: PDFDocument, maxPages: Int) -> String {
        let upperBound = min(document.pageCount, maxPages)
        guard upperBound > 0 else { return "" }
        return (0..<upperBound)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    static func extractDOI(from text: String) -> String? {
        let pattern = #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,\n\r\t);]}>"))
    }

    static func extractArxivID(from text: String) -> String? {
        let patterns = [
            #"(?i)\barxiv\s*:\s*([a-z.-]+/\d{7}|\d{4}\.\d{4,5})(v\d+)?"#,
            #"(?i)\barxiv\.org/(?:abs|pdf)/([a-z.-]+/\d{7}|\d{4}\.\d{4,5})(v\d+)?(?:\.pdf)?"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let idRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let version = match.numberOfRanges > 2
                ? Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
                : ""
            return String(text[idRange]) + version
        }
        return nil
    }

    static func extractAnnotations(from document: PDFDocument) -> [ResearchAnnotation] {
        var annotations: [ResearchAnnotation] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for pdfAnnotation in page.annotations {
                let kind = AnnotationKind(pdfType: pdfAnnotation.type)
                let annotation = ResearchAnnotation(
                    page: pageIndex + 1,
                    pageLabel: page.label ?? "",
                    kind: kind,
                    colorHex: pdfAnnotation.color.hexString,
                    selectedText: "",
                    note: pdfAnnotation.contents ?? ""
                )
                annotations.append(annotation)
            }
        }
        return annotations
    }
}

private extension AnnotationKind {
    init(pdfType: String?) {
        switch pdfType?.lowercased() {
        case "highlight": self = .highlight
        case "underline": self = .underline
        case "strikeout": self = .strikeout
        case "text": self = .note
        case "freetext": self = .freeText
        case "square": self = .square
        case "circle": self = .circle
        default: self = .note
        }
    }
}

extension NSColor {
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
