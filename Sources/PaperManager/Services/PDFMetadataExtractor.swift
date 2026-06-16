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

    static func extractAnnotations(
        from document: PDFDocument,
        imageDirectory: URL? = nil,
        paperID: UUID? = nil
    ) -> [ResearchAnnotation] {
        var annotations: [ResearchAnnotation] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for pdfAnnotation in page.annotations {
                let kind = AnnotationKind(pdfType: pdfAnnotation.type)
                let selectedText = selectedText(for: pdfAnnotation, on: page)
                let imagePath: String?
                if kind.needsImage {
                    imagePath = renderAnnotationImage(
                        annotation: pdfAnnotation,
                        page: page,
                        pageIndex: pageIndex,
                        imageDirectory: imageDirectory,
                        paperID: paperID
                    )?.path
                } else {
                    imagePath = nil
                }
                let annotation = ResearchAnnotation(
                    page: pageIndex + 1,
                    pageLabel: page.label ?? "",
                    kind: kind,
                    colorHex: pdfAnnotation.color.hexString,
                    selectedText: selectedText,
                    note: pdfAnnotation.contents ?? "",
                    bounds: CGRectCodable(pdfAnnotation.bounds),
                    imageFilePath: imagePath,
                    createdAt: pdfAnnotation.modificationDate
                )
                annotations.append(annotation)
            }
        }
        return annotations
    }

    static func defaultAnnotationImageDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PaperManager", isDirectory: true)
            .appendingPathComponent("AnnotationImages", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func selectedText(for annotation: PDFAnnotation, on page: PDFPage) -> String {
        guard let selection = page.selection(for: annotation.bounds) else { return "" }
        return selection.string?.trimmed ?? ""
    }

    private static func renderAnnotationImage(
        annotation: PDFAnnotation,
        page: PDFPage,
        pageIndex: Int,
        imageDirectory: URL?,
        paperID: UUID?
    ) -> URL? {
        guard let imageDirectory else { return nil }
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let pageBounds = page.bounds(for: .cropBox)
        let padded = annotation.bounds.insetBy(dx: -18, dy: -18).intersection(pageBounds)
        guard padded.width > 4, padded.height > 4 else { return nil }

        let scale: CGFloat = 2
        let imageSize = CGSize(width: padded.width * scale, height: padded.height * scale)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).fill()

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -padded.minX, y: -padded.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let owner = paperID?.uuidString ?? "unknown"
        let filename = "\(owner)-p\(pageIndex + 1)-\(annotation.bounds.integral.hashValue.magnitude).png"
        let url = imageDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
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

private extension AnnotationKind {
    var needsImage: Bool {
        switch self {
        case .square, .circle:
            return true
        case .highlight, .underline, .strikeout, .note, .freeText:
            return false
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
