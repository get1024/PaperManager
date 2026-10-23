import CryptoKit
import Foundation

@main
struct LatticeArchiveTests {
    @MainActor
    static func main() {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var failures = 0
        var checks = 0
        func check(_ name: String, _ body: () throws -> Void) {
            checks += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        func require(_ condition: @autoclosure () -> Bool) throws {
            if !condition() { throw PaperManagerError.message("assertion failed") }
        }
        let valid = directory.appendingPathComponent("valid.lattice")
        check("archive fields, source citekey, rating, notes, page/bounds, extras") {
            let result = try LatticeArchiveService.readArchive(at: valid)
            let paper = result.snapshot.papers[0]
            try require(paper.citekey == "OriginalSourceKey" && paper.rating == 4 && paper.notes == "fixture note")
            try require(paper.abstract == "fixture abstract" && paper.eprint == "2601.01234" && paper.paperType == .preprint)
            try require(paper.customFields.first?.key == "fixtureExtra" && paper.customFields.first?.value == "kept")
            try require(paper.annotations.count == 1 && paper.annotations[0].page == 2 && paper.annotations[0].note == "fixture annotation note")
            try require(paper.annotations[0].bounds?.width == 3.5 && paper.annotations[0].colorHex == "#FFBABA")
            let rerun = try LatticeArchiveService.readArchive(at: valid)
            try require(paper.annotations[0].id == rerun.snapshot.papers[0].annotations[0].id)
        }
        check("fractional ISO8601 decoder") {
            let paper = try LatticeArchiveService.readArchive(at: directory.appendingPathComponent("fractional.lattice")).snapshot.papers[0]
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expected = formatter.date(from: "2026-07-29T06:21:23.123Z")!
            try require(abs(paper.dateAdded.timeIntervalSince(expected)) < 0.00001)
        }
        check("independent import, full saved metadata, raw sidecar") {
            let store = LibraryStore(persistenceURL: directory.appendingPathComponent("independent/library.json"))
            let result = try LatticeArchiveService.importArchive(at: valid, into: store)
            let saved = try LatticeArchiveService.readSnapshot(at: store.persistenceURL)
            try require(saved.papers == result.snapshot.papers && saved.papers[0].dateAdded == result.snapshot.papers[0].dateAdded)
            let raw = try Data(contentsOf: directory.appendingPathComponent("independent/library.lattice-source/data.json"))
            try require(raw == result.libraryData)
        }
        check("explicit PDF copy preserves archive, bytes and source display name") {
            let archive = directory.appendingPathComponent("with-pdf.lattice")
            let before = try Data(contentsOf: archive)
            let destination = directory.resolvingSymlinksInPath().appendingPathComponent("copied-pdfs")
            let result = try LatticeArchiveService.readArchive(at: archive, materializePDFsTo: destination)
            let attachment = result.snapshot.papers[0].primaryPDF!
            try require(!attachment.isReadOnlyReference && attachment.displayName == "Fixture original name.pdf")
            let copiedBytes = try Data(contentsOf: attachment.url)
            let archiveAfter = try Data(contentsOf: archive)
            try require(copiedBytes == Data("%PDF-1.4\nfixture payload\n%%EOF\n".utf8))
            try require(archiveAfter == before)
            let store = LibraryStore(persistenceURL: directory.appendingPathComponent("copied-library/library.json"))
            try LatticeArchiveService.persist(result, into: store)
            try require(store.papers[0].primaryPDF?.filePath == attachment.filePath)
        }
        check("existing copy directory and symlinked parents cannot be overwritten") {
            let archive = directory.appendingPathComponent("with-pdf.lattice")
            let copied = directory.resolvingSymlinksInPath().appendingPathComponent("copied-pdfs")
            var rejectedExisting = false
            do { _ = try LatticeArchiveService.readArchive(at: archive, materializePDFsTo: copied) } catch { rejectedExisting = true }
            let link = directory.appendingPathComponent("copy-symlink")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copied)
            var rejectedLink = false
            do { _ = try LatticeArchiveService.readArchive(at: archive, materializePDFsTo: link.appendingPathComponent("child")) } catch { rejectedLink = true }
            try require(rejectedExisting && rejectedLink && !FileManager.default.fileExists(atPath: copied.appendingPathComponent("child").path))
        }
        check("explicit secondary members retain identities, dates, annotation metadata and exact bytes through restore") {
            let source = directory.appendingPathComponent("with-attachments.lattice"), before = try Data(contentsOf: source)
            let output = directory.resolvingSymlinksInPath().appendingPathComponent("copied-secondary")
            let metadata = try LatticeArchiveService.readArchive(at: source)
            try require(metadata.attachmentFileCount == 2 && metadata.snapshot.papers[0].attachments.count == 2)
            try require(metadata.snapshot.papers[0].attachments.allSatisfy { $0.missing && $0.isReadOnlyReference })
            let result = try LatticeArchiveService.readArchive(at: source, materializePDFsTo: output)
            let attachments = result.snapshot.papers[0].attachments
            let expected = [Data("first secondary payload".utf8) + Data([0, 255]), Data("second secondary payload".utf8)]
            try require(attachments.count == 2 && Set(attachments.map(\.filePath)).count == 2)
            for (attachment, bytes) in zip(attachments, expected) {
                try require(attachment.kind == .file && attachment.displayName == "same name.txt" && !attachment.missing && !attachment.isReadOnlyReference)
                let actual = try Data(contentsOf: attachment.url)
                try require(SHA256.hash(data: actual) == SHA256.hash(data: bytes))
            }
            try require(attachments[0].id == UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
            let dateFormatter = ISO8601DateFormatter(); dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try require(attachments[0].addedAt == dateFormatter.date(from: "2026-07-30T02:03:04.125Z"))
            try require(result.snapshot.papers[0].annotations[0].note == "fixture annotation note")
            let store = LibraryStore(persistenceURL: directory.appendingPathComponent("secondary-restored/library.json"))
            try LatticeArchiveService.persist(result, into: store)
            let restored = try LatticeArchiveService.readSnapshot(at: store.persistenceURL)
            try require(restored.papers[0].attachments.map(\.id) == attachments.map(\.id))
            for (attachment, bytes) in zip(restored.papers[0].attachments, expected) {
                let actual = try Data(contentsOf: attachment.url)
                try require(SHA256.hash(data: actual) == SHA256.hash(data: bytes))
            }
            let after = try Data(contentsOf: source)
            try require(after == before)
        }
        check("metadata-only secondary attachments retain identity and date without inventing accessible files") {
            let result = try LatticeArchiveService.readArchive(at: directory.appendingPathComponent("metadata-only-attachment.lattice"))
            let attachment = result.snapshot.papers[0].attachments[0]
            try require(attachment.missing && attachment.isReadOnlyReference && attachment.displayName == "same name.txt")
            try require(attachment.id == UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
            try require(!FileManager.default.fileExists(atPath: attachment.filePath) && result.attachmentFileCount == 0)
        }
        for name in ["missing-attachment", "attachment-traversal", "attachment-wildcard", "attachment-duplicate-id",
                     "attachment-duplicate-payload", "attachment-bad-count", "attachment-symlink", "attachment-corrupt-payload"] {
            check("reject \(name) without partial extracted bytes or published restore") {
                let target = directory.resolvingSymlinksInPath().appendingPathComponent("reject-\(name)-files")
                let store = LibraryStore(persistenceURL: directory.appendingPathComponent("reject-\(name)/library.json"))
                var rejected = false
                do { _ = try LatticeArchiveService.importArchive(at: directory.appendingPathComponent("\(name).lattice"), into: store, materializePDFsTo: target) }
                catch { rejected = true }
                try require(rejected && store.papers.isEmpty && !FileManager.default.fileExists(atPath: store.persistenceURL.path))
                try require(!FileManager.default.fileExists(atPath: target.path))
            }
        }
        for name in ["bad-json", "duplicate-id", "missing-reference", "bad-count", "bad-type", "duplicate-member", "traversal", "oversized-json", "bad-local-header"] {
            check("reject \(name) without writing target") {
                let target = directory.appendingPathComponent("reject-\(name)/library.json")
                let store = LibraryStore(persistenceURL: target)
                var rejected = false
                do { _ = try LatticeArchiveService.importArchive(at: directory.appendingPathComponent("\(name).lattice"), into: store) }
                catch { rejected = true }
                try require(rejected && !FileManager.default.fileExists(atPath: target.path))
            }
        }
        print("Archive checks: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
