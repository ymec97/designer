import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let systemImage: String
    /// Synonyms the fuzzy search also matches ("show", "chat", "ai"…) — the
    /// user's words, not just the menu's.
    var keywords: [String] = []
    let run: () -> Void

    var searchText: String {
        keywords.isEmpty ? title.lowercased() : (title + " " + keywords.joined(separator: " ")).lowercased()
    }
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
        // Score each command; keep matches, best first. Stable ordering for
        // equal scores preserves the natural command order.
        return model.commands
            .map { (command: $0, score: score(query: q, title: $0.searchText)) }
            .filter { $0.score > 0 }
            .enumerated()
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .map { $0.element.command }
    }

    /// 0 = no match. Every whitespace-separated token of the query must match
    /// somewhere in the title (order-independent — "flow record" still finds
    /// "Record Flow…"); the score sums per-token quality plus a bonus when
    /// the whole query is a literal prefix of the title.
    private func score(query: String, title: String) -> Int {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        var total = 0
        for token in tokens {
            let value = tokenScore(token, in: title)
            guard value > 0 else { return 0 } // every token must match
            total += value
        }
        if title.hasPrefix(query) { total += 100 }
        return total
    }

    /// One token against the title. Exact-ish matches rank highest; anything
    /// else falls through to fzf-style fuzzy scoring, so "smltrfc" finds
    /// "Simulate Traffic…" and near-misses still land.
    private func tokenScore(_ token: String, in title: String) -> Int {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(token) }) { return 200 + token.count }
        if title.contains(token) { return 160 }
        return fuzzyScore(token, in: title)
    }

    /// Greedy in-order character match with quality scoring: word-boundary
    /// hits and consecutive runs score high, scattered matches low. Tokens of
    /// five-plus characters may skip one character (typo forgiveness). 0 = no
    /// match.
    private func fuzzyScore(_ token: String, in text: String) -> Int {
        let haystack = Array(text)
        let needle = Array(token)
        var score = 0
        var hayIndex = 0
        var lastMatch = -2
        var skipsLeft = needle.count >= 5 ? 1 : 0
        var matched = 0

        for character in needle {
            var found: Int?
            var scan = hayIndex
            while scan < haystack.count {
                if haystack[scan] == character { found = scan; break }
                scan += 1
            }
            guard let position = found else {
                // Typo forgiveness: drop this query character once.
                if skipsLeft > 0 { skipsLeft -= 1; continue }
                return 0
            }
            matched += 1
            score += 4
            if position == lastMatch + 1 {
                score += 6 // consecutive run
            } else if position == 0 || !(haystack[position - 1].isLetter || haystack[position - 1].isNumber) {
                score += 8 // word boundary
            }
            lastMatch = position
            hayIndex = position + 1
        }
        // Too little actually matched to mean anything.
        guard matched >= 2 || matched == needle.count else { return 0 }
        return score
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
