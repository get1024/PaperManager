import Darwin
import Foundation

enum FileLibraryDecision: String, Codable, Hashable {
    case notAsked, declined, configured, legacyConflict
}

enum FileLibraryLayout: String, Codable, CaseIterable, Identifiable {
    case separate, byPaper
    var id: String { rawValue }
    var label: String { PMLocalization.text(self == .separate ? "PDF 与附件分开" : "每篇文献一个文件夹") }
}

struct FileLibraryPreferences: Codable, Hashable {
    var decision: FileLibraryDecision = .notAsked
    var rootPath: String = ""
    var rootBookmark: Data?
    var layout: FileLibraryLayout = .separate
    var legacyConflictPaths: [String] = []
}

enum FileLibraryAvailability: String {
    case notAsked, declined, configured, unavailable, legacyConflict
    var label: String {
        switch self {
        case .notAsked: return PMLocalization.text("尚未设置")
        case .declined: return PMLocalization.text("保留文件原位置")
        case .configured: return PMLocalization.text("可用")
        case .unavailable: return PMLocalization.text("文件夹不可访问，请重新授权")
        case .legacyConflict: return PMLocalization.text("发现两个旧文件夹，请选择今后的文件库")
        }
    }
}

struct FileLibraryStatus {
    var availability: FileLibraryAvailability
    var rootURL: URL?
    var message: String
    var isAvailable: Bool { availability == .configured }
}

struct FilePlacementPlan {
    var source: URL
    var destination: URL
    var action: PDFOrganizationMode
    var authorizedRoot: URL?
    fileprivate var identity: FileLibraryFileIdentity
    var changesLocation: Bool { source.path != destination.path && action != .none }
}

struct FilePlacementReceipt {
    let plan: FilePlacementPlan
    fileprivate let writtenIdentity: FileLibraryFileIdentity?
    fileprivate var movedByRename = false

    /// Restore a moved source before removing our new copy. Never replace a
    /// source or destination changed by another operation in the meantime.
    func rollback(preservingDestination: Bool = false) throws {
        guard plan.changesLocation, let writtenIdentity else { return }
        let access = plan.authorizedRoot?.startAccessingSecurityScopedResource() ?? false
        defer { if access { plan.authorizedRoot?.stopAccessingSecurityScopedResource() } }
        guard try FileLibraryFileIdentity.read(plan.destination) == writtenIdentity else {
            throw PaperManagerError.message("文件已被其他操作更改；已保留现有文件，请检查文件库。")
        }
        if plan.action == .move {
            guard !FileManager.default.fileExists(atPath: plan.source.path) else {
                throw PaperManagerError.message("原位置出现了其他文件；已保留文件库副本，未覆盖原位置。")
            }
            if movedByRename && !preservingDestination {
                guard renamex_np(plan.destination.path, plan.source.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return
            }
            try FileLibraryService.copyNoOverwrite(from: plan.destination, to: plan.source)
        }
        if !preservingDestination { try FileManager.default.removeItem(at: plan.destination) }
    }
}

struct FileOperationSummary {
    var completed = 0
    var unchanged = 0
    var messages: [String] = []
    var text: String {
        let summary = "已处理 \(completed) 个文件，\(unchanged) 个保持原位"
        return messages.isEmpty ? summary : summary + "。" + messages.joined(separator: "；")
    }
}

struct FileOperationProgress {
    var total = 0
    var completed = 0
    var unchanged = 0
    var failed = 0
    var cancelled = false
    var isRunning = true
    var messages: [String] = []
    var processed: Int { completed + unchanged + failed }
}

fileprivate struct FileLibraryFileIdentity: Equatable {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var seconds: Int
    var nanoseconds: Int

    static func read(_ url: URL) throws -> Self {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw PaperManagerError.message("文件不存在或不是可读取的普通文件：\(url.lastPathComponent)")
        }
        return Self(device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
                    seconds: metadata.st_mtimespec.tv_sec, nanoseconds: metadata.st_mtimespec.tv_nsec)
    }
}

