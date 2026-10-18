import Darwin
import Foundation

@main
@MainActor
struct ConnectorFixtureServer {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, let port = Int(CommandLine.arguments[2]) else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let store = LibraryStore(persistenceURL: root.appendingPathComponent("library.json"))
        var snapshot = LibrarySnapshot.empty
        snapshot.settings.localAPIEnabled = true
        snapshot.settings.localAPIReadOnly = false
        snapshot.settings.localAPIPort = port
        snapshot.settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: managed.path)
        snapshot.settings.pdfOrganizationMode = .copy
        snapshot.settings.confirmBeforeMovingFiles = false
        let collection = PaperCollection(name: "Fixture collection")
        let tag = PaperTag(name: "Fixture tag")
        snapshot.collections = [collection]; snapshot.tags = [tag]
        var first = Paper(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, citekey: "fixture2026", title: "Connector fixture", authors: ["Ada Lovelace"], year: 2026, doi: "10.5555/connector-fixture", abstract: "Fixture abstract")
        let pdf = minimalPDF(), source = root.appendingPathComponent("protected-source.pdf")
        try pdf.write(to: source)
        first.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: source.lastPathComponent, isReadOnlyReference: true)]
        first.collectionIDs = [collection.id]; first.tagIDs = [tag.id]
        snapshot.papers = [first,
            Paper(citekey: "collision", title: "Ambiguous first"),
            Paper(citekey: "collision", title: "Ambiguous second")]
        store.replaceSnapshot(snapshot)
        let server = LocalAPIServer()
        server.reconfigure(with: store)
        for _ in 0..<200 where !server.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        guard server.isRunning else { throw NSError(domain: "FixtureServer", code: 1, userInfo: [NSLocalizedDescriptionKey: server.statusText]) }
        output(["ready": true, "id": first.id.uuidString, "port": port, "pdf": source.path, "collection": collection.name, "tag": tag.name])
        Task.detached {
            while let line = readLine() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                await MainActor.run {
                    if let readOnly = object["readOnly"] as? Bool { store.updateSetting(\.localAPIReadOnly, value: readOnly) }
                    if let state = object["fileLibrary"] as? String {
                        var settings = store.settings
                        switch state {
                        case "configured": settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: managed.path)
                        case "legacyConflict": settings.fileLibrary = FileLibraryPreferences(decision: .legacyConflict, legacyConflictPaths: ["one", "two"])
                        default: settings.fileLibrary = FileLibraryPreferences(decision: .configured, rootPath: root.appendingPathComponent("missing-root").path)
                        }
                        store.updateSettings(settings)
                    }
                    output(["control": "ok"])
                }
            }
        }
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }

    static func output(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }

    static func minimalPDF() -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>"]
        var text = "%PDF-1.4\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }
}
