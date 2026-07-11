import XCTest
@testable import DesignerModel

final class SortKeyTests: XCTestCase {
    func testInitialKeyIsValid() {
        XCTAssertEqual(SortKey.initial, "i")
    }

    func testBetweenNilAndNil() {
        XCTAssertEqual(SortKey.between(nil, nil), "i")
    }

    func testBetweenOrdering() {
        let key = SortKey.between("a", "b")
        XCTAssertGreaterThan(key, "a")
        XCTAssertLessThan(key, "b")
    }

    func testAfterProducesGreaterKey() {
        var key = SortKey.initial
        for _ in 0..<100 {
            let next = SortKey.after(key)
            XCTAssertGreaterThan(next, key)
            key = next
        }
    }

    func testBeforeProducesSmallerKey() {
        var key = SortKey.initial
        for _ in 0..<100 {
            let next = SortKey.between(nil, key)
            XCTAssertLessThan(next, key)
            XCTAssertFalse(next.isEmpty)
            key = next
        }
    }

    func testRepeatedMidpointInsertionStaysOrderedAndValid() {
        // Simulates the worst case: always inserting between the same two
        // neighbors (e.g. repeatedly sending an element just below another).
        var lower = "a"
        let upper = "b"
        for _ in 0..<200 {
            let mid = SortKey.between(lower, upper)
            XCTAssertGreaterThan(mid, lower)
            XCTAssertLessThan(mid, upper)
            XCTAssertFalse(mid.hasSuffix("0"), "keys must not end in '0': \(mid)")
            lower = mid
        }
    }

    func testBulkKeysAreOrderedValidAndBetweenCompatible() {
        let count = 6000
        var previous: String?
        for index in 0..<count {
            let key = SortKey.bulk(index, of: count)
            XCTAssertFalse(key.hasSuffix("0"), "bulk keys must not end in '0': \(key)")
            if let previous {
                XCTAssertGreaterThan(key, previous, "bulk keys must be strictly increasing")
                // A key must always fit between two adjacent bulk keys.
                let mid = SortKey.between(previous, key)
                XCTAssertGreaterThan(mid, previous)
                XCTAssertLessThan(mid, key)
            }
            previous = key
        }
        // Constant length regardless of index (the whole point vs chained after()).
        XCTAssertEqual(
            SortKey.bulk(0, of: count).count,
            SortKey.bulk(count - 1, of: count).count
        )
    }

    func testDenseSequentialInsertions() {
        // Insert 500 keys always at a random gap; the whole list must stay sorted.
        var keys = [SortKey.initial]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let gapIndex = Int.random(in: 0...keys.count, using: &generator)
            let lower = gapIndex > 0 ? keys[gapIndex - 1] : nil
            let upper = gapIndex < keys.count ? keys[gapIndex] : nil
            let key = SortKey.between(lower, upper)
            if let lower { XCTAssertGreaterThan(key, lower) }
            if let upper { XCTAssertLessThan(key, upper) }
            keys.insert(key, at: gapIndex)
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count, "keys must be unique")
    }
}
