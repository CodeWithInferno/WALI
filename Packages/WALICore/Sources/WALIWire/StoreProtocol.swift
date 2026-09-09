import Foundation

/// Store-only lifecycle interface installed on the authenticated agent connection.
/// No request payload, filesystem capability, or arbitrary operation is accepted.
@objc public protocol WALIAppLifecycleXPCProtocol {
    func agentWillTerminate(reply: @escaping () -> Void)
}

public enum StoreLifecycleWire {
    public static let messageVersion: UInt16 = 1
}

/// A foreground transient implicit grant. Never persist this wrapper for recovery.
public struct StoreImportGrant: Codable, Sendable, Hashable {
    public static let maximumBookmarkBytes = 256 * 1_024
    public let messageVersion: UInt16
    public let bookmark: Data

    public init(messageVersion: UInt16 = 1, bookmark: Data) {
        self.messageVersion = messageVersion
        self.bookmark = bookmark
    }
}

public enum StoreImportGrantCodec {
    public static func encode(_ grant: StoreImportGrant) throws -> Data {
        try validate(grant)
        return try WireCodec.encode(grant)
    }

    public static func decode(from data: Data) throws -> StoreImportGrant {
        guard data.count <= 360 * 1_024 else { throw TranscoderWireError.invalidRequest }
        let grant = try WireCodec.decode(StoreImportGrant.self, from: data)
        try validate(grant)
        return grant
    }

    private static func validate(_ grant: StoreImportGrant) throws {
        guard grant.messageVersion == 1, !grant.bookmark.isEmpty,
              grant.bookmark.count <= StoreImportGrant.maximumBookmarkBytes else {
            throw TranscoderWireError.invalidRequest
        }
    }
}

public enum StoreWorkerWire {
    public static let messageVersion: UInt16 = 2
    public static let maximumHandshakeBytes = 4_096
    public static let shutdownTimeoutSeconds: UInt64 = 25
}

/// Echoed only after an authenticated Store worker accepts this exact revision.
public struct StoreWorkerHandshake: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let messageVersion: UInt16
    public let nonce: UUID

    public init(protocolVersion: UInt16 = WALIProtocol.currentVersion,
                messageVersion: UInt16 = StoreWorkerWire.messageVersion,
                nonce: UUID = UUID()) {
        self.protocolVersion = protocolVersion
        self.messageVersion = messageVersion
        self.nonce = nonce
    }
}

/// Store revision two retains the direct request's immutable attempt values.
/// sourceBookmark is a fresh implicit read grant, not the durable agent bookmark.
/// stagingBookmark grants only the already-created UUID/generation directory.
public struct StoreTranscoderRequest: Codable, Sendable, Hashable {
    public let messageVersion: UInt16
    public let request: TranscoderRequest
    public let stagingBookmark: Data

    public init(messageVersion: UInt16 = StoreWorkerWire.messageVersion,
                request: TranscoderRequest, stagingBookmark: Data) {
        self.messageVersion = messageVersion
        self.request = request
        self.stagingBookmark = stagingBookmark
    }
}

public enum StoreTranscoderWireCodec {
    public static func encodeRequest(_ value: StoreTranscoderRequest) throws -> Data {
        try validate(value)
        return try WireCodec.encode(value)
    }

    public static func decodeRequest(from data: Data) throws -> StoreTranscoderRequest {
        let value = try WireCodec.decode(StoreTranscoderRequest.self, from: data)
        try validate(value)
        return value
    }

    public static func encodeHandshake(_ value: StoreWorkerHandshake) throws -> Data {
        try validateHandshake(value)
        let data = try WireCodec.encode(value)
        guard data.count <= StoreWorkerWire.maximumHandshakeBytes else { throw TranscoderWireError.invalidRequest }
        return data
    }

    public static func decodeHandshake(from data: Data) throws -> StoreWorkerHandshake {
        guard data.count <= StoreWorkerWire.maximumHandshakeBytes else { throw TranscoderWireError.invalidRequest }
        let value = try WireCodec.decode(StoreWorkerHandshake.self, from: data)
        try validateHandshake(value)
        return value
    }

    private static func validateHandshake(_ value: StoreWorkerHandshake) throws {
        guard value.protocolVersion == WALIProtocol.currentVersion,
              value.messageVersion == StoreWorkerWire.messageVersion else {
            throw TranscoderWireError.incompatibleProtocol(received: value.messageVersion, supported: StoreWorkerWire.messageVersion)
        }
    }

    private static func validate(_ value: StoreTranscoderRequest) throws {
        guard value.messageVersion == StoreWorkerWire.messageVersion,
              !value.stagingBookmark.isEmpty,
              value.stagingBookmark.count <= StoreImportGrant.maximumBookmarkBytes,
              value.request.sourceBookmark.count <= StoreImportGrant.maximumBookmarkBytes,
              value.request.stagingDirectoryURL.lastPathComponent ==
                "\(value.request.jobID.uuidString.lowercased())-\(value.request.attemptGeneration)" else {
            throw TranscoderWireError.invalidRequest
        }
        _ = try TranscoderWireCodec.encodeRequest(value.request)
    }
}

/// Store alone installs this negotiated interface. An old peer receives only a
/// handshake attempt; the agent sends no job or grants until the echo validates.
@objc public protocol WALIStoreTranscoderXPCProtocol: WALITranscoderXPCProtocol {
    func negotiate(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func shutdown(withReply reply: @escaping (NSError?) -> Void)
}
