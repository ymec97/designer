import XCTest
@testable import DesignerModel

/// Style: the opacity field, the no-fill sentinel, and their JSON round-trip.
final class StyleTests: XCTestCase {
    func testOpacityAndNoFillRoundTrip() throws {
        let style = Style(fill: Style.noFill, stroke: "#D95757",
                          strokeWidth: 2.5, opacity: 0.3)
        let data = try JSONEncoder().encode(style)
        let back = try JSONDecoder().decode(Style.self, from: data)
        XCTAssertEqual(back, style)
        XCTAssertFalse(back.hasFill, "the none sentinel survives")
        XCTAssertEqual(back.effectiveOpacity, 0.3)
    }

    func testNilOpacityIsOmittedFromJSON() throws {
        let data = try JSONEncoder().encode(Style(fill: "#4A90D9"))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("opacity"), "nil fields keep documents small")
        let back = try JSONDecoder().decode(Style.self, from: data)
        XCTAssertEqual(back.effectiveOpacity, 1, "absent opacity means opaque")
        XCTAssertTrue(back.hasFill)
    }

    func testEffectiveOpacityClamps() {
        XCTAssertEqual(Style(opacity: 4).effectiveOpacity, 1)
        XCTAssertEqual(Style(opacity: -1).effectiveOpacity, 0)
    }

    func testUnknownFieldsStillRoundTrip() throws {
        let json = #"{"fill":"none","opacity":0.5,"futureThing":{"a":1}}"#
        let decoded = try JSONDecoder().decode(Style.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extra["futureThing"], .object(["a": .int(1)]))
        let re = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(re, decoded)
    }
}
