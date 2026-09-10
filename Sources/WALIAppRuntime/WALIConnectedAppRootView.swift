import SwiftUI

/// Each window owns its intentions and presentation; all share one auth service.
public struct WALIConnectedAppRootView: View {
    private static let foregroundServices = MarketplaceForegroundServices(bundle: .main)
    @State private var coordinator: WALIAppCoordinator
    @State private var marketplace: MarketplaceCoordinator
    @State private var visibilityID = UUID()

    public init() {
        #if WALI_APP_STORE
        let coordinator = WALIAppCoordinator.shared
        #else
        let coordinator = WALIAppCoordinator()
        #endif
        _coordinator = State(initialValue: coordinator)
        _marketplace = State(initialValue: MarketplaceCoordinator.configured(
            services: Self.foregroundServices,
            installHandler: { prepared in
                try await coordinator.installCatalogRelease(prepared)
            },
            securityHandler: { security in
                try await coordinator.updateCatalogSecurityState(security)
            }
        ))
    }

    public var body: some View {
        Group {
            #if WALI_APP_STORE
            if coordinator.backgroundState != .ready {
                backgroundConsent
            } else {
                content
            }
            #else
            content
            #endif
        }
        #if WALI_APP_STORE
        .background(WindowVisibilityReader { visible in
            if visible { coordinator.windowDidAppear(visibilityID) }
            else { coordinator.windowDidDisappear(visibilityID) }
        })
        #else
        .onAppear { coordinator.windowDidAppear(visibilityID) }
        #endif
        .onDisappear { coordinator.windowDidDisappear(visibilityID) }
    }

    private var content: some View {
        WALIAppRootView(
            model: coordinator.model, actions: coordinator, marketplace: marketplace,
            preparePresentation: coordinator.preparePresentation
        )
    }

    #if WALI_APP_STORE
    private var backgroundConsent: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Keep your wallpaper playing")
                .font(.title2.weight(.semibold))
            Text("WALI uses a background service for desktop playback and video preparation. Playback continues when you close this window. Quit WALI from either menu to stop it completely.")
                .multilineTextAlignment(.center)
            Text("Launching WALI at login is a separate choice in Settings. Quit any other edition of WALI before starting playback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            switch coordinator.backgroundState {
            case .needsConsent:
                Button("Allow Background Playback") { coordinator.allowBackgroundPlayback() }
                    .buttonStyle(.borderedProminent)
            case .needsApproval:
                Text("Approve WALI under Login Items in System Settings, then try again.")
                HStack {
                    Button("Open Login Items") { coordinator.openBackgroundApprovalSettings() }
                    Button("Try Again") { coordinator.start() }
                }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { coordinator.start() }
            case .starting: ProgressView("Starting WALI…")
            case .ready: EmptyView()
            }
        }
        .frame(maxWidth: 480)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WALI.BackgroundPlaybackConsent")
    }
    #endif
}
