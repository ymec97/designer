import SwiftUI
import DesignerCanvas

struct AgentProposalPending {
    var summary: String
    var detail: String
    var note: String?
}

final class AgentProposalModel: ObservableObject {
    @Published var pending: AgentProposalPending?
}

struct AgentProposalActions {
    var accept: () -> Void
    var reject: () -> Void
}

/// Review banner for a staged agent proposal (F4). Renders nothing when there's
/// no pending proposal, so it never covers the canvas. Anchored top-center.
struct AgentProposalPanel: View {
    @ObservedObject var model: AgentProposalModel
    let actions: AgentProposalActions
    @State private var expanded = false

    var body: some View {
        if let pending = model.pending {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GraphiteStyle.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Claude proposes changes")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GraphiteStyle.ink)
                        Text(pending.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(GraphiteStyle.inkDim)
                        // Canvas legend: the ghost colors' meaning at a glance.
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: Graphite.proposalAdd))
                                    .frame(width: 7, height: 7)
                                Text("green + added").font(.system(size: 10)).fixedSize()
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: Graphite.proposalRemove))
                                    .frame(width: 7, height: 7)
                                Text("red ✕ removed").font(.system(size: 10)).fixedSize()
                            }
                        }
                        .foregroundStyle(GraphiteStyle.inkFaint)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 16)
                    Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                        Text(expanded ? "Hide" : "Review")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GraphiteStyle.accent)
                    Button("Reject", action: actions.reject)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(GraphiteStyle.inkDim)
                    Button("Accept", action: actions.accept)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(GraphiteStyle.accent)
                }

                if expanded {
                    Divider().padding(.vertical, 8)
                    if let note = pending.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(GraphiteStyle.ink)
                            .padding(.bottom, 6)
                    }
                    ScrollView {
                        Text(pending.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(GraphiteStyle.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: expanded ? 460 : 440)
            .floatingPanel(radius: 12)
            .graphiteAccent()
            .onChange(of: model.pending == nil) { isNil in
                if isNil { expanded = false }
            }
        }
    }
}
