import AppKit
import SwiftUI
import DesignerModel

// MARK: - View state

/// Drives the one-time "this board is getting dense" nudge that suggests
/// switching connector captions to On Focus.
final class DensitySuggestionModel: ObservableObject {
    @Published var isVisible = false
}

// MARK: - Banner

/// A floating, non-modal suggestion shown once when a board first gets busy.
struct DensitySuggestionBanner: View {
    @ObservedObject var model: DensitySuggestionModel
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if model.isVisible {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(GraphiteStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This board is getting dense")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Show connector captions only on focus to cut the clutter")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 20)
                Button { onSwitch() } label: {
                    Label("Switch to On Focus", systemImage: "scope")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .help("Keep labels only on selected, hovered, or flow-highlighted connectors")
                Button("Dismiss") { onDismiss() }
                    .font(.system(size: 10.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .floatingPanel(radius: 10)
            .graphiteAccent()
        }
    }
}

// MARK: - Controller wiring

extension CanvasViewController {
    /// Connector count at which the nudge first fires. A tunable ceiling — the
    /// reference "cluttered" board sits well below this, so it won't nag on
    /// medium diagrams.
    static let densitySuggestionThreshold = 40
    private static let densitySuggestionShownPrefix = "DensitySuggestionShown."

    /// Installs the density-nudge banner; called once from viewDidLoad.
    func installDensitySuggestion() {
        let banner = DensitySuggestionBanner(
            model: densitySuggestionModel,
            onSwitch: { [weak self] in
                self?.densitySuggestionModel.isVisible = false
                self?.applyCaptionMode(.onFocus)
            },
            onDismiss: { [weak self] in self?.densitySuggestionModel.isVisible = false }
        )
        let host = NSHostingView(rootView: banner)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 62),
        ])
    }

    /// Fires the nudge the first time a board crosses the connector-count
    /// threshold while still in Always mode. The "shown" flag lives per-board in
    /// UserDefaults, so it never re-fires for that board and never dirties the
    /// document (unlike storing it in `extra`).
    func evaluateDensitySuggestion(_ board: Board) {
        // Only relevant while captions are Always — if the user has already
        // moved off it, there's nothing to suggest.
        guard board.captionMode == .always else {
            densitySuggestionModel.isVisible = false
            return
        }
        let connectors = board.elements.values.reduce(0) { $0 + ($1.edge != nil ? 1 : 0) }
        guard connectors >= Self.densitySuggestionThreshold else { return }
        let key = Self.densitySuggestionShownPrefix + board.id.rawValue.uuidString
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        densitySuggestionModel.isVisible = true
    }
}
