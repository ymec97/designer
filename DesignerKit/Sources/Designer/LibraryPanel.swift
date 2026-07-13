import SwiftUI
import DesignerModel
import DesignerPersistence

/// View state for the library panel.
final class LibraryPanelModel: ObservableObject {
    @Published var isVisible = false
    @Published var entries: [LibraryEntry] = []
    @Published var query = ""
    /// UUID → PNG thumbnail data, loaded lazily.
    @Published var thumbnails: [UUID: Data] = [:]
}

struct LibraryPanelActions {
    var insert: (LibraryEntry) -> Void
    /// Controller presents a rename prompt (NSAlert with a text field).
    var promptRename: (LibraryEntry) -> Void
    var delete: (LibraryEntry) -> Void
    var saveSelection: () -> Void
}

struct LibraryPanelContainer: View {
    @ObservedObject var model: LibraryPanelModel
    let actions: LibraryPanelActions

    var body: some View {
        if model.isVisible {
            LibraryPanel(model: model, actions: actions)
        }
    }
}

/// Floating library card (⌘Y): search, browse, and insert saved patterns.
struct LibraryPanel: View {
    @ObservedObject var model: LibraryPanelModel
    let actions: LibraryPanelActions

    private var filtered: [LibraryEntry] {
        let trimmed = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return model.entries }
        return model.entries.filter { entry in
            entry.name.lowercased().contains(trimmed)
                || entry.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered, id: \.id) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 260)
        .floatingPanel()
        .graphiteAccent()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Library").font(.system(size: 12, weight: .semibold))
            Text("⌘Y").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
            Spacer()
            Button(action: actions.saveSelection) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Save selection to library (⌥⌘S)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Search name or tag", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(model.entries.isEmpty ? "No saved patterns yet" : "No matches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.entries.isEmpty {
                Text("Select items and press ⌥⌘S")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func row(for entry: LibraryEntry) -> some View {
        Button {
            actions.insert(entry)
        } label: {
            HStack(spacing: 8) {
                thumbnail(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(entry.elementCount) item\(entry.elementCount == 1 ? "" : "s")")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        if !entry.tags.isEmpty {
                            Text(entry.tags.joined(separator: ", "))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .help("Insert “\(entry.name)”")
        .contextMenu {
            Button("Insert") { actions.insert(entry) }
            Button("Rename…") { actions.promptRename(entry) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(entry) }
        }
    }

    @ViewBuilder
    private func thumbnail(for entry: LibraryEntry) -> some View {
        if let data = model.thumbnails[entry.id], let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .frame(width: 46, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 46, height: 30)
                .overlay(Image(systemName: "square.on.square").font(.system(size: 12)).foregroundStyle(.tertiary))
        }
    }
}

