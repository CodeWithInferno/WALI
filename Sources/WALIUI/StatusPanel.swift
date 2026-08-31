import SwiftUI
import WALIModel

/// Placeholder shared status content for the WALI application processes.
public struct StatusPanel: View {
    /// Creates the foundation status panel.
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label("WALI", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Native foundation scaffold")
        }
        .frame(minWidth: 360, minHeight: 240)
        .accessibilityIdentifier("WALI.StatusPanel")
    }
}

