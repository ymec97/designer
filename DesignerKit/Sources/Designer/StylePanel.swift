import SwiftUI
import DesignerModel

/// The universal style panel (left side): pencil settings while drawing,
/// pending-shape settings while the shape tool is armed, and live restyling
/// of whatever styleable element is selected. One panel, three modes — the
/// same controls everywhere.
final class StylePanelModel: ObservableObject {
    enum Mode {
        case pencil     // Draw tool: styles NEW ink strokes
        case shape      // Shape tool: styles the NEXT dragged shape
        case selection  // Select tool: restyles the selected element(s)
        case connector  // Select tool with a connector selected
        case image      // Select tool with an image/SVG node: layers + text size only

        var title: String {
            switch self {
            case .pencil: return "Pencil"
            case .shape: return "Shape"
            case .selection: return "Style"
            case .connector: return "Connector"
            case .image: return "Image"
            }
        }

        /// Fill applies to blocks only — pencil strokes and connectors are
        /// lines, images paint their own pixels.
        var showsFill: Bool { self == .shape || self == .selection }
        /// Text size applies to anything that renders a label — including
        /// connectors (sizes the label; property badges scale with it).
        var showsTextSize: Bool { self == .selection || self == .shape || self == .image || self == .connector }
    }

    @Published var isVisible = false
    @Published var mode: Mode = .shape
    /// nil = default fill, Style.noFill = transparent background.
    @Published var fill: String? = Style.noFill
    @Published var stroke: String?
    @Published var strokeWidth: Double?
    @Published var opacity: Double = 1
    @Published var textSize: TextSize = .medium
    /// Diagonal-stripe background (blocks/shapes only).
    @Published var striped = false
    /// Dashed outline (blocks/shapes only).
    @Published var dashed = false
    // Z-order clarity (F8): the selection's layer + its position among
    // layer-sharing peers, kept in sync by the controller.
    @Published var layerChipText: String?
    @Published var zPositionText: String?
    @Published var canStepForward = false
    @Published var canStepBackward = false

    /// Set while the panel is being programmatically seeded (selection
    /// change) so the seeding doesn't echo back as an edit.
    var isSeeding = false

    var style: Style {
        Style(fill: fill, stroke: stroke, strokeWidth: strokeWidth,
              opacity: opacity >= 0.999 ? nil : opacity,
              textSize: textSize == .medium ? nil : textSize,
              fillPattern: striped ? .stripes : nil,
              outlineStyle: dashed ? .dashed : nil)
    }

    func seed(from style: Style, mode: Mode) {
        isSeeding = true
        self.mode = mode
        fill = style.fill
        stroke = style.stroke
        strokeWidth = style.strokeWidth
        opacity = style.effectiveOpacity
        textSize = style.textSize ?? .medium
        striped = style.isStriped
        dashed = style.isDashed
        isSeeding = false
    }
}

struct StylePanelActions {
    /// Fired on every user edit with the assembled style.
    var styleChanged: (Style) -> Void
    var bringToFront: () -> Void
    var sendToBack: () -> Void
    var stepForward: () -> Void = {}
    var stepBackward: () -> Void = {}
    /// Explicit dismiss (the header ✕) — the panel no longer closes itself
    /// on deselection/undo.
    var close: () -> Void = {}
}

struct StylePanelContainer: View {
    @ObservedObject var model: StylePanelModel
    let actions: StylePanelActions

    var body: some View {
        if model.isVisible {
            StylePanel(model: model, actions: actions)
        }
    }
}

struct StylePanel: View {
    @ObservedObject var model: StylePanelModel
    let actions: StylePanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.mode.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button {
                    actions.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close the style panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            StyleControls(model: model, actions: actions)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 236)
        .floatingPanel(radius: 12)
        .graphiteAccent()
        // The whole panel is a solid click target: a click on padding or
        // between controls must NEVER fall through to the canvas (it used to
        // deselect and close the panel).
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var hint: String {
        switch model.mode {
        case .pencil: return "new strokes"
        case .shape: return "next shape"
        case .selection: return "selected"
        case .connector: return "selected"
        case .image: return "selected"
        }
    }
}

/// The shared style controls — used by the style panel and the Inspector's
/// Style section so color/opacity editing looks identical everywhere.
struct StyleControls: View {
    @ObservedObject var model: StylePanelModel
    let actions: StylePanelActions

