import AppKit
import DesignerModel
import DesignerInterop
import DesignerAgent

/// App-level owner of the local agent (MCP) server. Bridges the server to
/// whichever board window is frontmost, and routes staged proposals to that
/// window's controller for review. Off until the user enables it.
final class AgentController: NSObject, AgentBoardBridge {
    static let shared = AgentController()

    let server = AgentServer()
    private(set) var isEnabled = false

    override init() {
        super.init()
        server.handler.bridge = self
    }

    /// Starts the loopback server; `onReady` fires on the main thread with the
    /// bound port once it's listening.
    func enable(onReady: @escaping (UInt16) -> Void) throws {
        try server.start { port in
            DispatchQueue.main.async { onReady(port) }
        }
        isEnabled = true
    }

    func disable() {
        server.stop()
        isEnabled = false
    }

    var endpointURL: String { server.endpointURL }

    // MARK: AgentBoardBridge (invoked on the server's background queue)

    func currentBoard() -> Board? {
        DispatchQueue.main.sync { Self.frontmostController()?.agentCurrentBoard() }
    }

    func stageProposal(_ proposed: Board, note: String?) -> BoardDiff {
        DispatchQueue.main.sync {
            guard let controller = Self.frontmostController() else { return BoardDiff() }
            return controller.presentAgentProposal(proposed, note: note)
        }
    }

    /// The controller for the frontmost board window (key window first, then
    /// any board window in z-order).
    static func frontmostController() -> CanvasViewController? {
        if let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController as? CanvasViewController {
            return controller
        }
        return NSApp.orderedWindows
            .compactMap { $0.contentViewController as? CanvasViewController }
            .first
    }
}
