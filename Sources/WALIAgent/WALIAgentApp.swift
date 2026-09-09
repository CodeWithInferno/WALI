import SwiftUI
import WALIAgentRuntime

@main
struct WALIAgentApp: App {
    #if WALI_APP_STORE
    @NSApplicationDelegateAdaptor(WALIStoreAgentApplicationDelegate.self) private var lifecycleDelegate
    @State private var controller = WALIAgentController.shared
    #else
    @State private var controller = WALIAgentController()
    #endif

    init() {
        controller.start()
    }

    var body: some Scene {
        WALIMenuBarScene(model: controller.model, actions: controller)

        Settings {
            WALIAgentRootView(
                status: controller.model.snapshot.renderer,
                actions: controller
            )
        }
    }
}
