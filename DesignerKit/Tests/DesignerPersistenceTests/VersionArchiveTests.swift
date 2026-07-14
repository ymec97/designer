import XCTest
import DesignerModel
@testable import DesignerPersistence

final class VersionArchiveTests: XCTestCase {
    private func sampleBoard(_ title: String, nodes: Int = 3) -> Board {
        var board = Board(title: title)
        let layer = board.layers[0].id
        for index in 0..<nodes {
            try! board.apply(.insertElement(Element(
                layerIDs: [layer], sortKey: board.topSortKey,
                content: .node(Node(semantic: NodeSemantic(name: "n\(index)"),
                                    frame: Rect(x: Double(index) * 100, y: 0, width: 80, height: 40)))
            )))
        }
        return board
    }

    func testAddReadRenameDelete() throws {
        var archive = VersionArchive()
        let meta = try archive.add(sampleBoard("v1"), name: "First", kind: .manual, thumbnail: Data([1, 2]))
        XCTAssertEqual(archive.metas.map(\.name), ["First"])
        XCTAssertEqual(archive.metas[0].elementCount, 3)
        XCTAssertEqual(try archive.board(for: meta.id)?.title, "v1")
        XCTAssertEqual(archive.thumbnail(for: meta.id), Data([1, 2]))

        archive.rename(meta.id, to: "Renamed")
        XCTAssertEqual(archive.metas[0].name, "Renamed")

        archive.delete(meta.id)
        XCTAssertTrue(archive.isEmpty)
        XCTAssertNil(try archive.board(for: meta.id))
    }

    func testNewestFirstAndAutoPruning() throws {
        var archive = VersionArchive()
        try archive.add(sampleBoard("m"), name: "Manual", kind: .manual)
        for index in 0..<5 {
            try archive.add(sampleBoard("a\(index)"), name: "Auto \(index)", kind: .auto)
        }
        XCTAssertEqual(archive.metas.first?.name, "Auto 4", "newest first")

        archive.pruneAutoVersions(keeping: 2)
        let names = archive.metas.map(\.name)
        XCTAssertEqual(names, ["Auto 4", "Auto 3", "Manual"],
                       "oldest autos pruned; manual versions never expire")
    }

    func testFileWrapperRoundTrip() throws {
        var archive = VersionArchive()
        let first = try archive.add(sampleBoard("v1"), name: "First", kind: .manual, thumbnail: Data([9]))
        let second = try archive.add(sampleBoard("v2", nodes: 5), name: "Second", kind: .auto)

        let reloaded = VersionArchive(wrapper: try archive.fileWrapper())
        XCTAssertEqual(reloaded.metas.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.metas.map(\.kind), [.auto, .manual])
        XCTAssertEqual(try reloaded.board(for: first.id)?.title, "v1")
        XCTAssertEqual(try reloaded.board(for: second.id)?.elements.count, 5)
        XCTAssertEqual(reloaded.thumbnail(for: first.id), Data([9]))
        XCTAssertNil(reloaded.thumbnail(for: second.id))
    }

    func testBoardPackageCarriesVersions() throws {
        var archive = VersionArchive()
        let meta = try archive.add(sampleBoard("snapshot"), name: "Kept", kind: .manual)
        let board = sampleBoard("current")

        let wrapper = try BoardPackage.fileWrapper(for: board, versions: archive)
        XCTAssertEqual(try BoardPackage.board(from: wrapper).title, "current")
        let reloaded = BoardPackage.versions(from: wrapper)
        XCTAssertEqual(reloaded.metas.map(\.name), ["Kept"])
        XCTAssertEqual(try reloaded.board(for: meta.id)?.title, "snapshot")
    }

    func testPackageWithoutVersionsLoadsEmptyArchive() throws {
        let wrapper = try BoardPackage.fileWrapper(for: sampleBoard("plain"))
        XCTAssertTrue(BoardPackage.versions(from: wrapper).isEmpty)
        XCTAssertNil(wrapper.fileWrappers?[VersionArchive.directoryName],
                     "empty archive writes no versions directory (back-compat)")
    }

    func testURLWritePreservesVersionsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("board.designerboard")

        // First write via wrapper (with versions), then rewrite via URL API.
        var archive = VersionArchive()
        try archive.add(sampleBoard("old"), name: "Kept", kind: .manual)
        let wrapper = try BoardPackage.fileWrapper(for: sampleBoard("first"), versions: archive)
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)

        try BoardPackage.write(sampleBoard("second"), to: url)
        XCTAssertEqual(try BoardPackage.read(from: url).title, "second")
        let indexURL = url.appendingPathComponent(VersionArchive.directoryName)
            .appendingPathComponent("index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "URL rewrite must not drop the version history")
    }
}
