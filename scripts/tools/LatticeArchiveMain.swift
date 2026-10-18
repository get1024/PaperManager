import Foundation

@main
struct LatticeArchiveMain {
    @MainActor
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let usage = "Usage: lattice-archive.sh inspect ARCHIVE [FALLBACK_SNAPSHOT] | import ARCHIVE DESTINATION_JSON [FALLBACK_SNAPSHOT] [--copy-pdfs NEW_DIRECTORY]"
            if arguments == ["--help"] || arguments == ["help"] { print(usage); return }
            guard arguments.count >= 2, arguments[0] == "inspect" || arguments[0] == "import" else {
                throw PaperManagerError.message(usage)
            }
            let archive = URL(fileURLWithPath: arguments[1])
            let result: LatticeArchiveResult
            if arguments[0] == "inspect" {
                let fallback = try arguments.count > 2 ? LatticeArchiveService.readSnapshot(at: URL(fileURLWithPath: arguments[2])) : nil
                result = try LatticeArchiveService.readArchive(at: archive, fallbackSnapshot: fallback)
            } else {
                guard arguments.count >= 3 else { throw PaperManagerError.message("Import needs an independent destination JSON path.") }
                var fallbackPath: String?
                var copyDirectory: URL?
                var index = 3
                while index < arguments.count {
                    if arguments[index] == "--copy-pdfs" {
                        guard index + 1 < arguments.count, copyDirectory == nil else {
                            throw PaperManagerError.message("--copy-pdfs needs one new destination directory.")
                        }
                        copyDirectory = URL(fileURLWithPath: arguments[index + 1])
                        index += 2
                    } else {
                        guard fallbackPath == nil, !arguments[index].hasPrefix("--") else {
                            throw PaperManagerError.message("Unknown import argument.")
                        }
                        fallbackPath = arguments[index]
                        index += 1
                    }
                }
                let store = LibraryStore(persistenceURL: URL(fileURLWithPath: arguments[2]))
                result = try LatticeArchiveService.importArchive(at: archive, into: store,
                    fallbackSnapshotURL: fallbackPath.map { URL(fileURLWithPath: $0) }, materializePDFsTo: copyDirectory)
            }
            let data = try JSONSerialization.data(withJSONObject: result.summary, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
