import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let systemImage: String
    let run: () -> Void
}

final class CommandPaletteModel: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var selectedIndex = 0
    var commands: [PaletteCommand] = []
}

/// ⌘K command palette (D17: depth lives here, not in chrome). Fuzzy-filters
/// commands; ↑/↓ to move, ↵ to run, esc to close.
struct CommandPalette: View {
    @ObservedObject var model: CommandPaletteModel
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    private var filtered: [PaletteCommand] {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.commands }
        return model.commands.filter { fuzzyMatch(q, $0.title.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Type a command…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit(runSelected)
                    .onChange(of: model.query) { _, _ in model.selectedIndex = 0 }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            row(command, isSelected: index == clampedIndex)
                                .id(index)
                                .onTapGesture { model.selectedIndex = index; runSelected() }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: model.selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.05)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(GraphiteStyle.hairline, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        .graphiteAccent()
        .onAppear { fieldFocused = true; model.selectedIndex = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private var clampedIndex: Int {
        guard !filtered.isEmpty else { return 0 }
        return min(max(model.selectedIndex, 0), filtered.count - 1)
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? AnyShapeStyle(GraphiteStyle.accent) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        model.selectedIndex = (clampedIndex + delta + filtered.count) % filtered.count
    }

    private func runSelected() {
        guard filtered.indices.contains(clampedIndex) else { return }
        let command = filtered[clampedIndex]
        close()
        command.run()
    }

    /// Subsequence fuzzy match: all query chars appear in order.
    private func fuzzyMatch(_ query: String, _ text: String) -> Bool {
        if text.contains(query) { return true }
        var index = text.startIndex
        for character in query {
            guard let found = text[index...].firstIndex(of: character) else { return false }
            index = text.index(after: found)
        }
        return true
    }
}

/// A full-canvas hosting view that lets mouse events fall through to the
/// canvas whenever the palette is hidden (an ordinary NSHostingView would
/// swallow every click as an invisible overlay).
final class PalettePassthroughHostingView<Content: View>: NSHostingView<Content> {
    var isActive: () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive() ? super.hitTest(point) : nil
    }
}

struct CommandPaletteContainer: View {
    @ObservedObject var model: CommandPaletteModel
    let close: () -> Void

    var body: some View {
        if model.isVisible {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001) // catch outside clicks
                    .onTapGesture { close() }
                CommandPalette(model: model, close: close)
                    .padding(.top, 90)
            }
            .ignoresSafeArea()
        }
    }
}
