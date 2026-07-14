import SwiftUI
import DesignerCanvas

final class ZoomHUDModel: ObservableObject {
    @Published var scale: Double = 1
}

struct ZoomHUDActions {
    var actualSize: () -> Void
    var zoomToFit: () -> Void
}

/// P1 (zoom drift): a small always-visible readout of the current zoom, so
/// you can't lose track of it. Click the percentage for 100%; the fit button
/// frames everything. The percentage tints accent when you're away from 1×.
struct ZoomHUD: View {
    @ObservedObject var model: ZoomHUDModel
    let actions: ZoomHUDActions

    private var percentText: String {
        "\(max(1, Int((model.scale * 100).rounded())))%"
    }

    private var isDrifted: Bool { abs(model.scale - 1) > 0.01 }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.actualSize) {
                Text(percentText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isDrifted ? GraphiteStyle.accent : GraphiteStyle.inkDim)
                    .frame(minWidth: 40)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Current zoom — click for 100% (⌘0)")
            Divider().frame(height: 14)
            Button(action: actions.zoomToFit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left.rectangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GraphiteStyle.inkDim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom to fit everything (⌘9)")
        }
        .floatingPanel(radius: 9)
        .graphiteAccent()
    }
}
