import Foundation

/// Headless companion for validating migration into an explicitly chosen,
/// independent PaperManager JSON file. It never writes to the Lattice library.
@main
struct LatticeMigrationMain {
    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let usage = "Usage: import-lattice-library.sh snapshot SNAPSHOT_JSON DESTINATION_JSON [EXPECTED_COUNT] | live DESTINATION_JSON [EXPECTED_COUNT]"
            if arguments == ["--help"] || arguments == ["help"] { print(usage); return }
            guard !arguments.isEmpty,
                  (arguments[0] == "snapshot" && arguments.count >= 3) ||
                  (arguments[0] == "live" && arguments.count >= 2) else {
                throw PaperManagerError.message(usage)
            }
            let destinationIndex = arguments[0] == "snapshot" ? 2 : 1
            let expected = arguments.count > destinationIndex + 1 ? Int(arguments[destinationIndex + 1]) : nil
            let destination = URL(fileURLWithPath: arguments[destinationIndex])
            let store = LibraryStore(persistenceURL: destination)
            let summary: LatticeImportSummary
            if arguments[0] == "snapshot" {
                summary = try await LatticeImportService.importMetadataSnapshot(
                    at: URL(fileURLWithPath: arguments[1]), into: store, expectedPaperCount: expected
                )
            } else {
                summary = try await LatticeImportService.importFromRunningLattice(
                    into: store, expectedPaperCount: expected
                )
            }
            let counts = store.collections.map { collection in
                store.papers.filter { $0.collectionIDs.contains(collection.id) }.count
            }.sorted()
            let result: [String: Any] = [
                "discovered": summary.discovered,
                "imported": summary.imported,
                "skipped": summary.skipped,
                "savedPapers": store.papers.count,
                "collections": store.collections.count,
                "tags": store.tags.count,
                "collectionCountsSorted": counts,
                "readOnlyPDFReferences": store.papers.flatMap(\.attachments).filter(\.isReadOnlyReference).count,
                "readablePDFReferences": store.papers.flatMap(\.attachments).filter { !$0.missing }.count,
                "warnings": summary.warnings
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
