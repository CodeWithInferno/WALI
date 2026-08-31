import Foundation

public enum WireCodecError: Error, Sendable, Equatable {
    case emptyMessage
    case messageTooLarge(actual: Int, maximum: Int)
    case incompatibleProtocol(received: UInt16, supported: UInt16)
    case malformedMessage(String)
}

/// Strict JSON serialization used at the XPC boundary.
public enum WireCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw WireCodecError.malformedMessage(String(describing: error))
        }
        try validateSize(data)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateSize(data)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WireCodecError.malformedMessage(String(describing: error))
        }
    }

    public static func decodeRequest(from data: Data) throws -> AgentRequest {
        let request = try decode(AgentRequest.self, from: data)
        guard request.protocolVersion == WALIProtocol.currentVersion else {
            throw WireCodecError.incompatibleProtocol(
                received: request.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        return request
    }

    public static func decodeResponse(from data: Data) throws -> AgentResponse {
        let response = try decode(AgentResponse.self, from: data)
        guard response.protocolVersion == WALIProtocol.currentVersion else {
            throw WireCodecError.incompatibleProtocol(
                received: response.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        return response
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
