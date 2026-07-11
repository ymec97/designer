import SwiftUI
import DesignerModel

/// M0 stand-in for the canvas: proves the document pipeline (create, mutate,
/// autosave, reopen) end to end. Replaced by the real canvas in M1.
struct BoardPlaceholderView: View {
    @ObservedObject var document: BoardDocument

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(document.board.title)
                .font(.title2)
            Text("\(nodeCount) blocks · \(document.board.layers.count) layer\(document.board.layers.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Add Sample Block") {
                document.addSampleNode()
            }
            .keyboardShortcut("b", modifiers: .command)
            Text("M0 placeholder — the canvas arrives in M1.\nAdd blocks, save (⌘S), close, and reopen to exercise persistence.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nodeCount: Int {
        document.board.elements.filter { $0.node != nil }.count
    }
}
