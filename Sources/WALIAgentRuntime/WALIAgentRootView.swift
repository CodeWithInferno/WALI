import SwiftUI
import WALIEngine
import WALIModel
import WALIUI
import WALIWire

/// The agent-owned root view hosted by the LSUIElement composition root.
public struct WALIAgentRootView: View {
    /// Creates the agent root view.
    public init() {}

    /// The placeholder status surface for the foundation scaffold.
    public var body: some View {
        StatusPanel()
    }
}

