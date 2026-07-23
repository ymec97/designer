import XCTest
@testable import DesignerModel

final class CaptionModeTests: XCTestCase {
    func testDefaultsToAlwaysWhenAbsent() {
        let board = Board(title: "x")
        XCTAssertEqual(board.captionMode, .always)
    }

    func testRoundTripsThroughExtra() throws {
        var board = Board(title: "x")
        _ = try board.apply(.setExtra(key: Board.captionModeExtraKey, value: .string("onFocus")))
        XCTAssertEqual(board.captionMode, .onFocus)
        _ = try board.apply(.setExtra(key: Board.captionModeExtraKey, value: .string("off")))
        XCTAssertEqual(board.captionMode, .off)
        // Clearing the key returns to the default.
        _ = try board.apply(.setExtra(key: Board.captionModeExtraKey, value: nil))
        XCTAssertEqual(board.captionMode, .always)
    }

    func testUnknownValueFallsBackToAlways() throws {
        var board = Board(title: "x")
        _ = try board.apply(.setExtra(key: Board.captionModeExtraKey, value: .string("bogus")))
        XCTAssertEqual(board.captionMode, .always)
    }

    /// Tolerant coding: the mode survives a JSON encode/decode via the `extra`
    /// bag, and older builds that don't know the key simply ignore it.
    func testJSONRoundTripPreservesMode() throws {
        var board = Board(title: "x")
        _ = try board.apply(.setExtra(key: Board.captionModeExtraKey, value: .string("onFocus")))
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertEqual(decoded.captionMode, .onFocus)
    }
}
