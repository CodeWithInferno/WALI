import Foundation
import WALIModel
import WALIWire

public enum AgentConnectionError: LocalizedError {
    case unavailable
    case invalidProxy
    case emptyResponse
    case requestMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The WALI background agent is unavailable."
        case .invalidProxy: "WALI could not create a secure connection to its agent."
        case .emptyResponse: "The WALI agent returned an empty response."
        case .requestMismatch: "The WALI agent returned a response for another request."
        }
    }
}

private final class AgentOneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    nonisolated func resume(with result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Builds Objective-C callbacks outside ``AgentConnection``'s main-actor
/// isolation. NSXPC invokes these blocks on private queues, so they may only
/// resolve the thread-safe continuation and must never touch app state.
private enum AgentCallbackFactory {
    nonisolated static func errorHandler(
        _ oneShot: AgentOneShotContinuation<Data>
    ) -> @Sendable (any Error) -> Void {
        { error in
            oneShot.resume(with: .failure(error))
        }
    }

    nonisolated static func replyHandler(
        _ oneShot: AgentOneShotContinuation<Data>
    ) -> @Sendable (Data?, (any Error)?) -> Void {
        { data, error in
            if let error {
                oneShot.resume(with: .failure(error))
            } else if let data {
                oneShot.resume(with: .success(data))
            } else {
                oneShot.resume(with: .failure(AgentConnectionError.emptyResponse))
            }
        }
    }
}

private final class AgentConnectionEndHandler: @unchecked Sendable {
    private weak var owner: AgentConnection?
    private let identifier: UUID

    init(owner: AgentConnection, identifier: UUID) {
        self.owner = owner
        self.identifier = identifier
    }

    func notify() {
        Task { @MainActor [weak owner] in
            owner?.connectionEnded(identifier)
        }
    }
}

/// Reconnecting foreground transport for the local agent's single XPC method.
@MainActor
public final class AgentConnection {
    private let serviceName: String
    private var connection: NSXPCConnection?
    private var connectionID: UUID?

    public init(serviceName: String = AgentServiceName.current) {
        self.serviceName = serviceName
    }

    public func send(
        _ command: AgentCommand,
        expectedRevision: EngineRevision? = nil,
        idempotencyKey: UUID = UUID()
    ) async throws -> AgentSnapshot {
        let request = AgentRequest(
            idempotencyKey: idempotencyKey,
            expectedRevision: expectedRevision,
            command: command
        )
        let requestData = try WireCodec.encodeRequest(request)

        let responseData = try await perform(requestData)
        let response = try WireCodec.decodeResponse(from: responseData)
        guard response.requestID == request.requestID else {
            throw AgentConnectionError.requestMismatch
        }
        switch response.result {
        case let .snapshot(snapshot):
            return snapshot
        case let .failure(failure):
            throw failure
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
        connectionID = nil
    }

    private func perform(_ request: Data) async throws -> Data {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let oneShot = AgentOneShotContinuation<Data>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(
                AgentCallbackFactory.errorHandler(oneShot)
            ) as? WALIAgentXPCProtocol else {
                oneShot.resume(with: .failure(AgentConnectionError.invalidProxy))
                return
            }
            proxy.perform(request, withReply: AgentCallbackFactory.replyHandler(oneShot))
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let identifier = UUID()
        let newConnection = NSXPCConnection(machServiceName: serviceName)
        let endHandler = AgentConnectionEndHandler(owner: self, identifier: identifier)
        newConnection.remoteObjectInterface = NSXPCInterface(with: WALIAgentXPCProtocol.self)
        newConnection.interruptionHandler = { endHandler.notify() }
        newConnection.invalidationHandler = { endHandler.notify() }
        newConnection.resume()
        connection = newConnection
        connectionID = identifier
        return newConnection
    }

    fileprivate func connectionEnded(_ identifier: UUID) {
        guard connectionID == identifier else { return }
        connection = nil
        connectionID = nil
    }
}

public enum AgentServiceName {
    public static var current: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "WALIControlServiceName") as? String,
           !configured.isEmpty {
            return configured
        }
        return "com.wali.WALIAgent.control"
    }
}
