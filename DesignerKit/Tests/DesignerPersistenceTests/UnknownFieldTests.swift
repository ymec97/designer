import XCTest
import DesignerModel
@testable import DesignerPersistence

/// NFR R2: fields written by future app versions must survive an open→save
/// round-trip in this version, at every level of the document.
final class UnknownFieldTests: XCTestCase {
    /// Marker resolved to the array index of the first element with that role
    /// (element order in JSON is sorted by random UUID, so indices vary).
    private enum PathToken {
        case elementWithRole(String)
    }

    /// Injects an unknown field into a JSON object at the given path, decodes
    /// the document, re-encodes it, and asserts the field is still there.
    private func assertUnknownFieldSurvives(
        injectAt rawPath: [Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try BoardSerialization.data(from: Fixtures.sampleBoard())
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            file: file, line: line
        )
        let path: [Any] = try rawPath.map { token in
            guard let pathToken = token as? PathToken else { return token }
            switch pathToken {
            case .elementWithRole(let role):
                let elements = try XCTUnwrap(json["elements"] as? [[String: Any]], file: file, line: line)
                return try XCTUnwrap(
                    elements.firstIndex { ($0["role"] as? String) == role },
                    "no element with role \(role)", file: file, line: line
                )
            }
        }
        json = try inject(into: json, at: path, key: "fieldFromTheFuture", value: "v2-data")
        let mutated = try JSONSerialization.data(withJSONObject: json)

        let decoded = try BoardSerialization.board(from: mutated)
        let reEncoded = try BoardSerialization.data(from: decoded)
        let text = try XCTUnwrap(String(data: reEncoded, encoding: .utf8), file: file, line: line)
        XCTAssertTrue(
            text.contains("fieldFromTheFuture") && text.contains("v2-data"),
            "unknown field at \(path) was dropped on round-trip",
            file: file, line: line
        )
    }

    func testUnknownFieldAtBoardLevel() throws {
        try assertUnknownFieldSurvives(injectAt: [])
    }

    func testUnknownFieldOnLayer() throws {
        try assertUnknownFieldSurvives(injectAt: ["layers", 0])
    }

    func testUnknownFieldOnElement() throws {
        try assertUnknownFieldSurvives(injectAt: ["elements", PathToken.elementWithRole("node")])
    }

    func testUnknownFieldOnNodeSemantic() throws {
        try assertUnknownFieldSurvives(injectAt: ["elements", PathToken.elementWithRole("node"), "semantic"])
    }

    func testUnknownFieldOnEdgeSemantic() throws {
        try assertUnknownFieldSurvives(injectAt: ["elements", PathToken.elementWithRole("edge"), "semantic"])
    }

    func testUnknownFieldOnStyle() throws {
        try assertUnknownFieldSurvives(injectAt: ["elements", PathToken.elementWithRole("node"), "style"])
    }

    func testUnknownFieldOnGroup() throws {
        try assertUnknownFieldSurvives(injectAt: ["groups", 0])
    }

    func testUnknownNodeKindIsPreserved() throws {
        let data = try BoardSerialization.data(from: Fixtures.sampleBoard())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let mutated = text.replacingOccurrences(of: "\"gateway\"", with: "\"quantum-mesh\"")

        let decoded = try BoardSerialization.board(from: Data(mutated.utf8))
        let reEncoded = try BoardSerialization.data(from: decoded)
        XCTAssertTrue(
            try XCTUnwrap(String(data: reEncoded, encoding: .utf8)).contains("quantum-mesh"),
            "unknown node kinds must round-trip as-is"
        )
    }

    // MARK: helpers

    private func inject(
        into json: [String: Any], at path: [Any], key: String, value: String
    ) throws -> [String: Any] {
        var json = json
        if path.isEmpty {
            json[key] = value
            return json
        }
        let head = path[0]
        let rest = Array(path.dropFirst())
        if let field = head as? String {
            if rest.isEmpty, var child = json[field] as? [String: Any] {
                child[key] = value
                json[field] = child
            } else if let index = rest.first as? Int, var array = json[field] as? [[String: Any]] {
                array[index] = try inject(into: array[index], at: Array(rest.dropFirst()), key: key, value: value)
                json[field] = array
            } else if var child = json[field] as? [String: Any] {
                child = try inject(into: child, at: rest, key: key, value: value)
                json[field] = child
            } else {
                XCTFail("cannot descend into '\(field)'")
            }
        }
        return json
    }
}
