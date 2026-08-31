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

/// Reconnecting foreground transport for the local agent's single XPC method.
@MainActor
public final class AgentConnection {
    private let serviceName: String
    private var connection: NSXPCConnection?

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
        let requestData = try WireCodec.encode(request)

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
    }

    private func perform(_ request: Data) async throws -> Data {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let finish: (Result<Data, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(error))
            }) as? WALIAgentXPCProtocol else {
                finish(.failure(AgentConnectionError.invalidProxy))
                return
            }
            proxy.perform(request) { data, error in
                if let error {
                    finish(.failure(error))
                } else if let data {
                    finish(.success(data))
                } else {
                    finish(.failure(AgentConnectionError.emptyResponse))
                }
            }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(machServiceName: serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: WALIAgentXPCProtocol.self)
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
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
