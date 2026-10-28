import CryptoKit
import Foundation

/// Versioned backups contain metadata and optional file bytes. Extraction never
/// trusts an archive pathname as a filesystem destination.
enum PortableBackupService {
    private struct Manifest: Codable {
        var format = "papermanager"
        var version = 2
        var includesFiles = false
        var files: [FileRecord] = []
    }
    private struct FileRecord: Codable {
        var paperID: UUID
        var itemID: UUID
        var annotationImage: Bool
        var entry: String
        var byteCount: Int64
        var sha256: String
    }
    private static let maximumFileSize: Int64 = 512 * 1024 * 1024
    private static let maximumTotalSize: Int64 = 20 * 1024 * 1024 * 1024

    static func write(snapshot: LibrarySnapshot, to destination: URL, includeFiles: Bool) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PaperManagerError.message("备份目标必须是普通文件，不能替换目录或符号链接。")
            }
        }
        let staging = manager.temporaryDirectory.appendingPathComponent("PaperManager-Backup-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging.appendingPathComponent("files"), withIntermediateDirectories: false)
        var manifest = Manifest(includesFiles: includeFiles)
        var total: Int64 = 0

        func copyFile(_ source: URL, paperID: UUID, itemID: UUID, annotationImage: Bool) throws {
            if Task.isCancelled { throw CancellationError() }
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard sourceValues.isRegularFile == true, let size = sourceValues.fileSize,
                  size <= maximumFileSize, total + Int64(size) <= maximumTotalSize else {
                throw PaperManagerError.message("备份文件不可读或超出大小限制：\(source.lastPathComponent)")
            }
            let suffix = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let role = annotationImage ? "image" : "attachment"
            let name = "\(paperID.uuidString)-\(role)-\(itemID.uuidString)" + (suffix.isEmpty ? "" : ".\(suffix.prefix(12))")
            let entry = "files/\(name)"
            let copied = staging.appendingPathComponent(entry)
            try manager.copyItem(at: source, to: copied)
            let copiedSize = Int64(try copied.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard copiedSize <= maximumFileSize, total + copiedSize <= maximumTotalSize else {
                throw PaperManagerError.message("复制过程中备份文件大小超出限制。")
            }
            total += copiedSize
            manifest.files.append(FileRecord(paperID: paperID, itemID: itemID, annotationImage: annotationImage,
                                             entry: entry, byteCount: copiedSize, sha256: try digest(copied)))
        }

        if includeFiles {
            for paper in snapshot.papers {
                for attachment in paper.attachments {
                    try attachment.withResolvedURL { source in
                        try copyFile(source, paperID: paper.id, itemID: attachment.id, annotationImage: false)
                    }
                }
                for annotation in paper.annotations {
                    if let path = annotation.imageFilePath, !path.isEmpty {
                        try copyFile(URL(fileURLWithPath: path), paperID: paper.id, itemID: annotation.id, annotationImage: true)
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Native v2 snapshots use Foundation's lossless reference-date number.
        // The separate legacy JSON format continues to use ISO-8601 strings.
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(snapshot).write(to: staging.appendingPathComponent("snapshot.json"))
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        // The final rename happens only after ZIP has finished successfully.
        let temporaryArchive = destination.deletingLastPathComponent().appendingPathComponent(".PaperManager-\(UUID()).zip")
        defer { try? manager.removeItem(at: temporaryArchive) }
        try run("/usr/bin/zip", arguments: ["-q", "-r", temporaryArchive.path, "."], directory: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporaryArchive)
        } else {
            try manager.moveItem(at: temporaryArchive, to: destination)
        }
    }

    static func read(from source: URL, filesDirectory: URL? = nil) throws -> LibrarySnapshot {
        let manifestData = try member("manifest.json", in: source, maximumBytes: 4 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.format == "papermanager", manifest.version == 2,
              manifest.files.count <= 100_000 else {
            throw PaperManagerError.message("不支持这个 PaperManager 备份版本。")
        }
        let data = try member("snapshot.json", in: source, maximumBytes: 32 * 1024 * 1024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        try validateSnapshot(snapshot)
        let expectedItemKeys = Set(snapshot.papers.flatMap { paper in
            paper.attachments.map { "\(paper.id)/\($0.id)/false" }
                + paper.annotations.filter { $0.imageFilePath?.isEmpty == false }.map { "\(paper.id)/\($0.id)/true" }
        })
        let declaredItemKeys = Set(manifest.files.map { "\($0.paperID)/\($0.itemID)/\($0.annotationImage)" })
        guard manifest.includesFiles ? declaredItemKeys == expectedItemKeys : manifest.files.isEmpty else { throw invalidArchive() }
        var paths = Set<String>()
        var itemKeys = Set<String>()
        var total: Int64 = 0
        for record in manifest.files {
            let components = record.entry.split(separator: "/", omittingEmptySubsequences: false)
            let key = "\(record.paperID)/\(record.itemID)/\(record.annotationImage)"
            let role = record.annotationImage ? "image" : "attachment"
            let baseName = "\(record.paperID)-\(role)-\(record.itemID)"
            let filename = components.last.map(String.init) ?? ""
            let suffix = filename.hasPrefix(baseName + ".") ? String(filename.dropFirst(baseName.count + 1)) : ""
            guard components.count == 2, components[0] == "files", !components[1].isEmpty,
                  filename == baseName || (filename.hasPrefix(baseName + ".") && !suffix.isEmpty && suffix.count <= 12
                      && suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })),
                  paths.insert(record.entry).inserted, itemKeys.insert(key).inserted,
                  record.byteCount >= 0, record.byteCount <= maximumFileSize,
                  record.sha256.count == 64, record.sha256.allSatisfy(\.isHexDigit),
                  let paper = snapshot.papers.first(where: { $0.id == record.paperID }) else { throw invalidArchive() }
            if record.annotationImage {
                guard paper.annotations.contains(where: { $0.id == record.itemID }) else { throw invalidArchive() }
            } else {
                guard paper.attachments.contains(where: { $0.id == record.itemID }) else { throw invalidArchive() }
            }
            total += record.byteCount
            guard total <= maximumTotalSize else { throw invalidArchive() }
        }
        guard !manifest.files.isEmpty else { return snapshot }
        let manager = FileManager.default
        let root: URL
        if let filesDirectory { root = filesDirectory }
        else {
            root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PaperManager/RestoredFiles/\(UUID())", isDirectory: true)
        }
        guard !manager.fileExists(atPath: root.path) else {
            throw PaperManagerError.message("恢复文件目录必须是一个尚不存在的新目录。")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for record in manifest.files {
                if Task.isCancelled { throw CancellationError() }
                let suffix = URL(fileURLWithPath: record.entry).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                let role = record.annotationImage ? "image" : "attachment"
                let file = root.appendingPathComponent("\(record.paperID)-\(role)-\(record.itemID)" + (suffix.isEmpty ? "" : ".\(suffix.prefix(12))"))
                try extract(record.entry, from: source, to: file, maximumBytes: record.byteCount)
                guard try digest(file) == record.sha256.lowercased(),
                      Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == record.byteCount else {
                    throw PaperManagerError.message("备份中的文件校验失败。")
                }
                guard let paperIndex = snapshot.papers.firstIndex(where: { $0.id == record.paperID }) else { throw invalidArchive() }
                if record.annotationImage {
                    guard let index = snapshot.papers[paperIndex].annotations.firstIndex(where: { $0.id == record.itemID }) else { throw invalidArchive() }
                    snapshot.papers[paperIndex].annotations[index].imageFilePath = file.path
                } else {
                    guard let index = snapshot.papers[paperIndex].attachments.firstIndex(where: { $0.id == record.itemID }) else { throw invalidArchive() }
                    snapshot.papers[paperIndex].attachments[index].filePath = file.path
                    snapshot.papers[paperIndex].attachments[index].bookmarkData = try? file.bookmarkData(options: .withSecurityScope)
                    snapshot.papers[paperIndex].attachments[index].isReadOnlyReference = false
                    snapshot.papers[paperIndex].attachments[index].missing = false
                }
            }
            return snapshot
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    private static func invalidArchive() -> PaperManagerError { .message("备份清单无效或文件关系不完整。") }

    static func validateSnapshot(_ snapshot: LibrarySnapshot) throws {
        let paperIDs = Set(snapshot.papers.map(\.id))
        let collectionIDs = Set(snapshot.collections.map(\.id))
        let tagIDs = Set(snapshot.tags.map(\.id))
        let templates = snapshot.metadataTemplates ?? []
        guard snapshot.schemaVersion == LibrarySnapshot.supportedSchemaVersion, Set(templates.map(\.id)).count == templates.count,
              paperIDs.count == snapshot.papers.count, collectionIDs.count == snapshot.collections.count,
              tagIDs.count == snapshot.tags.count else { throw invalidArchive() }
        let parents = Dictionary(uniqueKeysWithValues: snapshot.collections.map { ($0.id, $0.parentID) })
        for collection in snapshot.collections {
            var seen: Set<UUID> = [collection.id]
            var parent = collection.parentID
            while let id = parent {
                guard collectionIDs.contains(id), seen.insert(id).inserted, seen.count <= 3 else { throw invalidArchive() }
                parent = parents[id] ?? nil
            }
        }
        for paper in snapshot.papers {
            guard Set(paper.attachments.map(\.id)).count == paper.attachments.count,
                  Set(paper.annotations.map(\.id)).count == paper.annotations.count,
                  Set(paper.customFields.map(\.id)).count == paper.customFields.count,
                  Set(paper.collectionIDs).isSubset(of: collectionIDs), Set(paper.tagIDs).isSubset(of: tagIDs) else { throw invalidArchive() }
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func member(_ entry: String, in source: URL, maximumBytes: Int64) throws -> Data {
        var data = Data()
        try stream(entry, from: source, maximumBytes: maximumBytes) { data.append($0) }
        return data
    }

    private static func extract(_ entry: String, from source: URL, to destination: URL, maximumBytes: Int64) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw invalidArchive() }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try stream(entry, from: source, maximumBytes: maximumBytes) { try file.write(contentsOf: $0) }
    }

    private static func stream(_ entry: String, from source: URL, maximumBytes: Int64, consume: (Data) throws -> Void) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", source.path, entry]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            var size: Int64 = 0
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                guard size <= maximumBytes, !Task.isCancelled else { throw invalidArchive() }
                try consume(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw invalidArchive() }
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
    }

    private static func run(_ executable: String, arguments: [String], directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PaperManagerError.message("无法写入 ZIP 备份。") }
    }
}
