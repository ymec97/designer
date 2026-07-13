import Foundation
import DesignerAgent

/// Runs the in-app assistant (F6) by bridging to the Claude Code CLI — the
/// only path that bills the user's Claude subscription rather than an API
/// key. One CLI invocation per user message; `--resume` keeps the
/// conversation. The CLI talks back to Designer through the local MCP server,
/// so board edits arrive as reviewable proposals like any other agent.
final class ChatEngine {
    enum SetupState: Equatable {
        case ready(path: String)
        case notInstalled
    }

    /// Events delivered on the main queue.
    var onEvent: ((ChatStreamEvent) -> Void)?

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private(set) var sessionID: String?
    var isRunning: Bool { process?.isRunning ?? false }

    /// Where the Claude Code CLI lives. Checks the common install locations
    /// plus PATH.
    static func locateClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let paths = ProcessInfo.processInfo.environment["PATH"] {
            candidates += paths.split(separator: ":").map { "\($0)/claude" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var setupState: SetupState {
        Self.locateClaude().map { .ready(path: $0) } ?? .notInstalled
    }

    static let designerTools = [
        "mcp__designer__describe_board",
        "mcp__designer__get_board",
        "mcp__designer__search_board",
        "mcp__designer__propose_board",
    ]

    static let steeringPrompt = """
    You are the assistant inside Designer, a macOS app for software-architecture diagrams. \
    The user's open board is available ONLY through the designer MCP tools: describe_board, \
    get_board, search_board, propose_board. To create or change anything on the canvas: call \
    get_board, edit that JSON, and submit the COMPLETE edited board via propose_board — the \
    user reviews and accepts it in the app. Never read or write files, never run commands; \
    work only through those tools. Keep replies brief — the user sees proposed changes as a \
    visual diff in the app, so don't restate the whole board in text.
    """

    /// Sends one user message. Streams events until the CLI exits.
    func send(_ prompt: String, mcpEndpoint: String) {
        stop()
        guard let claude = Self.locateClaude() else {
            onEvent?(.finished(success: false, summary: "Claude Code CLI not found."))
            return
        }

        // MCP config file pointing the CLI at this app's local server.
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("designer-chat-mcp-\(ProcessInfo.processInfo.processIdentifier).json")
        let config = #"{"mcpServers":{"designer":{"type":"http","url":"\#(mcpEndpoint)"}}}"#
        try? config.write(to: configURL, atomically: true, encoding: .utf8)

        // Neutral working directory so the CLI doesn't pick up repo context.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("designer-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--mcp-config", configURL.path,
            "--strict-mcp-config",
            "--allowedTools", Self.designerTools.joined(separator: ","),
            "--append-system-prompt", Self.steeringPrompt,
        ]
        if let sessionID {
            arguments += ["--resume", sessionID]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = workDir
        // The CLI needs a sane PATH for its own node runtime.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/usr/local/bin:/opt/homebrew/bin"
        environment["PATH"] = [extraPaths, environment["PATH"] ?? ""].joined(separator: ":")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdoutBuffer = Data()
        stderrBuffer = Data()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.stderrBuffer.append(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.finishIfNeeded(exitCode: finished.terminationStatus)
            }
        }

        self.process = process
        sawResult = false
        do {
            try process.run()
        } catch {
            onEvent?(.finished(success: false, summary: "Couldn't launch the Claude CLI: \(error.localizedDescription)"))
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func resetConversation() {
        stop()
        sessionID = nil
    }

    // MARK: Stream handling

    private var sawResult = false

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        for line in ChatStreamParser.drainLines(from: &stdoutBuffer) {
            for event in ChatStreamParser.parse(line) {
                switch event {
                case .sessionStarted(let id):
                    sessionID = id
                case .finished:
                    sawResult = true
                case .ignored:
                    continue
                default:
                    break
                }
                if case .ignored = event { continue }
                onEvent?(event)
            }
        }
    }

    /// If the CLI died without emitting a result line (crash, auth failure),
    /// synthesize a finish so the UI never hangs on "thinking…".
    private func finishIfNeeded(exitCode: Int32) {
        process = nil
        guard !sawResult else { return }
        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hint: String
        if stderrText.localizedCaseInsensitiveContains("log in")
            || stderrText.localizedCaseInsensitiveContains("authenticate") {
            hint = "Claude Code isn't signed in. Run `claude` in Terminal once and log in with your Claude subscription."
        } else if stderrText.isEmpty {
            hint = "The Claude CLI exited unexpectedly (code \(exitCode))."
        } else {
            hint = String(stderrText.prefix(300))
        }
        onEvent?(.finished(success: false, summary: hint))
    }
}
