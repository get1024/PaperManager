import Foundation

enum BackupService {
    static func writeBackup(snapshot: LibrarySnapshot, to url: URL, includeFiles: Bool = true) throws {
        var destination = url
        if destination.pathExtension.isEmpty {
            destination.appendPathExtension("papermanager")
        }
        if destination.pathExtension.lowercased() != "json" {
            try PortableBackupService.write(snapshot: snapshot, to: destination, includeFiles: includeFiles)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: destination, options: [.atomic])
    }

    static func readBackup(from url: URL, filesDirectory: URL? = nil) throws -> LibrarySnapshot {
        let file = try FileHandle(forReadingFrom: url)
        let signature = try file.read(upToCount: 4)
        try file.close()
        if signature?.starts(with: [0x50, 0x4b]) == true {
            return try PortableBackupService.read(from: url, filesDirectory: filesDirectory)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        try PortableBackupService.validateSnapshot(snapshot)
        return snapshot
    }
}
