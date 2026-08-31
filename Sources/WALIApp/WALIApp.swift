import SwiftUI
import WALIAppRuntime

@main
struct WALIApp: App {
    var body: some Scene {
        WindowGroup("WALI") {
            WALIAppRootView()
        }
        .defaultSize(width: 720, height: 480)
    }
}

