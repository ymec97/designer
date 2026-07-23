import Foundation

extension Board {
    /// How connector captions (label + property badges) are shown board-wide.
    /// Stored in `extra` (schema-neutral; older builds ignore it), so it
    /// round-trips through board.json and is undoable like the sketchy flag.
    public enum CaptionMode: String, CaseIterable, Sendable {
        /// Every connector paints its caption (subject to the zoom LOD gate).
        case always
        /// Only selected / hovered / flow-emphasized connectors paint captions —
        /// keeps dense boards readable without losing the labels entirely.
        case onFocus
        /// No connector captions at all.
        case off
    }

    public static let captionModeExtraKey = "captionMode"

    /// The board's caption-visibility mode. Absent (or unrecognized) reads as
    /// `.always`, so existing boards render exactly as before.
    public var captionMode: CaptionMode {
        if case .string(let raw)? = extra[Self.captionModeExtraKey],
           let mode = CaptionMode(rawValue: raw) {
            return mode
        }
        return .always
    }
}
