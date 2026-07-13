import SwiftUI

final class SimulationTransportModel: ObservableObject {
    @Published var active = false
    @Published var paused = false
    @Published var speed: Double = 1
}

struct SimulationTransportActions {
    var togglePause: () -> Void
    var restart: () -> Void
    var setSpeed: (Double) -> Void
    var exit: () -> Void
}

/// Bottom transport shown while a traffic simulation runs (F2). Renders
/// nothing (zero size) when inactive, so it never covers the canvas.
struct SimulationTransport: View {
    @ObservedObject var model: SimulationTransportModel
    let actions: SimulationTransportActions

    private let speeds: [Double] = [0.5, 1, 2]

    var body: some View {
        if model.active {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(GraphiteStyle.accent).frame(width: 7, height: 7)
                    Text("Simulating traffic").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GraphiteStyle.ink)
                }
                Divider().frame(height: 18)
                controlButton(model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause") {
                    actions.togglePause()
                }
                controlButton("arrow.counterclockwise", help: "Restart") { actions.restart() }
                Divider().frame(height: 18)
                Picker("", selection: Binding(get: { model.speed }, set: { actions.setSpeed($0) })) {
                    ForEach(speeds, id: \.self) { s in
                        Text(s == 1 ? "1×" : (s < 1 ? "½×" : "\(Int(s))×")).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 128)
                .labelsHidden()
                Divider().frame(height: 18)
                Button(action: actions.exit) {
                    Text("Done").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(GraphiteStyle.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .floatingPanel(radius: 12)
            .graphiteAccent()
        }
    }

    private func controlButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 24, height: 22)
                .foregroundStyle(GraphiteStyle.ink)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
