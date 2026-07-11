import XCTest
import DesignerModel
@testable import DesignerPersistence

/// NFR R4: malformed input — hand-edited JSON, truncated files, LLM output —
/// must produce a precise error, never a crash or a silent partial import.
final class MalformedInputTests: XCTestCase {
    private func assertFailsWithDescriptiveError(
        _ data: Data, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try BoardSerialization.board(from: data), file: file, line: line) { error in
            let description = (error as? LocalizedError)?.errorDescription
            XCTAssertNotNil(description, "error must be user-presentable", file: file, line: line)
            XCTAssertFalse(description!.isEmpty, file: file, line: line)
        }
    }

    func testGarbageBytes() {
        assertFailsWithDescriptiveError(Data([0x00, 0xFF, 0x13, 0x37]))
    }

    func testEmptyData() {
        assertFailsWithDescriptiveError(Data())
    }

    func testTruncatedJSON() throws {
        let data = try BoardSerialization.data(from: Fixtures.sampleBoard())
        assertFailsWithDescriptiveError(data.prefix(data.count / 2))
    }

    func testTopLevelArrayIsNotABoard() {
        assertFailsWithDescriptiveError(Data("[1, 2, 3]".utf8))
    }

    func testMissingSchemaVersion() {
        assertFailsWithDescriptiveError(Data(#"{"id": "not-a-board"}"#.utf8))
        XCTAssertThrowsError(try BoardSerialization.board(from: Data(#"{"a": 1}"#.utf8))) { error in
            XCTAssertEqual(error as? BoardSerializationError, .missingSchemaVersion)
        }
    }

    func testNonIntegerSchemaVersion() {
        assertFailsWithDescriptiveError(Data(#"{"schemaVersion": "one"}"#.utf8))
    }

    func testMissingRequiredElementFieldReportsPath() throws {
        // An element without an id must fail and say so.
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(UUID().uuidString)",
          "title": "Broken",
          "layers": [{"id": "\(UUID().uuidString)", "name": "Base"}],
          "elements": [{"role": "note", "text": "no id", "frame": {"x":0,"y":0,"width":10,"height":10}, "layers": [], "sortKey": "i"}]
        }
        """
        XCTAssertThrowsError(try BoardSerialization.board(from: Data(json.utf8))) { error in
            guard case .decodingFailed(let detail)? = error as? BoardSerializationError else {
                return XCTFail("expected decodingFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("id"), "error should name the missing field: \(detail)")
        }
    }

    func testInvalidUUIDFails() {
        let json = #"{"schemaVersion": 1, "id": "definitely-not-a-uuid", "title": "x"}"#
        assertFailsWithDescriptiveError(Data(json.utf8))
    }

    func testInvalidDateFails() {
        let json = """
        {"schemaVersion": 1, "id": "\(UUID().uuidString)", "title": "x", "createdAt": "yesterday-ish"}
        """
        assertFailsWithDescriptiveError(Data(json.utf8))
    }
}
