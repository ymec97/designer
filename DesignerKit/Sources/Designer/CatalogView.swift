import SwiftUI
import DesignerCanvas
import DesignerModel
import DesignerPersistence

final class CatalogModel: ObservableObject {
    @Published var entries: [CatalogEntry] = []
    @Published var query = ""
    /// Lazily rendered thumbnails, keyed by board URL.
    @Published var thumbnails: [URL: NSImage] = [:]

    func reload() { entries = BoardCatalog.entries() }
}

/// The start screen (F1): a grid whose first tile is New Canvas and the rest
/// are previously created boards, newest first — jump straight back in.
struct CatalogView: View {
    @ObservedObject var model: CatalogModel
    let onNew: () -> Void
    let onOpen: (URL) -> Void
    let onOpenElsewhere: () -> Void
    let onExample: () -> Void
    let onDelete: (CatalogEntry) -> Void

    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 260), spacing: 20)]

    private var filtered: [CatalogEntry] {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(GraphiteStyle.hairline)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    NewCanvasTile(action: onNew)
                    ForEach(filtered) { entry in
                        BoardTile(
                            entry: entry,
                            thumbnail: model.thumbnails[entry.url],
                            action: { onOpen(entry.url) }
                        )
                        .contextMenu {
                            Button("Open") { onOpen(entry.url) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { onDelete(entry) }
                        }
                        .onAppear { loadThumbnail(entry) }
                    }
                }
                .padding(28)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: Graphite.canvas))
        .graphiteAccent()
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(GraphiteStyle.accent)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "square.on.square").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Designer").font(.system(size: 15, weight: .semibold))
                    Text("\(model.entries.count) board\(model.entries.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(GraphiteStyle.inkFaint)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search boards", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 150)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: Graphite.panel), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(GraphiteStyle.hairline, lineWidth: 0.75))
            Button(action: onOpenElsewhere) {
                Label("Open…", systemImage: "folder").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func loadThumbnail(_ entry: CatalogEntry) {
        guard model.thumbnails[entry.url] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let boardURL = entry.url.appendingPathComponent(BoardPackage.boardFileName)
            guard let data = try? Data(contentsOf: boardURL),
                  let board = try? BoardSerialization.board(from: data) else { return }
            DispatchQueue.main.async {
                model.thumbnails[entry.url] = BoardSnapshot.image(
                    of: board, pointSize: CGSize(width: 208, height: 132)
                )
            }
        }
    }
}

private struct NewCanvasTile: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 26, weight: .medium))
                Text("New Canvas").font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 132)
            .foregroundStyle(.white)
            .background(GraphiteStyle.accent.opacity(hovering ? 1 : 0.92), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Create a new board (⌘N)")
    }
}

private struct BoardTile: View {
    let entry: CatalogEntry
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Graphite.panel))
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().padding(6)
                    } else {
                        Image(systemName: "square.dashed").font(.system(size: 22)).foregroundStyle(.quaternary)
                    }
                }
                .frame(height: 132)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? GraphiteStyle.accent : GraphiteStyle.hairline, lineWidth: hovering ? 1.5 : 0.75))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(GraphiteStyle.ink)
                    Text(entry.modified.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11)).foregroundStyle(GraphiteStyle.inkFaint)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open “\(entry.title)”")
    }
}
