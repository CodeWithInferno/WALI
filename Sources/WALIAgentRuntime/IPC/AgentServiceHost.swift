import Foundation
import Security
import WALIWire

public typealias AgentRequestHandler = @Sendable (AgentRequest) async -> AgentResponse

private final class ReplyBox: @unchecked Sendable {
    let reply: (Data?, NSError?) -> Void

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }
}

final class AgentServiceEndpoint: NSObject, WALIAgentXPCProtocol, @unchecked Sendable {
    private let handler: AgentRequestHandler
    private let afterQuitReply: (@Sendable () async -> Void)?

    init(handler: @escaping AgentRequestHandler, afterQuitReply: (@Sendable () async -> Void)?) {
        self.handler = handler
        self.afterQuitReply = afterQuitReply
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
                guard response.requestID == request.requestID,
                      response.protocolVersion == WALIProtocol.currentVersion else {
                    throw WireCodecError.invalidEnvelope
                }
                replyBox.reply(try WireCodec.encodeResponse(response), nil)
                if case .quit = request.command, case .snapshot = response.result {
                    await afterQuitReply?()
                }
            } catch {
                replyBox.reply(nil, error as NSError)
            }
        }
    }
}

private final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let endpoint: AgentServiceEndpoint
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var stopped = false

    init(endpoint: AgentServiceEndpoint) {
        self.endpoint = endpoint
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard LocalClientValidator.isTrusted(connection) else { return false }
        #if WALI_APP_STORE
        lock.lock()
        guard !stopped, connections.count < 16 else { lock.unlock(); return false }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.remove(connection)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: WALIAppLifecycleXPCProtocol.self)
        #endif
        connection.exportedInterface = NSXPCInterface(with: WALIAgentXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }

    private func remove(_ connection: NSXPCConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in active { connection.invalidate() }
    }

    private func activeConnections() -> [NSXPCConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connections.values)
    }

    #if WALI_APP_STORE
    func notifyForegroundTermination() async throws {
        let active = activeConnections().map(StoreForegroundPeer.init)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for connection in active {
                group.addTask {
                    try await StoreForegroundAcknowledgement.wait { reply in
                        connection.requestTermination(reply: reply)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
    #endif
}

#if WALI_APP_STORE
/// NSXPC supports message submission from arbitrary threads. Keep the accepted
/// connection immutable while a bounded task waits for its callback reply.
private final class StoreForegroundPeer: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }

    func requestTermination(reply: @escaping StoreForegroundAcknowledgement.Reply) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(.failure(error))
        }) as? WALIAppLifecycleXPCProtocol else {
            reply(.failure(AgentFailure(code: .internalFailure, message: "WALI's foreground connection is unavailable.")))
            return
        }
        proxy.agentWillTerminate { reply(.success(())) }
    }
}
#endif

private enum LocalClientValidator {
    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        guard let client = code(for: connection.processIdentifier),
              SecCodeCheckValidity(client, [], nil) == errSecSuccess,
              let clientInfo = signingInfo(for: client),
              let clientIdentifier = clientInfo[kSecCodeInfoIdentifier as String] as? String,
              clientIdentifier == expectedClientIdentifier,
              let ownCode = ownCode(),
              let ownInfo = signingInfo(for: ownCode)
        else {
            return false
        }

        let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let clientTeam = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String
        if isAdHocDebugBuild, ownTeam == nil, clientTeam == nil {
            return true
        }
        guard let ownTeam,
              ownTeam == clientTeam,
              let requirement = peerRequirement(identifier: expectedClientIdentifier, team: ownTeam)
        else {
            return false
        }
        guard SecCodeCheckValidity(client, [], requirement) == errSecSuccess else { return false }
        #if WALI_APP_STORE
        var expression: CFString?
        guard SecRequirementCopyString(requirement, [], &expression) == errSecSuccess,
              let expression else { return false }
        connection.setCodeSigningRequirement(expression as String)
        #endif
        return true
    }

    private static var isAdHocDebugBuild: Bool {
        #if WALI_APP_STORE
        false
        #else
        (Bundle.main.bundleIdentifier ?? "").contains(".debug.")
        #endif
    }

    private static func peerRequirement(identifier: String, team: String) -> SecRequirement? {
        let validIdentifier = identifier.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
        }
        let validTeam = !team.isEmpty && team.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
        guard validIdentifier, validTeam else { return nil }
        let expression = "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            [],
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static var expectedClientIdentifier: String {
        #if WALI_APP_STORE
        let peers = [
            "com.wali.store.development.WALIAgent": "com.wali.store.development.WALI",
            "com.wali.store.WALIAgent": "com.wali.store.WALI",
        ]
        guard let ownIdentifier = Bundle.main.bundleIdentifier,
              let expected = peers[ownIdentifier],
              Bundle.main.object(forInfoDictionaryKey: "WALIExpectedClientBundleIdentifier") as? String == expected else { return "" }
        return expected
        #else
        return DirectAgentIdentity.foregroundIdentifier(for: Bundle.main.bundleIdentifier) ?? ""
        #endif
    }

    private static func code(for processIdentifier: pid_t) -> SecCode? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func ownCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func signingInfo(for code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

/// Owns the launchd-advertised XPC endpoint for the lifetime of the agent.
public final class AgentServiceHost: @unchecked Sendable {
    private let listener: NSXPCListener
    private let delegate: AgentListenerDelegate

    public init(
        serviceName: String = AgentServiceName.current,
        afterQuitReply: (@Sendable () async -> Void)? = nil,
        handler: @escaping AgentRequestHandler
    ) {
        let endpoint = AgentServiceEndpoint(handler: handler, afterQuitReply: afterQuitReply)
        delegate = AgentListenerDelegate(endpoint: endpoint)
        listener = NSXPCListener(machServiceName: serviceName)
        listener.delegate = delegate
    }

    public func start() {
        listener.resume()
    }

    #if WALI_APP_STORE
    public func notifyForegroundTermination() async throws {
        try await delegate.notifyForegroundTermination()
    }
    #endif

    public func stop() {
        #if WALI_APP_STORE
        listener.invalidate()
        delegate.stop()
        #else
        listener.suspend()
        #endif
    }
}

public enum AgentServiceName {
    public static var current: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "WALIControlServiceName") as? String,
           !configured.isEmpty {
            return configured
        }
        #if WALI_APP_STORE
        return ""
        #else
        return "io.github.codewithinferno.wali.WALIAgent.control"
        #endif
    }
}
