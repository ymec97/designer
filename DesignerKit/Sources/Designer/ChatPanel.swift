import SwiftUI
import DesignerAgent

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, activity, error }
    let id = UUID()
    var role: Role
    var text: String
}

final class ChatPanelModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isThinking = false
    @Published var visible = false
    @Published var setupHint: String? // non-nil = CLI missing; shows guidance
    /// Provider capabilities + current choices ("" = provider default).
    @Published var provider = ChatEngine.claudeProvider
    @Published var modelChoice = ""
    @Published var effortChoice = ""
}

struct ChatPanelActions {
    var send: (String) -> Void
    var stop: () -> Void
    var newConversation: () -> Void
    var close: () -> Void
}

/// The in-app assistant drawer (F6): chat with Claude — billed to the user's
/// Claude subscription via the Claude Code CLI — while it reads and proposes
/// edits to the open board through the local MCP tools.
struct ChatPanel: View {
    @ObservedObject var model: ChatPanelModel
    let actions: ChatPanelActions
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            optionsRow
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(width: 320, height: 460)
        .floatingPanel(radius: 12)
        .graphiteAccent()
    }

    /// Model + thinking-effort selectors, driven by the provider's declared
    /// capabilities (Claude today; Codex etc. slot in via ProviderInfo).
    private var optionsRow: some View {
        HStack(spacing: 10) {
            Picker(selection: $model.modelChoice) {
                ForEach(model.provider.models) { choice in
                    Text(choice.label).tag(choice.id)
                }
            } label: {
                Text("Model").font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .help("Model for the next message (Default = your Claude Code setting)")

            Picker(selection: $model.effortChoice) {
                ForEach(model.provider.efforts) { choice in
                    Text(choice.label).tag(choice.id)
                }
            } label: {
                Text("Thinking").font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .help("Reasoning effort for the next message")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .disabled(model.setupHint != nil)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GraphiteStyle.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Assistant").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GraphiteStyle.ink)
                Text("Claude · your subscription, via Claude Code")
                    .font(.system(size: 9.5))
                    .foregroundStyle(GraphiteStyle.inkFaint)
            }
            Spacer()
            Button { actions.newConversation() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 12))
                    .foregroundStyle(GraphiteStyle.inkDim)
            }
            .buttonStyle(.plain)
            .help("New conversation")
            Button { actions.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GraphiteStyle.inkDim)
            }
            .buttonStyle(.plain)
            .help("Close (⇧⌘A)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let hint = model.setupHint {
                        setupCard(hint)
                    } else if model.messages.isEmpty {
                        Text("Ask for anything on this board:\n“Add a Redis cache in front of the orders service”\n“Build a checkout system: web app → gateway → …”\n\nEdits arrive as proposals you Accept or Reject.")
                            .font(.system(size: 11))
                            .foregroundStyle(GraphiteStyle.inkDim)
                            .padding(.top, 6)
                    }
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if model.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 11))
                                .foregroundStyle(GraphiteStyle.inkDim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .onChange(of: model.messages.count) { _ in
                if let last = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(GraphiteStyle.accent))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(GraphiteStyle.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(GraphiteStyle.accentSoft.opacity(0.45)))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            HStack(spacing: 5) {
                Image(systemName: "gearshape.2").font(.system(size: 9))
                Text(message.text).font(.system(size: 10.5))
            }
            .foregroundStyle(GraphiteStyle.inkFaint)
        case .error:
            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func setupCard(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Set up the assistant", systemImage: "wrench.adjustable")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GraphiteStyle.ink)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(GraphiteStyle.inkDim)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(GraphiteStyle.accentSoft.opacity(0.4)))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this board…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(submit)
                .disabled(model.setupHint != nil)
            if model.isThinking {
                Button(action: actions.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(GraphiteStyle.accent)
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(model.input.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? GraphiteStyle.inkFaint : GraphiteStyle.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.setupHint != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func submit() {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isThinking else { return }
        model.input = ""
        actions.send(text)
    }
}
