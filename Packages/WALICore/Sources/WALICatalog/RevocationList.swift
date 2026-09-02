import Foundation

public enum CatalogRevocationReason: String, Codable, Sendable, Hashable {
    case criticalSecurity = "critical_security"
    case corruptArtifact = "corrupt_artifact"
    case signingCompromise = "signing_compromise"
}

public struct CatalogRevocation: Codable, Sendable, Hashable {
    public let releaseID: String
    public let artifactSHA256: String
    public let reason: CatalogRevocationReason
    public let issuedAt: Date

    enum CodingKeys: String, CodingKey {
        case reason
        case releaseID = "release_id"
        case artifactSHA256 = "artifact_sha256"
        case issuedAt = "issued_at"
    }

    public init(
        releaseID: String,
        artifactSHA256: String,
        reason: CatalogRevocationReason,
        issuedAt: Date
    ) throws {
        guard validateCanonicalUUID(releaseID), validateSHA256(artifactSHA256) else {
            throw CatalogValidationError.invalidManifest
        }
        self.releaseID = releaseID
        self.artifactSHA256 = artifactSHA256
        self.reason = reason
        self.issuedAt = issuedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            releaseID: container.decode(String.self, forKey: .releaseID),
            artifactSHA256: container.decode(String.self, forKey: .artifactSHA256),
            reason: container.decode(CatalogRevocationReason.self, forKey: .reason),
            issuedAt: try parseCatalogTimestamp(container.decode(String.self, forKey: .issuedAt))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(releaseID, forKey: .releaseID)
        try container.encode(artifactSHA256, forKey: .artifactSHA256)
        try container.encode(reason, forKey: .reason)
        try container.encode(formatCatalogTimestamp(issuedAt), forKey: .issuedAt)
    }
}

public struct CatalogRevocationList: Codable, Sendable, Hashable {
    public static let maximumEntryCount = 4_096

    public let schema: CatalogSchemaVersion
    public let keyID: CatalogKeyID
    public let revision: UInt64
    public let issuedAt: Date
    public let revocations: [CatalogRevocation]

    enum CodingKeys: String, CodingKey {
        case schema, revision, revocations
        case keyID = "key_id"
        case issuedAt = "issued_at"
    }

    public init(
        schema: CatalogSchemaVersion,
        keyID: CatalogKeyID,
        revision: UInt64,
        issuedAt: Date,
        revocations: [CatalogRevocation]
    ) throws {
        guard schema == .current else { throw CatalogValidationError.unsupportedSchema }
        guard (1...2_147_483_647).contains(revision),
              revocations.count <= Self.maximumEntryCount,
              Set(revocations.map { "\($0.releaseID):\($0.artifactSHA256)" }).count
                == revocations.count,
              revocations == revocations.sorted(by: Self.entryOrder)
        else {
            throw CatalogValidationError.invalidManifest
        }
        self.schema = schema
        self.keyID = keyID
        self.revision = revision
        self.issuedAt = issuedAt
        self.revocations = revocations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(CatalogSchemaVersion.self, forKey: .schema),
            keyID: container.decode(CatalogKeyID.self, forKey: .keyID),
            revision: container.decode(UInt64.self, forKey: .revision),
            issuedAt: try parseCatalogTimestamp(container.decode(String.self, forKey: .issuedAt)),
            revocations: container.decode([CatalogRevocation].self, forKey: .revocations)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(revision, forKey: .revision)
        try container.encode(formatCatalogTimestamp(issuedAt), forKey: .issuedAt)
        try container.encode(revocations, forKey: .revocations)
    }

    public func revokes(_ manifest: CatalogManifest) -> Bool {
        let artifactDigests = Set(manifest.artifacts.map(\.sha256))
        return revocations.contains {
            $0.releaseID == manifest.releaseID && artifactDigests.contains($0.artifactSHA256)
        }
    }

    private static func entryOrder(_ lhs: CatalogRevocation, _ rhs: CatalogRevocation) -> Bool {
        if lhs.releaseID == rhs.releaseID { return lhs.artifactSHA256 < rhs.artifactSHA256 }
        return lhs.releaseID < rhs.releaseID
    }
}
