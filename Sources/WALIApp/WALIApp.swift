import SwiftUI
import WALIAppRuntime

@main
struct WALIApp: App {
    #if WALI_APP_STORE
    @NSApplicationDelegateAdaptor(WALIStoreApplicationDelegate.self) private var lifecycleDelegate
    #endif
    var body: some Scene {
        WindowGroup("WALI") {
            WALIConnectedAppRootView()
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WALIAppCommands() }
    }
}
