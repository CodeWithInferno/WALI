import SwiftUI
import WALIAppRuntime

@main
struct WALIApp: App {
    var body: some Scene {
        WindowGroup("WALI") {
            WALIConnectedAppRootView()
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WALIAppCommands() }
    }
}
