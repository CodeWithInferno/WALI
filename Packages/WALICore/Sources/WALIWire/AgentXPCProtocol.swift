import Foundation

/// The single, bounded Objective-C surface exported by the local agent.
@objc public protocol WALIAgentXPCProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

/// The helper deliberately exports four selectors instead of one generic
/// command decoder. A caller cannot smuggle a fifth operation into the wire
/// payload because it has no Objective-C selector to invoke.
@objc public protocol WALILockScreenHelperXPCProtocol {
    func status(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func activateVerifiedRelease(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func deactivate(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func restore(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

public enum LockScreenHelperWire {
    public static let protocolVersion: UInt16 = 1
    public static let messageVersion: UInt16 = 1
    public static let maximumRequestBytes = 4_096
    public static let maximumResponseBytes = 4_096

    public static func canonicalPayloadLength(
        _ release: LockScreenVerifiedRelease
    ) throws -> UInt16 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let count = try encoder.encode(release).count
        guard count <= UInt16.max else { throw EncodingError.invalidValue(
            release,
            .init(codingPath: [], debugDescription: "Lock Screen release payload is too large")
        ) }
        return UInt16(count)
    }
}

public struct LockScreenHelperRequestHeader: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let messageVersion: UInt16
    public let requestID: UUID
    public let idempotencyKey: UUID
    public let expectedRevision: UInt64
    public let payloadLength: UInt16

    public init(
        protocolVersion: UInt16 = LockScreenHelperWire.protocolVersion,
        messageVersion: UInt16 = LockScreenHelperWire.messageVersion,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        expectedRevision: UInt64,
        payloadLength: UInt16
    ) {
        self.protocolVersion = protocolVersion
        self.messageVersion = messageVersion
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.payloadLength = payloadLength
    }
}

public struct LockScreenHelperStatusRequest: Codable, Sendable, Hashable {
    public let header: LockScreenHelperRequestHeader

    public init(header: LockScreenHelperRequestHeader) {
        self.header = header
    }
}

public struct LockScreenVerifiedRelease: Codable, Sendable, Hashable {
    public let releaseID: UUID
    public let assetID: UUID
    public let title: String
    public let masterSHA256: String
    public let thumbnailSHA256: String
    public let compatibilityRevision: UInt16

    public init(
        releaseID: UUID,
        assetID: UUID,
        title: String,
        masterSHA256: String,
        thumbnailSHA256: String,
        compatibilityRevision: UInt16
    ) {
        self.releaseID = releaseID
        self.assetID = assetID
        self.title = title
        self.masterSHA256 = masterSHA256
        self.thumbnailSHA256 = thumbnailSHA256
        self.compatibilityRevision = compatibilityRevision
    }
}

public struct LockScreenHelperActivationRequest: Codable, Sendable, Hashable {
    public let header: LockScreenHelperRequestHeader
    public let release: LockScreenVerifiedRelease
    public let restartPlayback: Bool

    public init(
        header: LockScreenHelperRequestHeader,
        release: LockScreenVerifiedRelease,
        restartPlayback: Bool
    ) {
        self.header = header
        self.release = release
        self.restartPlayback = restartPlayback
    }
}

public struct LockScreenHelperMutationRequest: Codable, Sendable, Hashable {
    public let header: LockScreenHelperRequestHeader

    public init(header: LockScreenHelperRequestHeader) {
        self.header = header
    }
}

public enum LockScreenHelperPermission: String, Codable, Sendable, Hashable {
    case available
    case permissionRequired = "permission_required"
    case unsupportedBuild = "unsupported_build"
    case unavailable
}

public struct LockScreenHelperStatus: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let messageVersion: UInt16
    public let revision: UInt64
    public let permission: LockScreenHelperPermission
    public let activeReleaseID: UUID?
    public let currentUserSessionOnly: Bool
    public let fileVaultPrebootSupported: Bool

    public init(
        protocolVersion: UInt16 = LockScreenHelperWire.protocolVersion,
        messageVersion: UInt16 = LockScreenHelperWire.messageVersion,
        revision: UInt64,
        permission: LockScreenHelperPermission,
        activeReleaseID: UUID?,
        currentUserSessionOnly: Bool = true,
        fileVaultPrebootSupported: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.messageVersion = messageVersion
        self.revision = revision
        self.permission = permission
        self.activeReleaseID = activeReleaseID
        self.currentUserSessionOnly = currentUserSessionOnly
        self.fileVaultPrebootSupported = fileVaultPrebootSupported
    }
}

public struct LockScreenHelperResponse: Codable, Sendable, Hashable {
    public let requestID: UUID
    public let revision: UInt64
    public let changed: Bool
    public let status: LockScreenHelperStatus

    public init(
        requestID: UUID,
        revision: UInt64,
        changed: Bool,
        status: LockScreenHelperStatus
    ) {
        self.requestID = requestID
        self.revision = revision
        self.changed = changed
        self.status = status
    }
}
