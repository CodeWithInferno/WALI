/// Logical record schema version with a breaking epoch and additive revision.
public struct RecordSchemaVersion: Codable, Sendable, Hashable {
    /// Initial and currently supported model record schema.
    public static let current = RecordSchemaVersion(uncheckedEpoch: 1, revision: 0)

    /// Positive breaking schema epoch.
    public let epoch: UInt16

    /// Additive revision within the epoch.
    public let revision: UInt16

    /// Creates a logical record schema version.
    public init(epoch: UInt16, revision: UInt16) throws {
        guard epoch > 0 else {
            throw modelViolation(.invalidSchema, field: "recordSchemaVersion")
        }
        self.epoch = epoch
        self.revision = revision
    }

    /// Decodes and validates a schema version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            epoch: container.decode(UInt16.self, forKey: .epoch),
            revision: container.decode(UInt16.self, forKey: .revision)
        )
    }

    package func requireSupported(field: String) throws {
        guard self == .current else {
            throw modelViolation(.unsupportedSchema, field: field)
        }
    }

    private init(uncheckedEpoch: UInt16, revision: UInt16) {
        self.epoch = uncheckedEpoch
        self.revision = revision
    }
}

/// Closed digest algorithm tags supported by model content identities.
public enum DigestAlgorithm: String, Codable, Sendable, Hashable {
    /// SHA-256 represented by 64 lowercase hexadecimal digits.
    case sha256
}

/// Immutable content identity consisting of an algorithm and validated digest.
public struct ContentDigest: Codable, Sendable, Hashable {
    /// Digest algorithm.
    public let algorithm: DigestAlgorithm

    /// Exactly 64 lowercase hexadecimal digits for SHA-256.
    public let value: String

    /// Creates and validates a content digest.
    public init(algorithm: DigestAlgorithm, value: String) throws {
        guard algorithm == .sha256,
              value.utf8.count == 64,
              value.utf8.allSatisfy(isLowercaseHex)
        else {
            throw modelViolation(.invalidDigest, field: "contentDigest")
        }
        self.algorithm = algorithm
        self.value = value
    }

    /// Decodes and validates a content digest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            algorithm: container.decode(DigestAlgorithm.self, forKey: .algorithm),
            value: container.decode(String.self, forKey: .value)
        )
    }
}
