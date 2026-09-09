#if WALI_APP_STORE
import AppKit

/// App lifetime owns the coordinator even after its last window closes.
@MainActor
public final class WALIStoreApplicationDelegate: NSObject, NSApplicationDelegate {
    private var quitTask: Task<Void, Never>?

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = WALIAppCoordinator.shared
        if coordinator.quitWasAcknowledged { return .terminateNow }
        guard quitTask == nil else { return .terminateLater }
        quitTask = Task { @MainActor in
            do {
                try await coordinator.prepareForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                sender.reply(toApplicationShouldTerminate: false)
            }
            quitTask = nil
        }
        return .terminateLater
    }
}
#endif
