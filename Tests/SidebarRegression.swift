import Darwin
import Foundation

@main
@MainActor
struct SidebarRegression {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failures: [String] = []

    static func main() {
        run("Creation rejects missing parents and a fourth collection level", testCreation)
        run("Reparenting rejects cycles and checks the entire subtree depth", testReparenting)
        run("Sibling drag order is persisted in both movement directions", testCollectionOrder)
        run("Moving and deleting collections preserve paper identity and source files", testCollectionMembership)
        run("Tags reorder persistently and normalize order after deletion", testTagOrder)
        run("Custom tag colors normalize hex and reject invalid values", testTagColors)
        run("Malformed existing hierarchy cannot trigger recursive mutation", testMalformedHierarchy)
        for failure in failures { print("FAIL: \(failure)") }
        print("Sidebar regression: \(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS: \(name)") }
        catch { failures.append("\(name): \(error)") }
    }

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    private static func rejects(_ body: () throws -> Void) throws {
        do { try body() }
        catch { return }
        throw Failure(description: "Invalid mutation unexpectedly succeeded")
    }

    private static func fixture() throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperManagerSidebar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, LibraryStore(persistenceURL: root.appendingPathComponent("library.json")))
    }

    private static func testCreation() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.createCollection(name: "One")
        let second = try store.createCollection(name: "Two", parentID: first)
        let third = try store.createCollection(name: "Three", parentID: second)
        try expect(store.collectionDepth(id: third) == 3, "The third level was not created")
        let before = try Data(contentsOf: store.persistenceURL)
        try rejects { try store.createCollection(name: "Four", parentID: third) }
        try rejects { try store.createCollection(name: "Orphan", parentID: UUID()) }
        try expect(store.collections.count == 3, "An invalid creation changed the collection list")
        try expect(try Data(contentsOf: store.persistenceURL) == before, "An invalid creation rewrote the library")
        try expect(!store.canCreateCollection(parentID: third), "The UI still enables a fourth level")
    }

    private static func testReparenting() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.createCollection(name: "A")
        let child = try store.createCollection(name: "A child", parentID: first)
        let leaf = try store.createCollection(name: "A leaf", parentID: child)
        let other = try store.createCollection(name: "B")
        try expect(!store.moveCollection(id: first, toParentID: leaf, at: 0), "A cycle was accepted")
        try expect(!store.moveCollection(id: first, toParentID: other, at: 0), "Moving a three-level subtree under a root exceeded the limit")
        try expect(!store.moveCollection(id: child, toParentID: UUID(), at: 0), "A nonexistent destination was accepted")
        try expect(store.moveCollection(id: child, toParentID: other, at: 0), "A valid subtree move was rejected")
        try expect(store.collectionDepth(id: leaf) == 3, "A subtree move lost the leaf or computed the wrong depth")
        try expect(store.collections.first { $0.id == child }?.parentID == other, "The parent relationship was not updated")
    }

    private static func testCollectionOrder() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.createCollection(name: "A")
        let second = try store.createCollection(name: "B")
        let third = try store.createCollection(name: "C")
        try expect(store.moveCollection(id: first, toParentID: nil, at: 3), "Dragging down failed")
        try expect(store.collections.children(of: nil).map(\.id) == [second, third, first], "Downward insertion index was off by one")
        try expect(store.moveCollection(id: first, toParentID: nil, at: 0), "Dragging up failed")
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.collections.children(of: nil).map(\.id) == [first, second, third], "The custom order did not survive reload")
        store.deleteCollection(id: second)
        try expect(store.collections.children(of: nil).map(\.sortIndex) == [0, 1], "Deletion left a noncanonical sibling order")
    }

    private static func testCollectionMembership() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        let sourceData = Data("protected source fixture".utf8)
        try sourceData.write(to: source)
        let first = try store.createCollection(name: "A")
        let child = try store.createCollection(name: "Child", parentID: first)
        let second = try store.createCollection(name: "B")
        var paper = Paper(); paper.title = "Member"; paper.collectionIDs = [first, child, second]
        paper.attachments = [Attachment(kind: .pdf, filePath: source.path, displayName: "source.pdf", isReadOnlyReference: true)]
        store.addPaper(paper)
        try expect(store.moveCollection(id: child, toParentID: second, at: 0), "A valid move was rejected")
        try expect(store.paper(with: paper.id)?.collectionIDs == [first, child, second], "Reparenting changed paper membership IDs")
        store.deleteCollection(id: second)
        let saved = LibraryStore(persistenceURL: store.persistenceURL).paper(with: paper.id)!
        try expect(saved.collectionIDs == [first] && saved.attachments.first?.isReadOnlyReference == true, "Deleting collections changed unrelated paper data")
        try expect(try Data(contentsOf: source) == sourceData, "A collection operation changed a protected source file")
    }

    private static func testTagOrder() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = store.addTag(name: "A"), second = store.addTag(name: "B"), third = store.addTag(name: "C")
        try expect(store.moveTag(id: first, at: 3), "Dragging a tag down failed")
        try expect(store.tags.map(\.id) == [second, third, first], "Tag movement used the wrong insertion index")
        try expect(store.moveTag(id: first, at: 0), "Dragging a tag up failed")
        try expect(!store.moveTag(id: UUID(), at: 0), "A nonexistent tag was inserted")
        let reloaded = LibraryStore(persistenceURL: store.persistenceURL)
        try expect(reloaded.tags.map(\.id) == [first, second, third], "The tag order did not persist")
        store.deleteTag(id: second)
        try expect(store.tags.map(\.sortIndex) == [0, 1], "Tag deletion left inconsistent sort positions")
    }

    private static func testTagColors() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tag = store.addTag(name: "Color")
        store.updateTagColor(id: tag, colorHex: " #abc ")
        try expect(store.tags.first?.colorHex == "#AABBCC", "Short hex was not normalized")
        store.updateTagColor(id: tag, colorHex: "12ab34")
        let before = try Data(contentsOf: store.persistenceURL)
        store.updateTagColor(id: tag, colorHex: "not-a-color")
        try expect(store.tags.first?.colorHex == "#12AB34", "An invalid color replaced the saved tag color")
        try expect(try Data(contentsOf: store.persistenceURL) == before, "An invalid color wrote to disk")
        try expect(LibraryStore(persistenceURL: store.persistenceURL).tags.first?.colorHex == "#12AB34", "Custom color did not survive reload")
    }

    private static func testMalformedHierarchy() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var first = PaperCollection(name: "Cycle A")
        let second = PaperCollection(name: "Cycle B", parentID: first.id)
        first.parentID = second.id
        var snapshot = LibrarySnapshot.empty; snapshot.collections = [first, second]
        store.replaceSnapshot(snapshot)
        try expect(store.collectionDepth(id: first.id) == nil, "A cycle has a valid depth")
        try expect(!store.canMoveCollection(id: first.id, toParentID: nil), "A cyclic subtree was allowed to move")
        try rejects { try store.createCollection(name: "Child", parentID: second.id) }
    }
}
