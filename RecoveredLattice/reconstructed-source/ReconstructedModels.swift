import Foundation
import SwiftData

// Reconstruction sketch from:
// - main-app/classes-and-ivars.md
// - database/default-store-schema.sql
//
// This is a starting point, not a verified copy of the original source.

@Model
final class MetadataTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: String
    var isDefault: Bool
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        isDefault: Bool = false,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.isDefault = isDefault
        self.dateCreated = dateCreated
    }
}

@Model
final class Paper {
    @Attribute(.unique) var id: UUID
    var title: String
    var authors: [String]
    var year: Int?
    var journal: String?
    var doi: String?
    var abstract: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var paperType: String?
    var pdfBookmark: Data?
    var notes: String?
    var rating: Int
    var dateAdded: Date
    var bibtexKey: String?
    var isbn: String?
    var subtitle: String?
    var editors: [String]
    var translators: [String]
    var publisher: String?
    var booktitle: String?
    var address: String?
    var edition: String?
    var series: String?
    var chapter: String?
    var institution: String?
    var school: String?
    var type: String?
    var howpublished: String?
    var organization: String?
    var language: String?
    var month: String?
    var url: String?
    var urlDate: String?
    var eprint: String?
    var eprintType: String?
    var eprintClass: String?
    var pubState: String?
    var eventTitle: String?
    var eventDate: String?
    var venue: String?
    var extraFieldsData: Data?
    var activePDFAttachID: UUID?

    @Relationship var collections: [PaperCollection]
    @Relationship var tags: [Tag]
    @Relationship(deleteRule: .cascade, inverse: \PDFAnnotationItem.paper) var annotations: [PDFAnnotationItem]
    @Relationship(deleteRule: .cascade, inverse: \PaperAttachment.paper) var attachments: [PaperAttachment]

    init(
        id: UUID = UUID(),
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        journal: String? = nil,
        doi: String? = nil,
        abstract: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        paperType: String? = "article",
        notes: String? = nil,
        rating: Int = 0,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.doi = doi
        self.abstract = abstract
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.paperType = paperType
        self.pdfBookmark = nil
        self.notes = notes
        self.rating = rating
        self.dateAdded = dateAdded
        self.bibtexKey = nil
        self.isbn = nil
        self.subtitle = nil
        self.editors = []
        self.translators = []
        self.publisher = nil
        self.booktitle = nil
        self.address = nil
        self.edition = nil
        self.series = nil
        self.chapter = nil
        self.institution = nil
        self.school = nil
        self.type = nil
        self.howpublished = nil
        self.organization = nil
        self.language = nil
        self.month = nil
        self.url = nil
        self.urlDate = nil
        self.eprint = nil
        self.eprintType = nil
        self.eprintClass = nil
        self.pubState = nil
        self.eventTitle = nil
        self.eventDate = nil
        self.venue = nil
        self.extraFieldsData = nil
        self.activePDFAttachID = nil
        self.collections = []
        self.tags = []
        self.annotations = []
        self.attachments = []
    }
}

@Model
final class PaperAttachment {
    @Attribute(.unique) var id: UUID
    var bookmark: Data?
    var filename: String
    var dateAdded: Date
    var paper: Paper?

    init(id: UUID = UUID(), bookmark: Data? = nil, filename: String, dateAdded: Date = Date(), paper: Paper? = nil) {
        self.id = id
        self.bookmark = bookmark
        self.filename = filename
        self.dateAdded = dateAdded
        self.paper = paper
    }
}

@Model
final class PaperCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String?
    var sortOrder: Int
    var papers: [Paper]
    var parent: PaperCollection?
    @Relationship(deleteRule: .cascade, inverse: \PaperCollection.parent) var children: [PaperCollection]

    init(id: UUID = UUID(), name: String, icon: String? = nil, sortOrder: Int = 0, parent: PaperCollection? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.papers = []
        self.parent = parent
        self.children = []
    }
}

@Model
final class PDFAnnotationItem {
    var type: String
    var pageIndex: Int
    var pageLabel: String?
    var boundsX: Double
    var boundsY: Double
    var boundsWidth: Double
    var boundsHeight: Double
    var text: String?
    var contents: String?
    var colorHex: String?
    var renderedImageData: Data?
    var sortOrder: Int
    var paper: Paper?

    init(
        type: String,
        pageIndex: Int,
        pageLabel: String? = nil,
        boundsX: Double = 0,
        boundsY: Double = 0,
        boundsWidth: Double = 0,
        boundsHeight: Double = 0,
        text: String? = nil,
        contents: String? = nil,
        colorHex: String? = nil,
        renderedImageData: Data? = nil,
        sortOrder: Int = 0,
        paper: Paper? = nil
    ) {
        self.type = type
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.boundsX = boundsX
        self.boundsY = boundsY
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight
        self.text = text
        self.contents = contents
        self.colorHex = colorHex
        self.renderedImageData = renderedImageData
        self.sortOrder = sortOrder
        self.paper = paper
    }
}

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    var color: String?
    var sortOrder: Int
    var papers: [Paper]

    init(id: UUID = UUID(), name: String, color: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.papers = []
    }
}
