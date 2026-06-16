import Foundation

enum BackupService {
    static func writeBackup(snapshot: LibrarySnapshot, to url: URL) throws {
        var destination = url
        if destination.pathExtension.isEmpty {
            destination.appendPathExtension("papermanager")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: destination, options: [.atomic])
    }

    static func readBackup(from url: URL) throws -> LibrarySnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibrarySnapshot.self, from: data)
    }
}
