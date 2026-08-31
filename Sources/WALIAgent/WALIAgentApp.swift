import SwiftUI
import WALIAgentRuntime

@main
struct WALIAgentApp: App {
    @State private var controller = WALIAgentController()

    init() {
        controller.start()
    }

    var body: some Scene {
        WALIMenuBarScene(model: controller.model, actions: controller)

        Settings {
            WALIAgentRootView()
        }
    }
}
