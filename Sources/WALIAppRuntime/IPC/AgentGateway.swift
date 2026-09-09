import Foundation
import WALIModel
import WALIWire

/// Foreground transport seam shared by authenticated XPC and deterministic
/// lifecycle tests. It carries only the existing bounded wire commands.
@MainActor
public protocol AgentGateway: AnyObject, Sendable {
    var isConnected: Bool { get }
    func send(_ command: AgentCommand, expectedRevision: EngineRevision?, idempotencyKey: UUID) async throws -> AgentSnapshot
    func invalidate()
    #if WALI_APP_STORE
    var onAgentWillTerminate: (@MainActor @Sendable () -> Void)? { get set }
    var onConnectionEnded: (@MainActor @Sendable () -> Void)? { get set }
    #endif
}

public extension AgentGateway {
    func send(_ command: AgentCommand, expectedRevision: EngineRevision? = nil) async throws -> AgentSnapshot {
        try await send(command, expectedRevision: expectedRevision, idempotencyKey: UUID())
    }
}
