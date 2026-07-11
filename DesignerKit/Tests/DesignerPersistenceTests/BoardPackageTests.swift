import XCTest
import DesignerModel
@testable import DesignerPersistence

final class BoardPackageTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoardPackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private var packageURL: URL {
        temporaryDirectory.appendingPathComponent("Test.\(BoardPackage.fileExtension)")
    }

    func testWriteThenReadRoundTrip() throws {
        let board = Fixtures.sampleBoard()
        try BoardPackage.write(board, to: packageURL)
        XCTAssertEqual(try BoardPackage.read(from: packageURL), board)

        // Package layout is as documented.
        let contents = try FileManager.default.contentsOfDirectory(atPath: packageURL.path).sorted()
        XCTAssertEqual(contents, [BoardPackage.assetsDirectoryName, BoardPackage.boardFileName])
    }

    func testOverwriteReplacesAtomicallyAndPreservesReadability() throws {
        var board = Fixtures.sampleBoard()
        try BoardPackage.write(board, to: packageURL)

        board.title = "Renamed"
        try BoardPackage.write(board, to: packageURL)

        let read = try BoardPackage.read(from: packageURL)
        XCTAssertEqual(read.title, "Renamed")
        XCTAssertEqual(read, board)
    }

    func testReadMissingBoardFileFails() throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BoardPackage.read(from: packageURL)) { error in
            XCTAssertTrue(error is BoardPackage.PackageError)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    func testFileWrapperRoundTrip() throws {
        let board = Fixtures.sampleBoard()
        let wrapper = try BoardPackage.fileWrapper(for: board)
        XCTAssertTrue(wrapper.isDirectory)
        XCTAssertEqual(try BoardPackage.board(from: wrapper), board)
    }

    func testFileWrapperWrittenToDiskReadsBackViaURL() throws {
        let board = Fixtures.sampleBoard()
        let wrapper = try BoardPackage.fileWrapper(for: board)
        try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try BoardPackage.read(from: packageURL), board)
    }
}
