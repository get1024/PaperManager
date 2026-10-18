import Foundation

extension LibrarySnapshot {
    /// An old snapshot's two template strings remain usable without writing a
    /// migration merely by reading it. The synthetic date is not a source date.
    var availableMetadataTemplates: [MetadataTemplate] {
        if let metadataTemplates, !metadataTemplates.isEmpty { return metadataTemplates }
        return [MetadataTemplate(id: MetadataTemplate.legacyID, name: "Default Template", content: settings.metadataTemplate,
                                 isDefault: true, dateCreated: Date(timeIntervalSince1970: 0))]
    }

    var selectedMetadataTemplate: MetadataTemplate {
        metadataTemplate(withID: settings.activeMetadataTemplateID)
            ?? availableMetadataTemplates.first(where: \.isDefault)
            ?? availableMetadataTemplates[0]
    }

    func metadataTemplate(withID id: UUID?) -> MetadataTemplate? {
        guard let id else { return nil }
        return availableMetadataTemplates.first { $0.id == id }
    }

    mutating func selectMetadataTemplate(id: UUID) throws {
        guard let template = metadataTemplate(withID: id) else { throw PaperManagerError.message(PMLocalization.text("模板不存在。")) }
        metadataTemplates = availableMetadataTemplates
        settings.activeMetadataTemplateID = id
        settings.metadataTemplate = template.content
    }

    @discardableResult
    mutating func addMetadataTemplate(name: String, content: String = AppSettings.defaultMetadataTemplate) throws -> UUID {
        guard let name = name.nilIfBlank else { throw PaperManagerError.message(PMLocalization.text("模板名称不能为空。")) }
        var templates = availableMetadataTemplates
        let template = MetadataTemplate(name: name, content: content)
        templates.append(template)
        metadataTemplates = templates
        try selectMetadataTemplate(id: template.id)
        return template.id
    }

    mutating func updateMetadataTemplate(id: UUID, name: String? = nil, content: String? = nil) throws {
        var templates = availableMetadataTemplates
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw PaperManagerError.message(PMLocalization.text("模板不存在。")) }
        if let name {
            guard let clean = name.nilIfBlank else { throw PaperManagerError.message(PMLocalization.text("模板名称不能为空。")) }
            templates[index].name = clean
        }
        if let content { templates[index].content = content }
        metadataTemplates = templates
        if selectedMetadataTemplate.id == id { settings.metadataTemplate = templates[index].content }
    }

    mutating func deleteMetadataTemplate(id: UUID) throws {
        var templates = availableMetadataTemplates
        guard templates.count > 1 else { throw PaperManagerError.message(PMLocalization.text("至少保留一个模板。")) }
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw PaperManagerError.message(PMLocalization.text("模板不存在。")) }
        let wasSelected = selectedMetadataTemplate.id == id, wasDefault = templates[index].isDefault
        templates.remove(at: index)
        if wasDefault { templates[0].isDefault = true }
        metadataTemplates = templates
        if wasSelected { try selectMetadataTemplate(id: templates.first(where: \.isDefault)?.id ?? templates[0].id) }
    }
}

@MainActor
enum MetadataTemplateService {
    static func update(in store: LibraryStore, _ edit: (inout LibrarySnapshot) throws -> Void) throws {
        guard store.loadError == nil else { throw PaperManagerError.message(PMLocalization.text("当前文库不可写。")) }
        var snapshot = store.snapshot
        try edit(&snapshot)
        try store.replaceSnapshotDurably(snapshot)
    }
}
