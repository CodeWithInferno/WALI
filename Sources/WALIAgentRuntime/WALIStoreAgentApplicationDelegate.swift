#if WALI_APP_STORE
import AppKit

@MainActor
public final class WALIStoreAgentApplicationDelegate: NSObject, NSApplicationDelegate {
    private var quitTask: Task<Void, Never>?

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = WALIAgentController.shared
        if controller.quitPrepared { return .terminateNow }
        guard quitTask == nil else { return .terminateLater }
        quitTask = Task { @MainActor in
            do {
                try await controller.prepareForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                controller.model.snapshot.notice = .init(
                    kind: .error, title: "WALI Could Not Finish Quitting", message: error.localizedDescription
                )
                sender.reply(toApplicationShouldTerminate: false)
            }
            quitTask = nil
        }
        return .terminateLater
    }
}
#endif
