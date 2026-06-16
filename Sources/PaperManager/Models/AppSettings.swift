import Foundation

enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
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
        case .none: return "不做任何处理"
        case .copy: return "复制到文件夹"
        case .move: return "移动到文件夹"
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
        case .none: return "无"
        case .year: return "按年份"
        case .authorInitial: return "按作者首字母"
        case .collection: return "按文集"
        }
    }
}

enum TableDensity: String, Codable, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .comfortable: return "舒适"
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
    var pdfSubfolderGrouping: PDFSubfolderGrouping = .none
    var autoRenamePDFs: Bool = false
    var pdfRenameTemplate: String = "{{citekey}}"
    var confirmBeforeMovingFiles: Bool = true
    var autoExtractMetadataAfterImport: Bool = true
    var autoExtractAnnotationsAfterImport: Bool = false
    var autoExtractAnnotationsAfterOpeningPDF: Bool = false

    var citekeyFormat: String = "{{authorLower}}{{year}}{{titleWord}}"
    var metadataTemplate: String = AppSettings.defaultMetadataTemplate
    var annotationTemplate: String = AppSettings.defaultAnnotationTemplate

    var localAPIEnabled: Bool = false
    var localAPIReadOnly: Bool = false
    var browserExtensionEnabled: Bool = true
    var localAPIPort: Int = 29467
    var browserUploadFolder: String = ""

    var freePaperLimit: Int = 50
    var proUnlocked: Bool = false

    static let defaults = AppSettings()

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
