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
                replyBox.reply(try WireCodec.encodeResponse(response), nil)
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
        guard LocalClientValidator.isTrusted(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: WALIAgentXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

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
        return SecCodeCheckValidity(client, [], requirement) == errSecSuccess
    }

    private static var isAdHocDebugBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").contains(".debug.")
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
        let identifier = Bundle.main.bundleIdentifier ?? "com.wali.WALIAgent"
        return identifier.replacingOccurrences(of: "WALIAgent", with: "WALI")
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
