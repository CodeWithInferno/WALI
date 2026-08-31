import Foundation
import WALIWire

public typealias AgentRequestHandler = @Sendable (AgentRequest) async -> AgentResponse

private final class ReplyBox: @unchecked Sendable {
    let reply: (Data?, NSError?) -> Void

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }
}

private final class AgentServiceEndpoint: NSObject, WALIAgentXPCProtocol, @unchecked Sendable {
    private let handler: AgentRequestHandler

    init(handler: @escaping AgentRequestHandler) {
        self.handler = handler
    }

    func perform(_ requestData: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let request: AgentRequest
        do {
            request = try WireCodec.decodeRequest(from: requestData)
        } catch {
            reply(nil, error as NSError)
            return
        }

        let replyBox = ReplyBox(reply)
        Task {
            let response = await handler(request)
            do {
                replyBox.reply(try WireCodec.encode(response), nil)
            } catch {
                replyBox.reply(nil, error as NSError)
            }
        }
    }
}

private final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let endpoint: AgentServiceEndpoint

    init(endpoint: AgentServiceEndpoint) {
        self.endpoint = endpoint
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WALIAgentXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

/// Owns the launchd-advertised XPC endpoint for the lifetime of the agent.
public final class AgentServiceHost: @unchecked Sendable {
    private let listener: NSXPCListener
    private let delegate: AgentListenerDelegate

    public init(serviceName: String = AgentServiceName.current, handler: @escaping AgentRequestHandler) {
        let endpoint = AgentServiceEndpoint(handler: handler)
        delegate = AgentListenerDelegate(endpoint: endpoint)
        listener = NSXPCListener(machServiceName: serviceName)
        listener.delegate = delegate
    }

    public func start() {
        listener.resume()
    }

    public func stop() {
        listener.suspend()
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
