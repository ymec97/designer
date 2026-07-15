import Foundation
import DesignerModel
import DesignerInterop

/// The app-side hook the MCP handler calls into. Implemented by the running
/// document/controller. All methods are invoked from the server's background
/// queue; the implementation is responsible for hopping to the main thread to
/// touch document state.
public protocol AgentBoardBridge: AnyObject {
    /// The board the agent is reading, or nil if no document is open.
    func currentBoard() -> Board?

    /// Stage `proposed` for the user to review and approve. Returns the diff
    /// against the current board (which the tool echoes back to the agent).
    /// Nothing is applied until the user accepts in the app.
    @discardableResult
    func stageProposal(_ proposed: Board, note: String?) -> BoardDiff

    /// Whether a previously staged proposal is still awaiting Accept/Reject.
    func hasPendingProposal() -> Bool

    /// Show or hide a layer by name — applied IMMEDIATELY (view state, not
    /// content; it's one undoable step). Returns an error message, or nil.
    func setLayerVisibility(layerName: String, visible: Bool) -> String?
}

public extension AgentBoardBridge {
    func hasPendingProposal() -> Bool { false }
    func setLayerVisibility(layerName: String, visible: Bool) -> String? {
        "Layer visibility is not available in this context."
    }
}