enum FileLibraryService {
    /// Old settings are interpreted without rewriting a library on load. Two
    /// distinct old roots require an explicit choice, rather than picking one.
    static func preferences(for settings: AppSettings) -> FileLibraryPreferences {
        if let saved = settings.fileLibrary { return saved }
        let paths = [settings.pdfOrganizationFolder, settings.browserUploadFolder]
            .compactMap(\.nilIfBlank).map { canonicalURL(URL(fileURLWithPath: $0)).path }
        let distinct = paths.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count > 1 {
            return FileLibraryPreferences(decision: .legacyConflict, legacyConflictPaths: distinct)
        }
        if let path = distinct.first { return FileLibraryPreferences(decision: .configured, rootPath: path) }
        return FileLibraryPreferences()
    }

    static func authorizedPreferences(root: URL, layout: FileLibraryLayout = .separate) throws -> FileLibraryPreferences {
        let root = canonicalURL(root)
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        try requireDirectory(root)
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileLibraryPreferences(decision: .configured, rootPath: root.path, rootBookmark: bookmark, layout: layout)
    }

    static func status(for settings: AppSettings) -> FileLibraryStatus {
        let configuration = preferences(for: settings)
        switch configuration.decision {
        case .notAsked: return FileLibraryStatus(availability: .notAsked, message: FileLibraryAvailability.notAsked.label)
        case .declined: return FileLibraryStatus(availability: .declined, message: FileLibraryAvailability.declined.label)
        case .legacyConflict: return FileLibraryStatus(availability: .legacyConflict, message: FileLibraryAvailability.legacyConflict.label)
        case .configured:
            do {
                let root = try resolvedRoot(configuration)
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                try requireDirectory(root)
                return FileLibraryStatus(availability: .configured, rootURL: root, message: FileLibraryAvailability.configured.label)
            } catch {
                return FileLibraryStatus(availability: .unavailable,
                                         rootURL: configuration.rootPath.nilIfBlank.map { URL(fileURLWithPath: $0) },
                                         message: error.localizedDescription)
            }
        }
    }

    static func withRoot<T>(settings: AppSettings, _ body: (URL) throws -> T) throws -> T {
        let configuration = preferences(for: settings)
        guard configuration.decision == .configured else {
            throw PaperManagerError.message(configuration.decision == .legacyConflict
                ? "请先在设置中解决旧文件库文件夹冲突。" : "请先在设置中授权文件库文件夹。")
        }
        let root = try resolvedRoot(configuration)
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        try requireDirectory(root)
        return try body(root)
    }

    /// A local import follows Local File Action. Explicit organization also
    /// relocates already-managed files when that action is Do Nothing.
    static func plan(source: URL, paper: Paper, snapshot: LibrarySnapshot, attachmentID: UUID? = nil,
                     explicitOrganization: Bool = false, kind: AttachmentKind? = nil, managedImport: Bool = false) throws -> FilePlacementPlan {
        let source = canonicalURL(source)
        let identity = try FileLibraryFileIdentity.read(source)
        var action: PDFOrganizationMode = managedImport ? .copy : snapshot.settings.pdfOrganizationMode
        if explicitOrganization,
           let root = status(for: snapshot.settings).rootURL, status(for: snapshot.settings).isAvailable,
           isWithin(source, root: root) { action = .move }
        if action == .none { return FilePlacementPlan(source: source, destination: source, action: .none, identity: identity) }
        try protectSource(source, paperID: paper.id, attachmentID: attachmentID, snapshot: snapshot, moving: action == .move)
        return try withRoot(settings: snapshot.settings) { root in
            let grouping = groupingComponents(paper: paper, snapshot: snapshot)
            var directory = root
            let layout = preferences(for: snapshot.settings).layout
            let isPrimaryPDF = (kind ?? (source.isPDF ? .pdf : .file)) == .pdf && (attachmentID == nil || paper.primaryPDF?.id == attachmentID)
            if layout == .separate, !isPrimaryPDF {
                directory.appendPathComponent("Attachments", isDirectory: true)
            }
            for component in grouping { directory.appendPathComponent(component, isDirectory: true) }
            if layout == .byPaper || !isPrimaryPDF {
                directory.appendPathComponent(paper.id.uuidString, isDirectory: true)
            }
            let stem = snapshot.settings.autoRenamePDFs ? filenameStem(paper: paper, template: snapshot.settings.pdfRenameTemplate, fallback: source.deletingPathExtension().lastPathComponent) : source.deletingPathExtension().lastPathComponent
            let named = directory.appendingPathComponent(stem.sanitizedFileName()).appendingPathExtension(source.pathExtension)
            let destination = uniqueDestination(named, source: source)
            try requireSafeDestination(destination, root: root)
            return FilePlacementPlan(source: source, destination: destination, action: action, authorizedRoot: root, identity: identity)
        }
    }

