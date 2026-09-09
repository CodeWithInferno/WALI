#if WALI_APP_STORE
import Foundation
import WALIWire

private final class StoreLifecycleReply: @unchecked Sendable {
    let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }
}

/// Exported only over a connection pinned to this distribution's signed agent.
final class StoreAppLifecycleEndpoint: NSObject, WALIAppLifecycleXPCProtocol, @unchecked Sendable {
    private let prepareToTerminate: @MainActor @Sendable () -> Void

    init(prepareToTerminate: @escaping @MainActor @Sendable () -> Void) {
        self.prepareToTerminate = prepareToTerminate
    }

    func agentWillTerminate(reply: @escaping () -> Void) {
        let reply = StoreLifecycleReply(reply)
        Task { @MainActor in
            prepareToTerminate()
            reply.invoke()
        }
    }
}
#endif
