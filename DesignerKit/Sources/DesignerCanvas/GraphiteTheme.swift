import AppKit
import DesignerModel

/// Studio Graphite — the app's visual language. A cool graphite neutral
/// ground, a single confident indigo accent, and quiet per-kind fills so the
/// diagram stays the hero. All tokens are appearance-dynamic (equal care in
/// light and dark, NFR U4). Public so the SwiftUI chrome and the canvas share
/// exactly one palette.
public enum Graphite {
    /// Builds a light/dark dynamic color from two sRGB hex strings.
    static func dynamic(light: String, dark: String) -> NSColor {
        let lightColor = NSColor(hexString: light) ?? .white
        let darkColor = NSColor(hexString: dark) ?? .black
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    // Ground & structure
    public static let canvas       = dynamic(light: "#FBFBFD", dark: "#16181D")
    public static let panel        = dynamic(light: "#FFFFFF", dark: "#1C1F27")
    public static let panelRaised  = dynamic(light: "#FFFFFF", dark: "#22262F")
    public static let hairline     = dynamic(light: "#E2E4EA", dark: "#2A2E38")
    public static let hairlineStrong = dynamic(light: "#D0D3DC", dark: "#363B47")
    public static let grid         = dynamic(light: "#EAECF1", dark: "#20242C")

    // Ink
    public static let ink          = dynamic(light: "#1B1D23", dark: "#E9EBF0")
    public static let inkDim        = dynamic(light: "#5C616E", dark: "#A2A7B4")
    public static let inkFaint      = dynamic(light: "#9498A4", dark: "#6B7080")

    // Accent — the app's indigo. Deliberately not the user's system accent,
    // so Designer has a consistent identity.
    public static let accent       = dynamic(light: "#3B5BDB", dark: "#7D97FF")
    public static let accentSoft   = dynamic(light: "#E7ECFD", dark: "#26305A")

    /// Palette for recorded flows (F5): distinct hues that read on both
    /// canvas grounds. Index 0 is the app accent; assignment cycles.
    public static let flowColors: [NSColor] = [
        accent,
        dynamic(light: "#0CA678", dark: "#38D9A9"),  // teal
        dynamic(light: "#E8590C", dark: "#FFA94D"),  // orange
        dynamic(light: "#AE3EC9", dark: "#DA77F2"),  // violet
        dynamic(light: "#E03131", dark: "#FF8787"),  // red
        dynamic(light: "#1098AD", dark: "#66D9E8"),  // cyan
    ]

    // Canvas semantics
    public static let nodeStroke   = dynamic(light: "#D5D9E2", dark: "#3A404D")
    public static let edge         = dynamic(light: "#9AA0AD", dark: "#6C7280")
    public static let nodeText     = ink
    public static let noteText     = inkDim
    public static let ink_stroke   = dynamic(light: "#2A2D34", dark: "#D7DAE1") // freehand
    public static let dangling     = dynamic(light: "#E8912F", dark: "#F0A94E")
    public static let snapGuide    = dynamic(light: "#E24A8B", dark: "#FF6FA5")
    public static let hint         = inkFaint

    /// Node surface fill per kind — a white/graphite base with a quiet wash so
    /// kinds are distinguishable without shouting.
    public static func nodeFill(for kind: NodeKind) -> NSColor {
        switch kind {
        case .client:   return dynamic(light: "#EDFAF1", dark: "#18291E")
        case .gateway:  return dynamic(light: "#E6F8F2", dark: "#14292A")
        case .database: return dynamic(light: "#EDF1FF", dark: "#1B2242")
        case .queue:    return dynamic(light: "#FFF5E9", dark: "#2C2214")
        case .cache:    return dynamic(light: "#F4EFFE", dark: "#241B3A")
        case .external: return dynamic(light: "#F2F3F6", dark: "#24272E")
        case .service:  return dynamic(light: "#FFFFFF", dark: "#232732")
        default:        return dynamic(light: "#FFFFFF", dark: "#232732")
        }
    }

    /// The small kind indicator dot — the one saturated spot of colour on a node.
    public static func kindDot(for kind: NodeKind) -> NSColor {
        switch kind {
        case .client:   return dynamic(light: "#2FA265", dark: "#4CC47F")
        case .gateway:  return dynamic(light: "#17A2A2", dark: "#2BC0C0")
        case .database: return dynamic(light: "#3B5BDB", dark: "#7D97FF")
        case .queue:    return dynamic(light: "#E08A2B", dark: "#F0A94E")
        case .cache:    return dynamic(light: "#7C5CF6", dark: "#A78BFA")
        case .external: return dynamic(light: "#7A7F8C", dark: "#9298A6")
        case .service:  return dynamic(light: "#8B90A0", dark: "#9AA0AF")
        default:        return dynamic(light: "#8B90A0", dark: "#9AA0AF")
        }
    }

    /// Translucent backing so edge captions read over lines without hard boxes.
    public static let captionBackground = dynamic(light: "#FBFBFD", dark: "#16181D").withAlphaComponent(0.9)

    /// Node elevation shadow — soft in light, near-invisible-but-present depth
    /// in dark (where a lighter node already lifts off the ground).
    public static let shadowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
            : NSColor(srgbRed: 0.11, green: 0.12, blue: 0.20, alpha: 0.14)
    }
}
