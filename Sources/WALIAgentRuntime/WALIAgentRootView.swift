import SwiftUI
import WALIEngine
import WALIModel
import WALIUI
import WALIWire

/// The agent-owned root view hosted by the LSUIElement composition root.
public struct WALIAgentRootView: View {
    private let status: WALIRendererPresentation
    private let actions: any WALIUIActionHandling

    /// Creates the agent-owned status surface.
    public init(
        status: WALIRendererPresentation = .stopped,
        actions: any WALIUIActionHandling = NoopWALIUIActionHandler()
    ) {
        self.status = status
        self.actions = actions
    }

    public var body: some View {
        StatusPanel(status: status, actions: actions)
    }
}
