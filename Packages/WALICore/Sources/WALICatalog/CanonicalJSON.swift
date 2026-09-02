import Foundation

/// Strict canonical JSON used by signed catalog documents.
public enum CanonicalJSON {
    public struct Limits: Sendable, Hashable {
        public let maximumDocumentBytes: Int
        public let maximumDepth: Int
        public let maximumCollectionCount: Int
        public let maximumStringBytes: Int

        public init(
            maximumDocumentBytes: Int,
            maximumDepth: Int,
            maximumCollectionCount: Int,
            maximumStringBytes: Int = 2_048
        ) {
            self.maximumDocumentBytes = maximumDocumentBytes
            self.maximumDepth = maximumDepth
            self.maximumCollectionCount = maximumCollectionCount
            self.maximumStringBytes = maximumStringBytes
        }

        public static let manifest = Limits(
            maximumDocumentBytes: 65_536,
            maximumDepth: 4,
            maximumCollectionCount: 16
        )

        public static let revocations = Limits(
            maximumDocumentBytes: 1_048_576,
            maximumDepth: 4,
            maximumCollectionCount: 4_096
        )

        public static let installMetadata = Limits(
            maximumDocumentBytes: 16_384,
            maximumDepth: 2,
            maximumCollectionCount: 16
        )

        public static let trustTransition = Limits(
            maximumDocumentBytes: 32_768,
            maximumDepth: 4,
            maximumCollectionCount: 32
        )
    }

    /// Parses canonical JSON and rejects bytes that are not already in their shortest form.
    public static func requireCanonical(
        _ data: Data,
        limits: Limits
    ) throws -> CanonicalJSONDocument {
        guard data.count <= limits.maximumDocumentBytes else {
            throw CatalogValidationError.documentTooLarge
        }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil
        else {
            throw CatalogValidationError.invalidCanonicalJSON
        }

        var parser = Parser(bytes: Array(data), limits: limits)
        let value = try parser.parseDocument()
        var encoded: [UInt8] = []
        value.appendCanonicalBytes(to: &encoded)
        guard Data(encoded) == data else {
            throw CatalogValidationError.invalidCanonicalJSON
        }
        return CanonicalJSONDocument(value: value, data: data)
    }
}

/// A validated canonical document. Its raw value is intentionally not exposed.
public struct CanonicalJSONDocument: Sendable {
    public let data: Data
    fileprivate let value: JSONValue

    fileprivate init(value: JSONValue, data: Data) {
        self.value = value
        self.data = data
    }

    func requireObjectShape(
        keys: [String],
        nestedObjects: [String: [String]] = [:],
        arrayObjectKey: String? = nil,
        arrayObjectKeys: [String] = []
    ) throws {
        guard case let .object(entries) = value,
              entries.map(\.key) == keys
        else {
            throw CatalogValidationError.invalidCanonicalJSON
        }
        for (key, requiredKeys) in nestedObjects {
            guard let nested = entries.first(where: { $0.key == key })?.value,
                  case let .object(nestedEntries) = nested,
                  nestedEntries.map(\.key) == requiredKeys
            else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
        }
        if let arrayObjectKey {
            guard let arrayValue = entries.first(where: { $0.key == arrayObjectKey })?.value,
                  case let .array(elements) = arrayValue
            else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
            for element in elements {
                guard case let .object(elementEntries) = element,
                      elementEntries.map(\.key) == arrayObjectKeys
                else {
                    throw CatalogValidationError.invalidCanonicalJSON
                }
            }
        }
    }
}

private struct JSONObjectEntry: Sendable {
    let key: String
    let value: JSONValue
}

private indirect enum JSONValue: Sendable {
    case object([JSONObjectEntry])
    case array([JSONValue])
    case string(String)
    case integer(String)
    case bool(Bool)

    func appendCanonicalBytes(to output: inout [UInt8]) {
        switch self {
        case let .object(entries):
            output.append(123)
            for (index, entry) in entries.enumerated() {
                if index > 0 { output.append(44) }
                appendJSONString(entry.key, to: &output)
                output.append(58)
                entry.value.appendCanonicalBytes(to: &output)
            }
            output.append(125)
        case let .array(elements):
            output.append(91)
            for (index, element) in elements.enumerated() {
                if index > 0 { output.append(44) }
                element.appendCanonicalBytes(to: &output)
            }
            output.append(93)
        case let .string(value):
            appendJSONString(value, to: &output)
        case let .integer(value):
            output.append(contentsOf: value.utf8)
        case let .bool(value):
            output.append(contentsOf: value ? [116, 114, 117, 101] : [102, 97, 108, 115, 101])
        }
    }
}

private struct Parser {
    let bytes: [UInt8]
    let limits: CanonicalJSON.Limits
    var index = 0

