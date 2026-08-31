import Foundation

public enum WireCodecError: Error, Sendable, Equatable {
    case emptyMessage
    case messageTooLarge(actual: Int, maximum: Int)
    case incompatibleProtocol(received: UInt16, supported: UInt16)
    case malformedMessage(String)
    case invalidEnvelope
    case collectionTooLarge
}

public enum WireMessageType: String, Codable, Sendable, Hashable {
    case agentRequest = "agent_request"
    case agentResponse = "agent_response"
    case transcoderRequest = "transcoder_request"
    case transcoderResponse = "transcoder_response"
}

public struct WireEnvelope: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let messageType: WireMessageType
    public let messageVersion: UInt16
    public let requestID: UUID
    public let idempotencyKey: UUID
    public let expectedRevision: UInt64?
    public let payloadLength: Int
    public let payload: Data

    public init(
        messageType: WireMessageType,
        requestID: UUID,
        idempotencyKey: UUID,
        expectedRevision: UInt64?,
        payload: Data
    ) {
        protocolVersion = WALIProtocol.currentVersion
        self.messageType = messageType
        messageVersion = 1
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        payloadLength = payload.count
        self.payload = payload
    }
}

/// Strict JSON serialization used at the XPC boundary.
public enum WireCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data: Data
        do {
            data = try makeEncoder().encode(value)
        } catch {
            throw WireCodecError.malformedMessage(String(describing: error))
        }
        try validateSize(data)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateSize(data)
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw WireCodecError.malformedMessage(String(describing: error))
        }
    }

    public static func decodeRequest(from data: Data) throws -> AgentRequest {
        let envelope = try decode(WireEnvelope.self, from: data)
        try validate(envelope, type: .agentRequest)
        let request = try decode(AgentRequest.self, from: envelope.payload)
        guard request.protocolVersion == WALIProtocol.currentVersion,
              request.requestID == envelope.requestID,
              request.idempotencyKey == envelope.idempotencyKey,
              request.expectedRevision?.rawValue == envelope.expectedRevision else {
            throw WireCodecError.invalidEnvelope
        }
        try validate(request.command)
        return request
    }

    public static func encodeRequest(_ request: AgentRequest) throws -> Data {
        try validate(request.command)
        let payload = try encode(request)
        return try encode(WireEnvelope(
            messageType: .agentRequest,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            expectedRevision: request.expectedRevision?.rawValue,
            payload: payload
        ))
    }

    public static func decodeResponse(from data: Data) throws -> AgentResponse {
        let envelope = try decode(WireEnvelope.self, from: data)
        try validate(envelope, type: .agentResponse)
        let response = try decode(AgentResponse.self, from: envelope.payload)
        guard response.protocolVersion == WALIProtocol.currentVersion,
              response.requestID == envelope.requestID else {
            throw WireCodecError.invalidEnvelope
        }
        return response
    }

    public static func encodeResponse(_ response: AgentResponse) throws -> Data {
        let payload = try encode(response)
        return try encode(WireEnvelope(
            messageType: .agentResponse,
            requestID: response.requestID,
            idempotencyKey: response.requestID,
            expectedRevision: nil,
            payload: payload
        ))
    }

    private static func validate(_ envelope: WireEnvelope, type: WireMessageType) throws {
        guard envelope.protocolVersion == WALIProtocol.currentVersion else {
            throw WireCodecError.incompatibleProtocol(
                received: envelope.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        guard envelope.messageType == type,
              envelope.messageVersion == 1,
              envelope.payloadLength == envelope.payload.count else {
            throw WireCodecError.invalidEnvelope
        }
        try validateSize(envelope.payload)
    }

    private static func validate(_ command: AgentCommand) throws {
        switch command {
        case let .importFiles(bookmarks):
            guard bookmarks.count <= 32,
                  bookmarks.allSatisfy({ $0.count <= 1_024 * 1_024 }) else {
                throw WireCodecError.collectionTooLarge
            }
        case let .apply(_, displayIDs, _):
            guard displayIDs.count <= 16,
                  displayIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw WireCodecError.collectionTooLarge
            }
        case let .renameItem(_, name):
            guard !name.isEmpty, name.utf8.count <= 480 else {
                throw WireCodecError.collectionTooLarge
            }
        default:
            break
        }
    }

    private static func validateSize(_ data: Data) throws {
        guard !data.isEmpty else { throw WireCodecError.emptyMessage }
        guard data.count <= WALIProtocol.maximumMessageBytes else {
            throw WireCodecError.messageTooLarge(
                actual: data.count,
                maximum: WALIProtocol.maximumMessageBytes
            )
        }
    }
}
