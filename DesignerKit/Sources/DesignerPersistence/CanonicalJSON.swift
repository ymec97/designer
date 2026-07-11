import Foundation

/// The one true JSON configuration for board documents (NFR M3):
/// sorted keys + pretty printing + stable date format ⇒ encoding the same
/// board twice yields identical bytes, documents stay git-diff-friendly, and
/// the output is legible to humans and LLMs (D16).
public enum CanonicalJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatMilliseconds(date.unixMilliseconds))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? iso8601Millis.parse(string)) ?? (try? iso8601Plain.parse(string)) {
                // Quantize exactly like `Date.millisecondRounded` so a decoded
                // date is bit-identical to the date that was encoded.
                return date.millisecondRounded
            }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid ISO 8601 date '\(string)'"
            ))
        }
        return decoder
    }

    /// Integer-math ISO 8601 formatting: the fractional part is the exact
    /// stored millisecond count, immune to Double truncation artifacts.
    private static func formatMilliseconds(_ unixMilliseconds: Int64) -> String {
        var (seconds, millis) = unixMilliseconds.quotientAndRemainder(dividingBy: 1000)
        if millis < 0 {
            seconds -= 1
            millis += 1000
        }
        let components = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            components.year!, components.month!, components.day!,
            components.hour!, components.minute!, components.second!, millis
        )
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let iso8601Millis = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Plain = Date.ISO8601FormatStyle()
}
