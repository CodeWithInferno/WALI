import Foundation
import Security
import WALILockScreenWire

public enum LockScreenOperation: String, CaseIterable, Sendable {
    case status
    case activateVerifiedRelease
    case deactivate
    case restore
}

public enum LockScreenHelperError: LocalizedError, Equatable, Sendable {
    case malformedEnvelope
    case protocolMismatch
    case messageVersionMismatch
    case requestTooLarge
    case invalidPayload
    case staleRevision
    case replayConflict
    case peerRejected
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .malformedEnvelope: "The Lock Screen helper request is malformed."
        case .protocolMismatch: "The Lock Screen helper protocol version is incompatible."
        case .messageVersionMismatch: "The Lock Screen helper message version is incompatible."
        case .requestTooLarge: "The Lock Screen helper request exceeds its fixed size limit."
        case .invalidPayload: "The Lock Screen helper rejected an unbounded or unknown field."
        case .staleRevision: "The Lock Screen helper state changed; refresh and try again."
        case .replayConflict: "The Lock Screen helper rejected a conflicting replay."
        case .peerRejected: "The Lock Screen helper rejected the caller identity."
        case .unavailable: "The Lock Screen helper is unavailable."
        }
    }
}

public enum AuthenticatedPeer {
    public static func isTrusted(_ connection: NSXPCConnection, expectedIdentifier: String) -> Bool {
        guard let client = code(for: connection.processIdentifier), SecCodeCheckValidity(client, [], nil) == errSecSuccess,
              let clientInfo = signingInfo(for: client), clientInfo[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier,
              let own = ownCode(), let ownInfo = signingInfo(for: own),
              matchesDesignatedIdentity(clientIdentifier: clientInfo[kSecCodeInfoIdentifier as String] as? String,
                                        expectedIdentifier: expectedIdentifier,
                                        clientTeam: clientInfo[kSecCodeInfoTeamIdentifier as String] as? String,
                                        ownTeam: ownInfo[kSecCodeInfoTeamIdentifier as String] as? String),
              let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              let expression = try? requirementExpression(identifier: expectedIdentifier, team: ownTeam) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(client, [], requirement) == errSecSuccess
    }
    static func matchesDesignatedIdentity(clientIdentifier: String?, expectedIdentifier: String, clientTeam: String?, ownTeam: String?) -> Bool {
        guard clientIdentifier == expectedIdentifier, let clientTeam, let ownTeam, !clientTeam.isEmpty, clientTeam == ownTeam else { return false }
        return true
    }
    public static func requirementExpression(identifier: String, team: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy(allowed.contains), !team.isEmpty,
              team.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { throw LockScreenHelperError.peerRejected }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
    private static func code(for pid: pid_t) -> SecCode? { var value: SecCode?; let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary; guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &value) == errSecSuccess else { return nil }; return value }
    private static func ownCode() -> SecCode? { var value: SecCode?; guard SecCodeCopySelf([], &value) == errSecSuccess else { return nil }; return value }
    private static func signingInfo(for code: SecCode) -> [String: Any]? { var staticCode: SecStaticCode?; guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }; var information: CFDictionary?; guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }; return information as? [String: Any] }
}

enum StrictLockScreenCodec {
    private static let headerKeys: Set<String> = [
        "protocolVersion", "messageVersion", "requestID", "idempotencyKey",
        "expectedRevision", "payloadLength",
    ]
    private static let releaseKeys: Set<String> = [
        "releaseID", "assetID", "title", "masterSHA256", "thumbnailSHA256",
        "compatibilityRevision",
    ]

    static func decodeStatus(_ data: Data) throws -> LockScreenHelperStatusRequest {
        let object = try preflight(data)
        try requireKeys(object, exactly: ["header"])
        let value = try decode(LockScreenHelperStatusRequest.self, from: data)
        try validate(value.header, payloadRequired: false)
        return value
    }

    static func decodeActivation(_ data: Data) throws -> LockScreenHelperActivationRequest {
        let object = try preflight(data)
        try requireKeys(object, exactly: ["header", "release", "restartPlayback"])
        guard let release = object["release"] as? [String: Any] else {
            throw LockScreenHelperError.invalidPayload
        }
        try requireKeys(release, exactly: releaseKeys)
        let value = try decode(LockScreenHelperActivationRequest.self, from: data)
        try validate(value.header, payloadRequired: true)
        try validate(value.release)
        let canonicalPayloadLength = try LockScreenHelperWire.canonicalPayloadLength(value.release)
        guard value.header.payloadLength == canonicalPayloadLength else {
            throw LockScreenHelperError.invalidPayload
        }
        return value
    }

