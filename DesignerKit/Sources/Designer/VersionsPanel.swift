import SwiftUI
import DesignerModel
import DesignerCanvas
import DesignerPersistence

struct VersionRowInfo: Identifiable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var kind: VersionArchive.VersionMeta.Kind
    var elementCount: Int
    var thumbnail: NSImage?

    static func == (lhs: VersionRowInfo, rhs: VersionRowInfo) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.createdAt == rhs.createdAt
            && lhs.kind == rhs.kind && lhs.elementCount == rhs.elementCount
    }
}

final class VersionsPanelModel: ObservableObject {
    @Published var rows: [VersionRowInfo] = []
    @Published var visible = false
    /// The version whose diff-vs-current is ghosted on the canvas.
    @Published var previewedID: UUID?
}

struct VersionsPanelActions {
    var saveNow: () -> Void
    var togglePreview: (UUID) -> Void
    var restore: (UUID) -> Void
    var rename: (UUID, String) -> Void
    var delete: (UUID) -> Void
}

/// F3 — the board's version history: named snapshots you can preview as a
/// ghost diff against the current board, restore (one undo step), or prune.
struct VersionsPanel: View {
    @ObservedObject var model: VersionsPanelModel
    let actions: VersionsPanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Versions").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GraphiteStyle.ink)
                Text("⇧⌘H").font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
                Spacer()
                Button(action: actions.saveNow) {
                    Label("Save Version", systemImage: "clock.badge.checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GraphiteStyle.accent)
                .help("Snapshot the current board into the history")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.rows.isEmpty {
                Text("No versions yet.\nSave one before big changes; one is\ncaptured automatically when you accept\nan assistant proposal.")
                    .font(.system(size: 11))
                    .foregroundStyle(GraphiteStyle.inkDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            VersionRow(
                                row: row,
                                isPreviewed: model.previewedID == row.id,
                                actions: actions
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 292)
        .floatingPanel(radius: 12)
        .graphiteAccent()
    }
}

private struct VersionRow: View {
    let row: VersionRowInfo
    let isPreviewed: Bool
    let actions: VersionsPanelActions
    @State private var editedName = ""

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    TextField("Version name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GraphiteStyle.ink)
                        .onSubmit { actions.rename(row.id, editedName) }
                        .onAppear { editedName = row.name }
                        .onChange(of: row.name) { editedName = $0 }
                    if row.kind == .auto {
                        Text("auto")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(GraphiteStyle.accentSoft, in: Capsule())
                            .foregroundStyle(GraphiteStyle.inkDim)
                    }
                }
                Text("\(row.createdAt.formatted(.relative(presentation: .named))) · \(row.elementCount) element\(row.elementCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(GraphiteStyle.inkFaint)
            }
            Spacer(minLength: 4)
            rowButton(isPreviewed ? "eye.fill" : "eye",
                      help: "Preview changes vs the current board",
                      active: isPreviewed) { actions.togglePreview(row.id) }
            rowButton("arrow.uturn.backward.circle",
                      help: "Restore this version (undoable; the current board is snapshotted first)",
                      active: false) { actions.restore(row.id) }
            rowButton("trash", help: "Delete this version", active: false) { actions.delete(row.id) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isPreviewed ? GraphiteStyle.accentSoft.opacity(0.5) : .clear)
        )
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = row.thumbnail {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(GraphiteStyle.hairline, lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(GraphiteStyle.accentSoft.opacity(0.4))
                .frame(width: 44, height: 28)
                .overlay(Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(GraphiteStyle.inkFaint))
        }
    }

    private func rowButton(_ icon: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .foregroundStyle(active ? GraphiteStyle.accent : GraphiteStyle.inkDim)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
