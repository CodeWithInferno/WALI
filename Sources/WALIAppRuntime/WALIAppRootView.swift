import SwiftUI
import WALIModel
import WALIUI
import WALIWire

/// The app-owned root view hosted by the foreground composition root.
public struct WALIAppRootView: View {
    /// Creates the foreground app root view.
    public init() {}

    /// The placeholder status surface for the foundation scaffold.
    public var body: some View {
        StatusPanel()
    }
}