    mutating func parseDocument() throws -> JSONValue {
        guard !bytes.isEmpty else { throw CatalogValidationError.invalidCanonicalJSON }
        let value = try parseValue(depth: 1)
        guard index == bytes.count else { throw CatalogValidationError.invalidCanonicalJSON }
        return value
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= limits.maximumDepth, index < bytes.count else {
            if depth > limits.maximumDepth { throw CatalogValidationError.nestingTooDeep }
            throw CatalogValidationError.invalidCanonicalJSON
        }
        switch bytes[index] {
        case 123: return try parseObject(depth: depth)
        case 91: return try parseArray(depth: depth)
        case 34: return .string(try parseString())
        case 45, 48...57: return .integer(try parseInteger())
        case 116:
            try consumeLiteral([116, 114, 117, 101])
            return .bool(true)
        case 102:
            try consumeLiteral([102, 97, 108, 115, 101])
            return .bool(false)
        default:
            throw CatalogValidationError.invalidCanonicalJSON
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var entries: [JSONObjectEntry] = []
        var keys: Set<String> = []
        if consume(125) { return .object(entries) }
        while true {
            guard index < bytes.count, bytes[index] == 34 else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw CatalogValidationError.duplicateJSONKey
            }
            guard consume(58) else { throw CatalogValidationError.invalidCanonicalJSON }
            let value = try parseValue(depth: depth + 1)
            entries.append(JSONObjectEntry(key: key, value: value))
            guard entries.count <= limits.maximumCollectionCount else {
                throw CatalogValidationError.collectionTooLarge
            }
            if consume(125) { break }
            guard consume(44) else { throw CatalogValidationError.invalidCanonicalJSON }
        }
        return .object(entries)
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var elements: [JSONValue] = []
        if consume(93) { return .array(elements) }
        while true {
            elements.append(try parseValue(depth: depth + 1))
            guard elements.count <= limits.maximumCollectionCount else {
                throw CatalogValidationError.collectionTooLarge
            }
            if consume(93) { break }
            guard consume(44) else { throw CatalogValidationError.invalidCanonicalJSON }
        }
        return .array(elements)
    }

    mutating func parseString() throws -> String {
        guard consume(34) else { throw CatalogValidationError.invalidCanonicalJSON }
        var result = ""
        var segmentStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 || byte == 92 {
                if segmentStart < index {
                    guard let segment = String(
                        data: Data(bytes[segmentStart..<index]),
                        encoding: .utf8
                    ) else {
                        throw CatalogValidationError.invalidCanonicalJSON
                    }
                    result.append(segment)
                }
                if byte == 34 {
                    index += 1
                    guard Array(result.utf8)
                        == Array(result.precomposedStringWithCanonicalMapping.utf8)
                    else {
                        throw CatalogValidationError.invalidCanonicalJSON
                    }
                    guard result.utf8.count <= limits.maximumStringBytes else {
                        throw CatalogValidationError.stringTooLarge
                    }
                    return result
                }
                index += 1
                try appendEscape(to: &result)
                segmentStart = index
            } else {
                guard byte >= 0x20 else { throw CatalogValidationError.invalidCanonicalJSON }
                index += 1
            }
        }
        throw CatalogValidationError.invalidCanonicalJSON
    }

    mutating func appendEscape(to result: inout String) throws {
        guard index < bytes.count else { throw CatalogValidationError.invalidCanonicalJSON }
        switch bytes[index] {
        case 34: result.append("\""); index += 1
        case 92: result.append("\\"); index += 1
        case 98: result.append("\u{0008}"); index += 1
        case 102: result.append("\u{000C}"); index += 1
        case 110: result.append("\n"); index += 1
        case 114: result.append("\r"); index += 1
        case 116: result.append("\t"); index += 1
        case 117:
            index += 1
            let first = try parseHexQuad()
            let scalar: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard consume(92), consume(117) else {
                    throw CatalogValidationError.invalidCanonicalJSON
                }
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw CatalogValidationError.invalidCanonicalJSON
                }
                scalar = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw CatalogValidationError.invalidCanonicalJSON
                }
                scalar = UInt32(first)
            }
            guard let unicode = Unicode.Scalar(scalar) else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
            result.unicodeScalars.append(unicode)
        default:
            throw CatalogValidationError.invalidCanonicalJSON
        }
    }

    mutating func parseHexQuad() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw CatalogValidationError.invalidCanonicalJSON }
        var value: UInt16 = 0
        for byte in bytes[index..<(index + 4)] {
            let nibble: UInt16
            switch byte {
            case 48...57: nibble = UInt16(byte - 48)
            case 97...102: nibble = UInt16(byte - 97 + 10)
            default: throw CatalogValidationError.invalidCanonicalJSON
            }
            value = (value << 4) | nibble
        }
        index += 4
        return value
    }

    mutating func parseInteger() throws -> String {
        let start = index
        guard !consume(45) else {
            throw CatalogValidationError.invalidCanonicalJSON
        }
        guard index < bytes.count else { throw CatalogValidationError.invalidCanonicalJSON }
        if consume(48) {
            guard index == bytes.count || !(48...57).contains(bytes[index]) else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
        } else {
            guard (49...57).contains(bytes[index]) else {
                throw CatalogValidationError.invalidCanonicalJSON
            }
            index += 1
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 46 || bytes[index] == 69 || bytes[index] == 101 {
            throw CatalogValidationError.floatingPointNumber
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard token != "-0", Int64(token) != nil else {
            throw CatalogValidationError.invalidCanonicalJSON
        }
        return token
    }

    mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal
        else {
            throw CatalogValidationError.invalidCanonicalJSON
        }
        index += literal.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

private func appendJSONString(_ value: String, to output: inout [UInt8]) {
    output.append(34)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x08: output.append(contentsOf: [92, 98])
        case 0x09: output.append(contentsOf: [92, 116])
        case 0x0A: output.append(contentsOf: [92, 110])
        case 0x0C: output.append(contentsOf: [92, 102])
        case 0x0D: output.append(contentsOf: [92, 114])
        case 0x22: output.append(contentsOf: [92, 34])
        case 0x5C: output.append(contentsOf: [92, 92])
        case 0x00...0x1F:
            let digits = Array("0123456789abcdef".utf8)
            output.append(contentsOf: [92, 117, 48, 48])
            output.append(digits[Int((scalar.value >> 4) & 0xF)])
            output.append(digits[Int(scalar.value & 0xF)])
        default:
            output.append(contentsOf: String(scalar).utf8)
        }
    }
    output.append(34)
}
