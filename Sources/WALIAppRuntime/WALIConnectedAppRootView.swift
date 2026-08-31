import SwiftUI

/// Foreground composition surface that retains one live adapter per window.
public struct WALIConnectedAppRootView: View {
    @State private var coordinator = WALIAppCoordinator()

    public init() {}

    public var body: some View {
        WALIAppRootView(model: coordinator.model, actions: coordinator)
            .task { coordinator.start() }
            .onDisappear { coordinator.stop() }
    }
}