    static func renamePlan(attachment: Attachment, paper: Paper, snapshot: LibrarySnapshot) throws -> FilePlacementPlan {
        guard snapshot.settings.autoRenamePDFs else { throw PaperManagerError.message("请先在设置中启用重命名规则。") }
        let source = try attachment.resolvedURL().resolvingSymlinksInPath().standardizedFileURL
        try protectSource(source, paperID: paper.id, attachmentID: attachment.id, snapshot: snapshot, moving: true)
        let stem = filenameStem(paper: paper, template: snapshot.settings.pdfRenameTemplate, fallback: source.deletingPathExtension().lastPathComponent)
        let destination = uniqueDestination(source.deletingLastPathComponent().appendingPathComponent(stem.sanitizedFileName()).appendingPathExtension(source.pathExtension), source: source)
        return FilePlacementPlan(source: source, destination: destination, action: .move, identity: try FileLibraryFileIdentity.read(source))
    }

    static func execute(_ plan: FilePlacementPlan, checkCancellation: () throws -> Void = {}) throws -> FilePlacementReceipt {
        try checkCancellation()
        guard plan.changesLocation else { return FilePlacementReceipt(plan: plan, writtenIdentity: nil) }
        let access = plan.authorizedRoot?.startAccessingSecurityScopedResource() ?? false
        defer { if access { plan.authorizedRoot?.stopAccessingSecurityScopedResource() } }
        guard try FileLibraryFileIdentity.read(plan.source) == plan.identity else {
            throw PaperManagerError.message("源文件在操作前发生更改，请重新执行。")
        }
        if let root = plan.authorizedRoot { try requireSafeDestination(plan.destination, root: root) }
        try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if plan.action == .move {
            if renamex_np(plan.source.path, plan.destination.path, UInt32(RENAME_EXCL)) == 0 {
                return FilePlacementReceipt(plan: plan, writtenIdentity: try FileLibraryFileIdentity.read(plan.destination), movedByRename: true)
            }
            guard errno == EXDEV else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        // Reserve the destination with O_EXCL/O_NOFOLLOW. Neither an existing
        // file nor a dangling link created after planning can be overwritten.
        try copyNoOverwrite(from: plan.source, to: plan.destination, checkCancellation: checkCancellation)
        let identity = try FileLibraryFileIdentity.read(plan.destination)
        do {
            guard try FileLibraryFileIdentity.read(plan.source) == plan.identity else {
                throw PaperManagerError.message("源文件在复制期间发生更改，操作已取消。")
            }
            try checkCancellation()
            if plan.action == .move { try FileManager.default.removeItem(at: plan.source) }
            return FilePlacementReceipt(plan: plan, writtenIdentity: identity)
        } catch {
            // Only remove our unchanged copy. If removal fails, retain both
            // paths rather than deleting a source or overwriting newer data.
            if (try? FileLibraryFileIdentity.read(plan.destination)) == identity {
                try? FileManager.default.removeItem(at: plan.destination)
            }
            throw error
        }
    }

    static func canonicalURL(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
    static func resolvedCanonicalURL(for attachment: Attachment) -> URL {
        canonicalURL((try? attachment.resolvedURL()) ?? attachment.url)
    }
    static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = canonicalURL(url).path, parent = canonicalURL(root).path
        return path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func resolvedRoot(_ configuration: FileLibraryPreferences) throws -> URL {
        guard let path = configuration.rootPath.nilIfBlank else { throw PaperManagerError.message("尚未配置文件库文件夹。") }
        if let bookmark = configuration.rootBookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw PaperManagerError.message("文件库授权已过期，请在设置中重新授权。") }
            return canonicalURL(url)
        }
        // Legacy path settings were already selected by this app's user. New
        // selections always store a bookmark; never invent authorization.
        return canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func requireDirectory(_ root: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path), FileManager.default.isWritableFile(atPath: root.path) else {
            throw PaperManagerError.message("文件库文件夹不可访问，请在设置中重新选择或授权。")
        }
    }

