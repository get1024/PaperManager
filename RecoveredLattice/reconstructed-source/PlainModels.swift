import Foundation

// Compiler-checkable model sketch without SwiftData macros.
// Use this when working outside an Xcode target that has SwiftDataMacros available.

struct MetadataTemplateRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var content: String
    var isDefault: Bool
    var dateCreated: Date
}

struct PaperRecord: Identifiable, Codable, Hashable {
    var id: UUID
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
    var collectionIDs: [UUID]
    var tagIDs: [UUID]
    var attachmentIDs: [UUID]
    var annotationIDs: [UUID]
}

struct PaperAttachmentRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var bookmark: Data?
    var filename: String
    var dateAdded: Date
    var paperID: UUID?
}

struct PaperCollectionRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var icon: String?
    var sortOrder: Int
    var parentID: UUID?
    var childIDs: [UUID]
    var paperIDs: [UUID]
}

struct PDFAnnotationRecord: Identifiable, Codable, Hashable {
    var id: UUID
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
    var paperID: UUID?
}

struct TagRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var color: String?
    var sortOrder: Int
    var paperIDs: [UUID]
}
