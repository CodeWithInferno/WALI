#if !WALI_APP_STORE
import AppKit

/// Explicit Quit owns a connection independently of the foreground windows.
@MainActor
public final class WALIDirectApplicationDelegate: NSObject, NSApplicationDelegate {
    private let lifetime: DirectForegroundLifetime?
    private let quitAgent: @MainActor () async throws -> Void
    private let reply: @MainActor (Bool) -> Void
    private let reportFailure: @MainActor (Error) -> Void
    private var quitTask: Task<Void, Never>?
    private var quitWasAcknowledged = false

    public override convenience init() {
        let connection = AgentConnection()
        let lifecycle = AgentLifecycleController()
        let lifetime = DirectForegroundLifetime.shared
        self.init(
            lifetime: lifetime,
            quitAgent: {
                if try lifetime.canQuitWithoutAgent(using: lifecycle) { return }
                _ = try await connection.send(.quit)
            },
            reply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
            reportFailure: { error in
                let alert = NSAlert()
                alert.messageText = "WALI Could Not Finish Quitting"
                alert.informativeText = "\(error.localizedDescription) Try Quit again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        )
    }

    init(
        lifetime: DirectForegroundLifetime? = nil,
        quitAgent: @escaping @MainActor () async throws -> Void,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.lifetime = lifetime
        self.quitAgent = quitAgent
        self.reply = reply
        self.reportFailure = reportFailure
        super.init()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestQuit()
    }

    func requestQuit() -> NSApplication.TerminateReply {
        if quitWasAcknowledged { return .terminateNow }
        guard quitTask == nil else { return .terminateLater }
        lifetime?.beginQuit()
        quitTask = Task { @MainActor in
            do {
                try await quitAgent()
                quitWasAcknowledged = true
                quitTask = nil
                reply(true)
            } catch {
                lifetime?.cancelQuit()
                quitTask = nil
                reply(false)
                reportFailure(error)
            }
        }
        return .terminateLater
    }
}
/// Admission belongs to the application lifetime; each window retains its own
/// presentation state and is held weakly here.
@MainActor
final class DirectForegroundLifetime {
    static let shared = DirectForegroundLifetime()
    private struct Participant {
        weak var coordinator: WALIAppCoordinator?
    }
    private var participants: [Participant] = []
    private var isQuitting = false
    private var agentWasActive = false

    func register(_ coordinator: WALIAppCoordinator) {
        participants.removeAll { $0.coordinator == nil }
        participants.append(Participant(coordinator: coordinator))
        recordAgentActivity(if: !coordinator.canQuitWithoutDirectAgent)
        if isQuitting { coordinator.suspendForDirectQuit() }
    }

    func recordAgentActivity(if active: Bool = true) {
        agentWasActive = agentWasActive || active
    }

    func beginQuit() {
        isQuitting = true
        for participant in participants { participant.coordinator?.suspendForDirectQuit() }
    }

    func canQuitWithoutAgent(using lifecycle: AgentLifecycleController) throws -> Bool {
        // A pending native unregister may still change service state. Refuse
        // promptly, without waiting on it or any long-running catalog request.
        guard !lifecycle.isReinstalling,
              !participants.contains(where: { $0.coordinator?.hasPendingDirectServiceOperation == true }) else {
            throw AgentLifecycleError.operationInProgress
        }
        return !agentWasActive && lifecycle.canQuitWithoutAgent
            && participants.allSatisfy { $0.coordinator?.canQuitWithoutDirectAgent ?? true }
    }

    func cancelQuit() {
        isQuitting = false
        for participant in participants { participant.coordinator?.resumeAfterFailedDirectQuit() }
    }
}
#endif
