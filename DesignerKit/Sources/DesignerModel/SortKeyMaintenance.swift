import Foundation

/// B2: `SortKey.after()` chained thousands of times grows keys (~1 char per
/// ~17 insertions), inflating files and comparisons. Rather than renumbering
/// mid-session (which would fight the undo stack), keys are normalized when a
/// board is LOADED — before any undo history exists — whenever they've grown
/// past a threshold.
extension Board {
    /// Longest key tolerated before a load-time renumber kicks in. Bulk keys
    /// for even 100k elements are ~4 chars; interactive chains grow slowly,
    /// so 24 means "has been through many thousands of sequential inserts".
    public static let sortKeyLengthThreshold = 24

    /// True when any element's z-order key exceeds the threshold.
    public var needsSortKeyNormalization: Bool {
        elements.values.contains { $0.sortKey.count > Self.sortKeyLengthThreshold }
    }

    /// Rewrites every element's sort key to a compact bulk key, preserving
    /// the existing z-order exactly. Call only where undo history can't
    /// reference old keys (e.g. right after decoding a file).
    public mutating func normalizeSortKeys() {
        let ordered = elementsInZOrder
        for (index, element) in ordered.enumerated() {
            var updated = element
            updated.sortKey = SortKey.bulk(index, of: ordered.count)
            elements[updated.id] = updated
        }
    }

    /// Convenience for the load path.
    public mutating func normalizeSortKeysIfNeeded() {
        if needsSortKeyNormalization { normalizeSortKeys() }
    }
}
