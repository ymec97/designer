import XCTest
import DesignerModel
@testable import DesignerPersistence

final class RoundTripTests: XCTestCase {
    func testFullBoardRoundTripIsLossless() throws {
        let board = Fixtures.sampleBoard()
        let data = try BoardSerialization.data(from: board)
        let decoded = try BoardSerialization.board(from: data)
        XCTAssertEqual(decoded, board)
    }

    func testEmptyBoardRoundTrip() throws {
        let board = Board(title: "Empty")
        let decoded = try BoardSerialization.board(from: try BoardSerialization.data(from: board))
        XCTAssertEqual(decoded, board)
        XCTAssertEqual(decoded.layers.count, 1, "a valid board always has a base layer")
    }

    func testEncodingIsDeterministic() throws {
        let board = Fixtures.sampleBoard()
        let first = try BoardSerialization.data(from: board)
        let second = try BoardSerialization.data(from: board)
        XCTAssertEqual(first, second, "same board must encode to identical bytes (NFR M3)")

        // And decode → encode is byte-stable too.
        let decoded = try BoardSerialization.board(from: first)
        let third = try BoardSerialization.data(from: decoded)
        XCTAssertEqual(first, third)
    }

    func testEncodedFormIsHumanReadable() throws {
        let data = try BoardSerialization.data(from: Fixtures.sampleBoard())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\""))
        XCTAssertTrue(text.contains("api-gateway"))
        XCTAssertTrue(text.contains("gRPC"))
        XCTAssertTrue(text.contains("\n"), "output must be pretty-printed for diffs and LLMs")
    }
}
