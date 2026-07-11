import Foundation

/// Fractional-index sort keys for z-ordering: strings over the base-36 digits
/// `0-9a-z`, compared lexicographically, interpreted as a fraction in (0, 1).
/// Valid keys are non-empty and never end in `0`, which guarantees a key
/// strictly between any two distinct keys always exists. Inserting between
/// neighbors never rewrites other elements' keys — important for the
/// operation log (D11).
public enum SortKey {
    static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    static let base = 36

    /// First key for an empty board ("i", the midpoint digit).
    public static var initial: String { String(digits[base / 2]) }

    /// A key strictly between `lower` and `upper` (standard fractional-indexing
    /// midpoint). `nil` lower means "before everything"; `nil` upper means
    /// "after everything".
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let a = Array(lower ?? "")
        let b = upper.map(Array.init)
        precondition(b == nil || Array(lower ?? "").lexicographicallyPrecedes(b!) || lower == nil,
                     "SortKey.between requires lower < upper")
        return midpoint(a, b)
    }

    /// A key after `lower` (append at top of z-order).
    public static func after(_ lower: String?) -> String {
        between(lower, nil)
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        // Strip the longest common prefix; recurse on the remainder.
        if let b {
            var i = 0
            while i < b.count && (i < a.count ? a[i] : "0") == b[i] { i += 1 }
            if i > 0 {
                return String(b[0..<i]) + midpoint(Array(a.dropFirst(i)), Array(b.dropFirst(i)))
            }
        }

        // First digits now differ.
        let digitA = a.isEmpty ? 0 : value(a[0])
        let digitB = b.map { value($0[0]) } ?? base

        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB) / 2])
        }

        // Consecutive digits.
        if let b, b.count > 1 {
            // b's first digit alone: a proper prefix of b (so < b) and > a.
            return String(b[0])
        }
        // Descend into a's remainder with no upper bound.
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }

    static func value(_ character: Character) -> Int {
        guard let ascii = character.asciiValue else { return 0 }
        switch ascii {
        case 0x30...0x39: return Int(ascii - 0x30)          // '0'-'9'
        case 0x61...0x7A: return Int(ascii - 0x61) + 10     // 'a'-'z'
        default: return 0
        }
    }

    /// Constant-length key for bulk generation (index i of a known count):
    /// zero-padded base-36 counter + a non-zero tail digit to satisfy the
    /// no-trailing-zero invariant. Chaining `after()` thousands of times
    /// grows keys quadratically — bulk builders (perf boards, importers)
    /// must use this instead.
    public static func bulk(_ index: Int, of count: Int) -> String {
        let width = max(1, Int(ceil(log(Double(max(count, 2))) / log(36))))
        var digitsOut = [Character](repeating: "0", count: width)
        var remaining = index
        var position = width - 1
        while remaining > 0 && position >= 0 {
            digitsOut[position] = digits[remaining % base]
            remaining /= base
            position -= 1
        }
        return String(digitsOut) + "i"
    }
}
