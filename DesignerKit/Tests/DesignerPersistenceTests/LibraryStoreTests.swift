import XCTest
import DesignerModel
@testable import DesignerPersistence

final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)")
        store = LibraryStore(rootURL: root)
        try store.ensureRootExists()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleClip(_ name: String) -> Board {
        var board = Board(title: name)
        let layer = board.layers[0].id
        let node = Element(
            layerIDs: [layer], sortKey: "i",
            content: .node(Node(semantic: NodeSemantic(name: name), frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        board.elements[node.id] = node
        return board
    }

    func testSaveLoadRoundTrip() throws {
        let clip = sampleClip("cache-pattern")
        let entry = LibraryEntry(name: "Cache Pattern", tags: ["infra", "cache"])
        let saved = try store.save(clip, as: entry)
        XCTAssertEqual(saved.elementCount, 1)

        let loaded = try store.loadBoard(entry.id)
        XCTAssertEqual(loaded.elements.count, 1)

        let list = try store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Cache Pattern")
        XCTAssertEqual(list.first?.tags, ["infra", "cache"])
    }

    func testListIsNewestFirst() throws {
        let older = LibraryEntry(name: "Older", createdAt: Date(timeIntervalSince1970: 1000))
        let newer = LibraryEntry(name: "Newer", createdAt: Date(timeIntervalSince1970: 2000))
        try store.save(sampleClip("a"), as: older)
        try store.save(sampleClip("b"), as: newer)
        XCTAssertEqual(try store.list().map(\.name), ["Newer", "Older"])
    }

    func testSearchByNameAndTag() throws {
        try store.save(sampleClip("a"), as: LibraryEntry(name: "Redis Cache", tags: ["infra"]))
        try store.save(sampleClip("b"), as: LibraryEntry(name: "Load Balancer", tags: ["network", "edge"]))

        XCTAssertEqual(try store.search("redis").map(\.name), ["Redis Cache"])
        XCTAssertEqual(try store.search("edge").map(\.name), ["Load Balancer"])
        XCTAssertEqual(Set(try store.search("").map(\.name)), ["Redis Cache", "Load Balancer"])
        XCTAssertTrue(try store.search("nonexistent").isEmpty)
    }

    func testUpdateMetadataKeepsPayload() throws {
        var entry = LibraryEntry(name: "Original", tags: ["a"])
        try store.save(sampleClip("payload"), as: entry)

        entry.name = "Renamed"
        entry.tags = ["a", "b"]
        try store.update(entry)

        let list = try store.list()
        XCTAssertEqual(list.first?.name, "Renamed")
        XCTAssertEqual(list.first?.tags, ["a", "b"])
        // Payload still loads.
        XCTAssertEqual(try store.loadBoard(entry.id).elements.count, 1)
    }

    func testOverwriteSameEntry() throws {
        let entry = LibraryEntry(name: "Entry")
        try store.save(sampleClip("v1"), as: entry)
        var twoNodeClip = sampleClip("v2")
        let extra = Element(
            layerIDs: [twoNodeClip.layers[0].id], sortKey: "j",
            content: .node(Node(frame: Rect(x: 200, y: 0, width: 100, height: 60)))
        )
        twoNodeClip.elements[extra.id] = extra
        try store.save(twoNodeClip, as: entry)

        XCTAssertEqual(try store.list().count, 1, "same id overwrites, not duplicates")
        XCTAssertEqual(try store.loadBoard(entry.id).elements.count, 2)
    }

    func testDelete() throws {
        let entry = LibraryEntry(name: "Doomed")
        try store.save(sampleClip("x"), as: entry)
        try store.delete(entry.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testCorruptPackageIsSkippedNotFatal() throws {
        try store.save(sampleClip("good"), as: LibraryEntry(name: "Good"))
        // A junk package directory shouldn't break listing.
        let junk = root.appendingPathComponent("\(UUID().uuidString).designerclip")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: junk.appendingPathComponent("entry.json"))

        XCTAssertEqual(try store.list().map(\.name), ["Good"])
    }

    func testListEmptyWhenRootMissing() throws {
        let missing = LibraryStore(rootURL: root.appendingPathComponent("nope"))
        XCTAssertEqual(try missing.list().count, 0)
    }
}