    private static func protectSource(_ source: URL, paperID: UUID, attachmentID: UUID?, snapshot: LibrarySnapshot, moving: Bool) throws {
        guard moving else { return }
        for paper in snapshot.papers {
            for attachment in paper.attachments where resolvedCanonicalURL(for: attachment).path == source.path {
                if attachment.isReadOnlyReference { throw PaperManagerError.message("原版文件是只读引用，不能移动或重命名。请使用复制。") }
                if paper.id != paperID || (attachmentID != nil && attachment.id != attachmentID) {
                    throw PaperManagerError.message("文件还被其他文献或附件引用，不能移动或重命名。请使用复制。")
                }
            }
        }
    }

    private static func groupingComponents(paper: Paper, snapshot: LibrarySnapshot) -> [String] {
        switch snapshot.settings.pdfSubfolderGrouping {
        case .none: return []
        case .year: return [paper.year.map(String.init) ?? "Unsorted"]
        case .authorInitial:
            guard !paper.authors.isEmpty else { return ["Unsorted"] }
            let initial = String(CitekeyGenerator.firstAuthorLastName(paper).prefix(1)).uppercased().sanitizedFileName(fallback: "Unsorted")
            return [initial]
        case .collection:
            var order: [PaperCollection] = [], seen = Set<UUID>()
            func append(parent: UUID?) {
                for collection in snapshot.collections.children(of: parent) where seen.insert(collection.id).inserted {
                    order.append(collection); append(parent: collection.id)
                }
            }
            append(parent: nil)
            guard let first = order.first(where: { paper.collectionIDs.contains($0.id) }) else { return ["Unsorted"] }
            return snapshot.collections.path(for: first.id).split(separator: "/").map { String($0).sanitizedFileName(fallback: "Unsorted") }
        }
    }

    static func filenameStem(paper: Paper, template: String, fallback: String) -> String {
        let author = paper.authors.isEmpty ? "" : CitekeyGenerator.firstAuthorLastName(paper)
        let values = ["citekey": paper.citekey, "auth": author.lowercased(), "author": author,
                      "authorLower": author.lowercased(), "authorInitial": String(author.prefix(1)).uppercased(),
                      "authorEtAl": paper.authors.count > 1 ? author + " et al." : author,
                      "authEtAl": paper.authors.count > 1 ? author + " et al." : author,
                      "year": paper.year.map(String.init) ?? "", "year2": paper.year.map { String(String($0).suffix(2)) } ?? "",
                      "title": paper.title, "titleWord": paper.title.isEmpty ? "" : CitekeyGenerator.firstMeaningfulTitleWord(paper.title),
                      "journal": paper.journal, "doi": paper.doi]
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9]*)(?::([0-9]+))?\}\}|\{([A-Za-z][A-Za-z0-9]*)(?::([0-9]+))?\}"#) else { return fallback }
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let group = match.range(at: 1).location == NSNotFound ? 3 : 1
            guard let token = Range(match.range(at: group), in: template), let value = values[String(template[token])], !value.trimmed.isEmpty,
                  let full = Range(match.range, in: result) else { return fallback }
            var replacement = value
            if let lengthRange = Range(match.range(at: group + 1), in: template), let length = Int(template[lengthRange]) {
                replacement = String(value.prefix(length))
            }
            result.replaceSubrange(full, with: replacement)
        }
        return result.nilIfBlank?.sanitizedFileName(fallback: fallback) ?? fallback
    }

    private static func uniqueDestination(_ desired: URL, source: URL) -> URL {
        if desired.standardizedFileURL.path == source.path { return source }
        var target = desired, suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let stem = desired.deletingPathExtension().lastPathComponent + " \(suffix)"
            target = desired.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(desired.pathExtension)
            suffix += 1
        }
        return target
    }

    private static func requireSafeDestination(_ destination: URL, root: URL) throws {
        let lexical = destination.standardizedFileURL
        let root = canonicalURL(root)
        guard lexical.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
            throw PaperManagerError.message("目标路径经过符号链接或超出文件库，操作已停止。")
        }
        var cursor = root
        for component in lexical.pathComponents.dropFirst(root.pathComponents.count) {
            cursor.appendPathComponent(component)
            var metadata = stat()
            if lstat(cursor.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFLNK {
                throw PaperManagerError.message("目标路径经过符号链接，操作已停止。")
            }
        }
    }

    fileprivate static func copyNoOverwrite(from source: URL, to destination: URL, checkCancellation: () throws -> Void = {}) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(output) }
        do {
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try checkCancellation()
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if count == 0 { break }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                        offset += written
                    }
                }
            }
            guard fsync(output) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