    static func decodeMutation(_ data: Data) throws -> LockScreenHelperMutationRequest {
        let object = try preflight(data)
        try requireKeys(object, exactly: ["header"])
        let value = try decode(LockScreenHelperMutationRequest.self, from: data)
        try validate(value.header, payloadRequired: false)
        return value
    }

    static func encode(_ response: LockScreenHelperResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        guard data.count <= LockScreenHelperWire.maximumResponseBytes else {
            throw LockScreenHelperError.invalidPayload
        }
        return data
    }

    private static func preflight(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= LockScreenHelperWire.maximumRequestBytes else {
            throw LockScreenHelperError.requestTooLarge
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw LockScreenHelperError.malformedEnvelope
        }
        guard let object = raw as? [String: Any],
              let header = object["header"] as? [String: Any],
              let protocolNumber = header["protocolVersion"] as? NSNumber,
              protocolNumber.uint16Value == LockScreenHelperWire.protocolVersion else {
            throw LockScreenHelperError.protocolMismatch
        }
        guard let messageNumber = header["messageVersion"] as? NSNumber,
              messageNumber.uint16Value == LockScreenHelperWire.messageVersion else {
            throw LockScreenHelperError.messageVersionMismatch
        }
        try requireKeys(header, exactly: headerKeys)
        return object
    }

    private static func validate(
        _ header: LockScreenHelperRequestHeader,
        payloadRequired: Bool
    ) throws {
        guard header.protocolVersion == LockScreenHelperWire.protocolVersion else {
            throw LockScreenHelperError.protocolMismatch
        }
        guard header.messageVersion == LockScreenHelperWire.messageVersion else {
            throw LockScreenHelperError.messageVersionMismatch
        }
        if payloadRequired {
            guard header.payloadLength > 0,
                  Int(header.payloadLength) <= LockScreenHelperWire.maximumRequestBytes else {
                throw LockScreenHelperError.invalidPayload
            }
        } else if header.payloadLength != 0 {
            throw LockScreenHelperError.invalidPayload
        }
    }

