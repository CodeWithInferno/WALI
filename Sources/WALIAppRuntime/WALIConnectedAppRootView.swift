import SwiftUI

/// Foreground composition surface that retains one live adapter per window.
public struct WALIConnectedAppRootView: View {
    @State private var coordinator: WALIAppCoordinator
    @State private var marketplace: MarketplaceCoordinator

    public init() {
        let coordinator = WALIAppCoordinator()
        _coordinator = State(initialValue: coordinator)
        _marketplace = State(initialValue: MarketplaceCoordinator.configured(
            installHandler: { prepared in
                try await coordinator.installCatalogRelease(prepared)
            },
            securityHandler: { security in
                try await coordinator.updateCatalogSecurityState(security)
            }
        ))
    }

    public var body: some View {
        WALIAppRootView(
            model: coordinator.model,
            actions: coordinator,
            marketplace: marketplace
        )
            .task { coordinator.start() }
            .onDisappear { coordinator.stop() }
    }
}