    /// Graphite-friendly quick colors (fills and strokes share them).
    static let quickColors: [String] = [
        "#FFFFFF", "#4A90D9", "#5FA55A", "#E8943A", "#9B6BD3",
        "#D95757", "#3AAFA9", "#FFF2CC", "#8B95A5",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if model.mode.showsFill {
                swatchRow(title: "Background", selected: model.fill, includeNone: true) { hex in
                    model.fill = hex
                    emit()
                }
            }
            // Image/SVG nodes expose ONLY layers (z-order) and text size (F7),
            // so the paint controls below are hidden for them.
            if model.mode != .image {
            swatchRow(title: model.mode.showsFill ? "Outline" : "Color",
                      selected: model.stroke, includeNone: false) { hex in
                model.stroke = hex
                emit()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.opacity * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { model.opacity },
                        set: { model.opacity = $0; emit() }
                    ), in: 0.05...1)
                    Button("100%") { model.opacity = 1; emit() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9.5))
                        .help("Fully opaque")
                    Button("30%") { model.opacity = 0.3; emit() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9.5))
                        .help("Ghosted — good for grouping outlines")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.mode == .pencil ? "Width" : "Outline width")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Percentage of the slider's full range (0.5…8 pt), so the
                    // readout matches the Opacity row's "NN%" style.
                    Text("\(Int((currentWidth - 0.5) / (8 - 0.5) * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { currentWidth },
                        set: { model.strokeWidth = ($0 * 10).rounded() / 10; emit() }
                    ), in: 0.5...8)
                    // Live illustration: the actual stroke at the chosen
                    // width and color, inside a small chip.
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.75)
                        Capsule()
                            .fill(Color(nsColor: NSColor(hexFallback: model.stroke ?? "#8B95A5")))
                            .frame(width: 20, height: min(max(CGFloat(currentWidth), 1), 12))
                    }
                    .frame(width: 30, height: 20)
                    .help(String(format: "%.1f pt", currentWidth))
                }
            }
            } // end paint controls (hidden for .image)

            if model.mode.showsTextSize {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text size")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.textSize },
                        set: { model.textSize = $0; emit() }
                    )) {
                        Text("S").tag(TextSize.small)
                        Text("M").tag(TextSize.medium)
                        Text("L").tag(TextSize.large)
                        Text("XL").tag(TextSize.xl)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            if model.mode.showsFill {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { model.striped }, set: { model.striped = $0; emit() })) {
                        Text("Stripes").font(.system(size: 10))
                    }
                    Toggle(isOn: Binding(get: { model.dashed }, set: { model.dashed = $0; emit() })) {
                        Text("Dashed").font(.system(size: 10))
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            if model.mode == .selection || model.mode == .connector || model.mode == .image {
                VStack(alignment: .leading, spacing: 5) {
                    // Z-order clarity (F8): which layer, and where in the stack
                    // among elements sharing that layer.
                    if let chip = model.layerChipText {
                        HStack(spacing: 5) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(chip).font(.system(size: 10, weight: .medium))
                            if let z = model.zPositionText {
                                Text("· \(z)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Button { actions.sendToBack() } label: {
                            Label("To Back", systemImage: "square.3.layers.3d.bottom.filled")
                                .font(.system(size: 10))
                        }
                        .help("Send behind everything")
                        Button { actions.bringToFront() } label: {
                            Label("To Front", systemImage: "square.3.layers.3d.top.filled")
                                .font(.system(size: 10))
                        }
                        .help("Bring in front of everything")
                    }
                    HStack(spacing: 6) {
                        Button { actions.stepBackward() } label: {
                            Label("Backward", systemImage: "chevron.down")
                                .font(.system(size: 10))
                        }
                        .disabled(!model.canStepBackward)
                        .help("One step back within this layer")
                        Button { actions.stepForward() } label: {
                            Label("Forward", systemImage: "chevron.up")
                                .font(.system(size: 10))
                        }
                        .disabled(!model.canStepForward)
                        .help("One step forward within this layer")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if model.mode != .image {
                Button {
                    // Back to the app defaults for this mode — one click.
                    model.fill = model.mode == .shape ? Style.noFill : nil
                    model.stroke = nil
                    model.strokeWidth = nil
                    model.opacity = 1
                    model.textSize = .medium
                    model.striped = false
                    model.dashed = false
                    emit()
                } label: {
                    Label("Remove formatting", systemImage: "paintbrush.slash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Reset color, outline, width, and opacity to the defaults")
            }
        }
    }

    private var currentWidth: Double {
        model.strokeWidth ?? (model.mode == .pencil ? 2 : 1.25)
    }

    private func emit() {
        guard !model.isSeeding else { return }
        actions.styleChanged(model.style)
    }

    private func swatchRow(
        title: String, selected: String?, includeNone: Bool,
        choose: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if includeNone {
                    swatch(isSelected: selected == Style.noFill || selected == nil) {
                        choose(Style.noFill)
                    } content: {
                        // "No fill": a hollow swatch with a diagonal slash.
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                            Path { path in
                                path.move(to: CGPoint(x: 3, y: 15))
                                path.addLine(to: CGPoint(x: 15, y: 3))
                            }
                            .stroke(Color.red.opacity(0.7), lineWidth: 1.2)
                        }
                    }
                    .help("No background")
                }
                ForEach(Self.quickColors, id: \.self) { hex in
                    swatch(isSelected: selected == hex) {
                        choose(hex)
                    } content: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: NSColor(hexFallback: hex)))
                    }
                }
            }
        }
    }

    private func swatch<Content: View>(
        isSelected: Bool, action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? GraphiteStyle.accent : .clear, lineWidth: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

extension NSColor {
    /// Hex parse with a visible fallback — swatches never render invisible.
    convenience init(hexFallback hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The Inspector's embedded Style section: the same controls, seeded from
/// one element and applying straight back to it.
struct InspectorStyleSection: View {
    let style: Style
    let isInk: Bool
    let apply: (Style) -> Void

    @StateObject private var model = StylePanelModel()

    var body: some View {
        StyleControls(
            model: model,
            actions: StylePanelActions(
                styleChanged: apply,
                bringToFront: {},
                sendToBack: {}
            )
        )
        .onAppear { model.seed(from: style, mode: isInk ? .pencil : .selection) }
        .onChange(of: style) { _, newValue in
            model.seed(from: newValue, mode: isInk ? .pencil : .selection)
        }
    }
}
