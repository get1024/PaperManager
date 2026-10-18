import Foundation

enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return PMLocalization.text("自动")
        case .light: return PMLocalization.text("浅色")
        case .dark: return PMLocalization.text("深色")
        }
    }
}

enum PDFOrganizationMode: String, Codable, CaseIterable, Identifiable {
    case none
    case copy
    case move

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return PMLocalization.text("不做任何处理")
        case .copy: return PMLocalization.text("复制到文件夹")
        case .move: return PMLocalization.text("移动到文件夹")
        }
    }
}

enum PDFSubfolderGrouping: String, Codable, CaseIterable, Identifiable {
    case none
    case year
    case authorInitial
    case collection

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return PMLocalization.text("无")
        case .year: return PMLocalization.text("按年份")
        case .authorInitial: return PMLocalization.text("按作者首字母")
        case .collection: return PMLocalization.text("按文集")
        }
    }
}

enum TableDensity: String, Codable, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return PMLocalization.text("紧凑")
        case .comfortable: return PMLocalization.text("舒适")
        }
    }
}

enum CitationExportField: String, CaseIterable, Identifiable {
    case abstract
    case keywords
    case notes
    case customFields

    var id: String { rawValue }

    var label: String {
        switch self {
        case .abstract: return PMLocalization.text("包含摘要")
        case .keywords: return PMLocalization.text("包含关键词（来自标签）")
        case .notes: return PMLocalization.text("包含备注")
        case .customFields: return PMLocalization.text("包含自定义字段")
        }
    }
}

struct AppSettings: Codable, Hashable {
    var appearance: AppearanceChoice = .system
    var languageIdentifier: String = "system"
    var tableDensity: TableDensity = .compact
    var showInspectorByDefault: Bool = true

    var deleteAttachmentsToTrash: Bool = false
    var defaultPDFReaderPath: String = ""
    var pdfOrganizationMode: PDFOrganizationMode = .none
    var pdfOrganizationFolder: String = ""
    // Optional so snapshots written before File Library remain decodable.
    // Legacy path settings are interpreted by FileLibraryService until the
    // user explicitly configures or declines a single authorized root.
    var fileLibrary: FileLibraryPreferences? = nil
    var pdfSubfolderGrouping: PDFSubfolderGrouping = .none
    var autoRenamePDFs: Bool = false
    var pdfRenameTemplate: String = "{year} - {authEtAl} - {title:50}"
    var confirmBeforeMovingFiles: Bool = true
    var autoExtractMetadataAfterImport: Bool = true
    var autoExtractAnnotationsAfterImport: Bool = false
    var autoExtractAnnotationsAfterOpeningPDF: Bool = false

    var citekeyFormat: String = "{auth}{year}"
    // Absent in older snapshots: nil includes all four optional export groups.
    var disabledCitationExportFields: [String]? = nil
    var metadataTemplate: String = AppSettings.defaultMetadataTemplate
    var annotationTemplate: String = AppSettings.defaultAnnotationTemplate
    var activeMetadataTemplateID: UUID? = nil

    var localAPIEnabled: Bool = false
    var localAPIReadOnly: Bool = false
    var browserExtensionEnabled: Bool = true
    var localAPIPort: Int = 29467
    var browserUploadFolder: String = ""

    var freePaperLimit: Int = 50
    var proUnlocked: Bool = false

    static let defaults = AppSettings()

    func includesCitationExport(_ field: CitationExportField) -> Bool {
        !(disabledCitationExportFields ?? []).contains(field.rawValue)
    }

    mutating func setCitationExport(_ field: CitationExportField, included: Bool) {
        var disabled = Set(disabledCitationExportFields ?? [])
        if included {
            disabled.remove(field.rawValue)
        } else {
            disabled.insert(field.rawValue)
        }
        disabledCitationExportFields = disabled.isEmpty ? nil : disabled.sorted()
    }

    static let defaultMetadataTemplate = """
    # {{title}}

    {{#authors}}**Authors:** {{authors}}
    {{/authors}}{{#year}}**Year:** {{year}}
    {{/year}}{{#source}}**Source:** {{source}}
    {{/source}}{{#doi}}**DOI:** {{doi}}
    {{/doi}}{{#url}}**URL:** {{url}}
    {{/url}}{{#abstract}}
    ## Abstract

    {{abstract}}
    {{/abstract}}{{#notes}}
    ## Notes

    {{notes}}
    {{/notes}}{{#annotations}}
    ## Annotations

    {{annotations}}
    {{/annotations}}
    """

    static let defaultAnnotationTemplate = """
    - Page {{page}} · {{type}}
      {{#selectedText}}
      > {{selectedText}}
      {{/selectedText}}{{#note}}
      Comment: {{note}}
      {{/note}}{{#image}}
      ![]({{image}})
      {{/image}}
    """
}