    private static func validate(_ release: LockScreenVerifiedRelease) throws {
        guard !release.title.isEmpty,
              release.title.utf8.count <= 160,
              !release.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              isDigest(release.masterSHA256),
              isDigest(release.thumbnailSHA256),
              release.compatibilityRevision == 1 else {
            throw LockScreenHelperError.invalidPayload
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func requireKeys(
        _ object: [String: Any],
        exactly expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else { throw LockScreenHelperError.invalidPayload }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as LockScreenHelperError {
            throw error
        } catch {
            throw LockScreenHelperError.malformedEnvelope
        }
    }
}

protocol LockScreenStoreOperating: Sendable {
    func status() throws -> LockScreenHelperStatus
    func activate(
        _ release: LockScreenVerifiedRelease,
        expectedRevision: UInt64
    ) throws -> (changed: Bool, status: LockScreenHelperStatus)
    func deactivate(expectedRevision: UInt64) throws -> (changed: Bool, status: LockScreenHelperStatus)
    func restore(expectedRevision: UInt64) throws -> (changed: Bool, status: LockScreenHelperStatus)
}

private final class HelperReply: @unchecked Sendable { let closure: (Data?, NSError?) -> Void; init(_ closure: @escaping (Data?, NSError?) -> Void) { self.closure = closure } }
private final class LockScreenHelperEndpoint: NSObject, WALILockScreenHelperXPCProtocol, @unchecked Sendable {
    private let router: LockScreenOperationRouter
    init(router: LockScreenOperationRouter) { self.router = router }
    func status(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { perform(reply) { try await self.router.status(request) } }
    func activateVerifiedRelease(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { perform(reply) { try await self.router.activateVerifiedRelease(request) } }
    func deactivate(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { perform(reply) { try await self.router.deactivate(request) } }
    func restore(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { perform(reply) { try await self.router.restore(request) } }
    private func perform(_ reply: @escaping (Data?, NSError?) -> Void, operation: @escaping @Sendable () async throws -> Data) { let box = HelperReply(reply); Task { do { box.closure(try await operation(), nil) } catch { box.closure(nil, error as NSError) } } }
}
private final class LockScreenHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let endpoint: LockScreenHelperEndpoint; private let expectedAgentIdentifier: String
    init(endpoint: LockScreenHelperEndpoint, expectedAgentIdentifier: String) { self.endpoint = endpoint; self.expectedAgentIdentifier = expectedAgentIdentifier }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool { guard AuthenticatedPeer.isTrusted(connection, expectedIdentifier: expectedAgentIdentifier) else { return false }; connection.exportedInterface = NSXPCInterface(with: WALILockScreenHelperXPCProtocol.self); connection.exportedObject = endpoint; connection.resume(); return true }
}
public final class LockScreenHelperService: @unchecked Sendable {
    private let listener: NSXPCListener; private let delegate: LockScreenHelperListenerDelegate
    public init(serviceName: String, expectedAgentIdentifier: String, router: LockScreenOperationRouter) { let endpoint = LockScreenHelperEndpoint(router: router); delegate = LockScreenHelperListenerDelegate(endpoint: endpoint, expectedAgentIdentifier: expectedAgentIdentifier); listener = NSXPCListener(machServiceName: serviceName); listener.delegate = delegate }
    public convenience init() throws { guard let serviceName = Bundle.main.object(forInfoDictionaryKey: "WALILockScreenHelperServiceName") as? String, !serviceName.isEmpty, let expected = Bundle.main.object(forInfoDictionaryKey: "WALIExpectedAgentBundleIdentifier") as? String, !expected.isEmpty else { throw LockScreenHelperError.unavailable }; try self.init(serviceName: serviceName, expectedAgentIdentifier: expected, router: LockScreenOperationRouter()) }
    public func run() -> Never { listener.resume(); dispatchMain() }
}

public actor LockScreenOperationRouter {
    private let store: any LockScreenStoreOperating
    private var replayCache: [UUID: (digest: Data, response: Data)] = [:]
    private var replayOrder: [UUID] = []

    init(store: any LockScreenStoreOperating) {
        self.store = store
    }

    public init() throws {
        store = try FixedWallpaperStore.live()
    }

    public func status(_ data: Data) throws -> Data {
        let request = try StrictLockScreenCodec.decodeStatus(data)
        return try cached(header: request.header, requestData: data) {
            let status = try store.status()
            return .init(
                requestID: request.header.requestID,
                revision: status.revision,
                changed: false,
                status: status
            )
        }
    }

    public func activateVerifiedRelease(_ data: Data) throws -> Data {
        let request = try StrictLockScreenCodec.decodeActivation(data)
        return try cached(header: request.header, requestData: data) {
            let result = try store.activate(
                request.release,
                expectedRevision: request.header.expectedRevision
            )
            return .init(
                requestID: request.header.requestID,
                revision: result.status.revision,
                changed: result.changed,
                status: result.status
            )
        }
    }

    public func deactivate(_ data: Data) throws -> Data {
        let request = try StrictLockScreenCodec.decodeMutation(data)
        return try cached(header: request.header, requestData: data) {
            let result = try store.deactivate(expectedRevision: request.header.expectedRevision)
            return .init(
                requestID: request.header.requestID,
                revision: result.status.revision,
                changed: result.changed,
                status: result.status
            )
        }
    }

    public func restore(_ data: Data) throws -> Data {
        let request = try StrictLockScreenCodec.decodeMutation(data)
        return try cached(header: request.header, requestData: data) {
            let result = try store.restore(expectedRevision: request.header.expectedRevision)
            return .init(
                requestID: request.header.requestID,
                revision: result.status.revision,
                changed: result.changed,
                status: result.status
            )
        }
    }

    private func cached(
        header: LockScreenHelperRequestHeader,
        requestData: Data,
        operation: () throws -> LockScreenHelperResponse
    ) throws -> Data {
        let digest = LockScreenFileIO.sha256(of: requestData)
        if let cached = replayCache[header.idempotencyKey] {
            guard cached.digest == digest else { throw LockScreenHelperError.replayConflict }
            return cached.response
        }
        let response = try StrictLockScreenCodec.encode(operation())
        replayCache[header.idempotencyKey] = (digest, response)
        replayOrder.append(header.idempotencyKey)
        if replayOrder.count > 256 {
            replayCache.removeValue(forKey: replayOrder.removeFirst())
        }
        return response
    }
}
