import Foundation

/// A string-only coding key used to enumerate and re-emit fields the current
/// schema does not know about, so documents written by newer app versions
/// survive an open/save round-trip in older versions (NFR R2).
public struct RawCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }

    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
    public init(_ stringValue: String) { self.stringValue = stringValue }
}

extension Decoder {
    /// Collects every field in the current keyed container that is not a known key.
    public func unknownFields(excluding knownKeys: Set<String>) throws -> [String: JSONValue] {
        let container = try container(keyedBy: RawCodingKey.self)
        var extra: [String: JSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extra
    }
}

extension Encoder {
    /// Re-emits previously captured unknown fields alongside the known ones.
    public func encodeUnknownFields(_ extra: [String: JSONValue]) throws {
        guard !extra.isEmpty else { return }
        var container = container(keyedBy: RawCodingKey.self)
        for (key, value) in extra {
            try container.encode(value, forKey: RawCodingKey(key))
        }
    }
}

extension CodingKey where Self: CaseIterable {
    public static var knownKeys: Set<String> { Set(allCases.map(\.stringValue)) }
}
