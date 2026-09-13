import CryptoKit
import Foundation

public enum CatalogSigningKeyStatus: String, Codable, Sendable, Hashable {
    case active
    case retired
    case compromised
}

/// A public catalog key whose anchor or rotation chain was accepted by WALI.
public struct TrustedCatalogSigningKey: Sendable, Hashable {
    public let id: CatalogKeyID
    public let publicKey: Data
    public let validFrom: Date
    public let validUntil: Date
    public let status: CatalogSigningKeyStatus

    public init(
        id: CatalogKeyID,
        publicKey: Data,
        validFrom: Date,
        validUntil: Date,
        status: CatalogSigningKeyStatus
    ) throws {
        guard publicKey.count == 32, validFrom < validUntil else {
            throw CatalogValidationError.inactiveSigningKey
        }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        self.id = id
        self.publicKey = publicKey
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.status = status
    }

    func isUsable(for issuedAt: Date) -> Bool {
        status != .compromised && validFrom <= issuedAt && issuedAt <= validUntil
    }
}

public struct CatalogVerificationContext: Sendable, Hashable {
    public let wallpaperID: String
    public let releaseID: String
    public let metadataDigest: String

    public init(wallpaperID: String, releaseID: String, metadataDigest: String) throws {
        guard validateCanonicalUUID(wallpaperID),
              validateCanonicalUUID(releaseID),
              validateSHA256(metadataDigest)
        else {
            throw CatalogValidationError.invalidManifest
        }
        self.wallpaperID = wallpaperID
        self.releaseID = releaseID
        self.metadataDigest = metadataDigest
    }
}

public struct VerifiedCatalogManifest: Sendable, Hashable {
    public let manifest: CatalogManifest
    public let signedBytes: Data
}

public struct ManifestVerifier: Sendable {
    private let trustedKeys: [CatalogKeyID: TrustedCatalogSigningKey]
    private let approvedCDNHosts: Set<String>

    public init(
        trustedKeys: [TrustedCatalogSigningKey],
        approvedCDNHosts: Set<String>
    ) throws {
        guard !trustedKeys.isEmpty,
              Set(trustedKeys.map(\.id)).count == trustedKeys.count,
              !approvedCDNHosts.isEmpty,
              approvedCDNHosts.allSatisfy(validateCatalogPublicHostname)
        else {
            throw CatalogValidationError.invalidManifest
        }
        self.trustedKeys = Dictionary(uniqueKeysWithValues: trustedKeys.map { ($0.id, $0) })
        self.approvedCDNHosts = approvedCDNHosts
    }

    public func verify(
        manifestData: Data,
        signatureBase64URL: String,
        context: CatalogVerificationContext,
        revocations: CatalogRevocationList? = nil
    ) throws -> VerifiedCatalogManifest {
        let document = try CanonicalJSON.requireCanonical(manifestData, limits: .manifest)
        let manifest: CatalogManifest
        do {
            manifest = try JSONDecoder().decode(CatalogManifest.self, from: manifestData)
        } catch let error as CatalogValidationError {
            throw error
        } catch {
            throw CatalogValidationError.invalidManifest
        }
        try document.requireObjectShape(
            keys: ["schema"] + (manifest.schema == CatalogManifest.stillSchema ? ["media_kind"] : []) + [
                "key_id", "wallpaper_id", "release_id", "edition", "issued_at", "artifacts", "metadata_digest"
            ],
            nestedObjects: ["schema": ["epoch", "revision"]],
            arrayObjectKey: "artifacts",
            arrayObjectKeys: [
                "role", "url", "sha256", "byte_count", "media_type", "width",
                "height", "duration_ms"
            ]
        )


        guard manifest.wallpaperID == context.wallpaperID,
              manifest.releaseID == context.releaseID,
              manifest.metadataDigest == context.metadataDigest
        else {
            throw CatalogValidationError.metadataMismatch
        }
        guard manifest.artifacts.allSatisfy({ artifact in
            artifact.url.host.map { approvedCDNHosts.contains($0.lowercased()) } == true
        }) else {
            throw CatalogValidationError.unapprovedHost
        }
        guard let key = trustedKeys[manifest.keyID] else {
            throw CatalogValidationError.unknownSigningKey
        }
        guard key.isUsable(for: manifest.issuedAt) else {
            throw CatalogValidationError.inactiveSigningKey
        }
        guard let signature = decodeBase64URL(signatureBase64URL, expectedByteCount: 64)
        else {
            throw CatalogValidationError.invalidSignature
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
        guard publicKey.isValidSignature(signature, for: manifestData) else {
            throw CatalogValidationError.invalidSignature
        }
        if revocations?.revokes(manifest) == true {
            throw CatalogValidationError.revokedRelease
        }
        return VerifiedCatalogManifest(manifest: manifest, signedBytes: manifestData)
    }

    public func verifyRevocations(
        data: Data,
        signatureBase64URL: String
    ) throws -> CatalogRevocationList {
        let document = try CanonicalJSON.requireCanonical(data, limits: .revocations)
        try document.requireObjectShape(
            keys: ["schema", "key_id", "revision", "issued_at", "revocations"],
            nestedObjects: ["schema": ["epoch", "revision"]],
            arrayObjectKey: "revocations",
            arrayObjectKeys: ["release_id", "artifact_sha256", "reason", "issued_at"]
        )
        let list: CatalogRevocationList
        do {
            list = try JSONDecoder().decode(CatalogRevocationList.self, from: data)
        } catch let error as CatalogValidationError {
            throw error
        } catch {
            throw CatalogValidationError.invalidManifest
        }
        guard let key = trustedKeys[list.keyID],
              key.status == .active,
              key.isUsable(for: list.issuedAt)
        else {
            throw trustedKeys[list.keyID] == nil
                ? CatalogValidationError.unknownSigningKey
                : CatalogValidationError.inactiveSigningKey
        }
        guard let signature = decodeBase64URL(signatureBase64URL, expectedByteCount: 64)
        else {
            throw CatalogValidationError.invalidSignature
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
        guard publicKey.isValidSignature(signature, for: data) else {
            throw CatalogValidationError.invalidSignature
        }
        return list
    }
}

public struct CatalogInstallMetadata: Codable, Sendable, Hashable {
    public static let schemaValue = "wali.catalog.install-metadata.v1"

    public let schema: String
    public let wallpaperID: String
    public let releaseID: String
    public let edition: UInt64
    public let title: String
    public let creatorName: String
    public let creatorHandle: String
    public let attributionText: String
    public let rightsHolder: String

    enum CodingKeys: String, CodingKey {
        case schema, edition, title
        case wallpaperID = "wallpaper_id"
        case releaseID = "release_id"
        case creatorName = "creator_name"
        case creatorHandle = "creator_handle"
        case attributionText = "attribution_text"
        case rightsHolder = "rights_holder"
    }

    public init(
        schema: String,
        wallpaperID: String,
        releaseID: String,
        edition: UInt64,
        title: String,
        creatorName: String,
        creatorHandle: String,
        attributionText: String,
        rightsHolder: String
    ) throws {
        guard schema == Self.schemaValue,
              validateCanonicalUUID(wallpaperID),
              validateCanonicalUUID(releaseID),
              (1...2_147_483_647).contains(edition),
              Self.validRequired(title, maximum: 256),
              Self.validRequired(creatorName, maximum: 256),
              Self.validOptional(creatorHandle, maximum: 128),
              Self.validOptional(attributionText, maximum: 2_048),
              Self.validRequired(rightsHolder, maximum: 256)
        else {
            throw CatalogValidationError.invalidManifest
        }
        self.schema = schema
        self.wallpaperID = wallpaperID
        self.releaseID = releaseID
        self.edition = edition
        self.title = title
        self.creatorName = creatorName
        self.creatorHandle = creatorHandle
        self.attributionText = attributionText
        self.rightsHolder = rightsHolder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(String.self, forKey: .schema),
            wallpaperID: container.decode(String.self, forKey: .wallpaperID),
            releaseID: container.decode(String.self, forKey: .releaseID),
            edition: container.decode(UInt64.self, forKey: .edition),
            title: container.decode(String.self, forKey: .title),
            creatorName: container.decode(String.self, forKey: .creatorName),
            creatorHandle: container.decode(String.self, forKey: .creatorHandle),
            attributionText: container.decode(String.self, forKey: .attributionText),
            rightsHolder: container.decode(String.self, forKey: .rightsHolder)
        )
    }

    private static func validRequired(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && validOptional(value, maximum: maximum)
    }

    private static func validOptional(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum
            && value == value.precomposedStringWithCanonicalMapping
            && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }
}

public struct VerifiedCatalogInstallMetadata: Sendable, Hashable {
    public let metadata: CatalogInstallMetadata
    public let canonicalBytes: Data
}

extension ManifestVerifier {
    public func verifyMetadata(
        _ data: Data,
        for verifiedManifest: VerifiedCatalogManifest
    ) throws -> VerifiedCatalogInstallMetadata {
        let document = try CanonicalJSON.requireCanonical(data, limits: .installMetadata)
        try document.requireObjectShape(keys: [
            "schema", "wallpaper_id", "release_id", "edition", "title",
            "creator_name", "creator_handle", "attribution_text", "rights_holder"
        ])

        let metadata: CatalogInstallMetadata
        do {
            metadata = try JSONDecoder().decode(CatalogInstallMetadata.self, from: data)
        } catch let error as CatalogValidationError {
            throw error
        } catch {
            throw CatalogValidationError.invalidManifest
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == verifiedManifest.manifest.metadataDigest,
              metadata.wallpaperID == verifiedManifest.manifest.wallpaperID,
              metadata.releaseID == verifiedManifest.manifest.releaseID,
              metadata.edition == verifiedManifest.manifest.edition
        else {
            throw CatalogValidationError.metadataMismatch
        }
        return VerifiedCatalogInstallMetadata(metadata: metadata, canonicalBytes: data)
    }
}

public struct CatalogTrustTransitionKey: Codable, Sendable, Hashable {
    public let keyID: CatalogKeyID
    public let publicKeyBase64URL: String
    public let validFrom: Date
    public let validUntil: Date
    public let status: CatalogSigningKeyStatus

    enum CodingKeys: String, CodingKey {
        case status
        case keyID = "key_id"
        case publicKeyBase64URL = "public_key"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }

    public init(
        keyID: CatalogKeyID,
        publicKeyBase64URL: String,
        validFrom: Date,
        validUntil: Date,
        status: CatalogSigningKeyStatus
    ) throws {
        guard decodeBase64URL(publicKeyBase64URL, expectedByteCount: 32) != nil,
              validFrom < validUntil
        else {
            throw CatalogValidationError.invalidTrustTransition
        }
        self.keyID = keyID
        self.publicKeyBase64URL = publicKeyBase64URL
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keyID: container.decode(CatalogKeyID.self, forKey: .keyID),
            publicKeyBase64URL: container.decode(String.self, forKey: .publicKeyBase64URL),
            validFrom: try parseCatalogTimestamp(container.decode(String.self, forKey: .validFrom)),
            validUntil: try parseCatalogTimestamp(container.decode(String.self, forKey: .validUntil)),
            status: container.decode(CatalogSigningKeyStatus.self, forKey: .status)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(publicKeyBase64URL, forKey: .publicKeyBase64URL)
        try container.encode(formatCatalogTimestamp(validFrom), forKey: .validFrom)
        try container.encode(formatCatalogTimestamp(validUntil), forKey: .validUntil)
        try container.encode(status, forKey: .status)
    }

    fileprivate func trustedKey() throws -> TrustedCatalogSigningKey {
        guard let publicKey = decodeBase64URL(publicKeyBase64URL, expectedByteCount: 32) else {
            throw CatalogValidationError.invalidTrustTransition
        }
        return try TrustedCatalogSigningKey(
            id: keyID,
            publicKey: publicKey,
            validFrom: validFrom,
            validUntil: validUntil,
            status: status
        )
    }
}

public struct CatalogTrustTransition: Codable, Sendable, Hashable {
    public static let schemaValue = "wali.catalog.trust-transition.v1"
    public static let maximumKeyCount = 32

    public let schema: String
    public let revision: UInt64
    public let issuedAt: Date
    public let keys: [CatalogTrustTransitionKey]

    enum CodingKeys: String, CodingKey {
        case schema, revision, keys
        case issuedAt = "issued_at"
    }

    public init(
        schema: String,
        revision: UInt64,
        issuedAt: Date,
        keys: [CatalogTrustTransitionKey]
    ) throws {
        guard schema == Self.schemaValue,
              (1...2_147_483_647).contains(revision),
              !keys.isEmpty,
              keys.count <= Self.maximumKeyCount,
              Set(keys.map(\.keyID)).count == keys.count,
              keys.map(\.keyID.rawValue) == keys.map(\.keyID.rawValue).sorted()
        else {
            throw CatalogValidationError.invalidTrustTransition
        }
        self.schema = schema
        self.revision = revision
        self.issuedAt = issuedAt
        self.keys = keys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(String.self, forKey: .schema),
            revision: container.decode(UInt64.self, forKey: .revision),
            issuedAt: try parseCatalogTimestamp(container.decode(String.self, forKey: .issuedAt)),
            keys: container.decode([CatalogTrustTransitionKey].self, forKey: .keys)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(revision, forKey: .revision)
        try container.encode(formatCatalogTimestamp(issuedAt), forKey: .issuedAt)
        try container.encode(keys, forKey: .keys)
    }
}

public struct VerifiedCatalogTrustTransition: Sendable, Hashable {
    public let transition: CatalogTrustTransition
    public let trustedKeys: [TrustedCatalogSigningKey]
    public let canonicalBytes: Data
    public let signatureBase64URL: String
    public let signingKeyID: CatalogKeyID
}

public struct CatalogTrustTransitionVerifier: Sendable {
    private let compiledAnchors: [CatalogKeyID: TrustedCatalogSigningKey]

    public init(compiledAnchors: [TrustedCatalogSigningKey]) throws {
        guard !compiledAnchors.isEmpty,
              compiledAnchors.count <= CatalogTrustTransition.maximumKeyCount,
              Set(compiledAnchors.map(\.id)).count == compiledAnchors.count
        else {
            throw CatalogValidationError.invalidTrustTransition
        }
        self.compiledAnchors = Dictionary(uniqueKeysWithValues: compiledAnchors.map { ($0.id, $0) })
    }

    public func verify(
        data: Data,
        signatureBase64URL: String,
        signingKeyID: CatalogKeyID
    ) throws -> VerifiedCatalogTrustTransition {
        let document = try CanonicalJSON.requireCanonical(data, limits: .trustTransition)
        try document.requireObjectShape(
            keys: ["schema", "revision", "issued_at", "keys"],
            arrayObjectKey: "keys",
            arrayObjectKeys: ["key_id", "public_key", "valid_from", "valid_until", "status"]
        )
        let transition: CatalogTrustTransition
        do {
            transition = try JSONDecoder().decode(CatalogTrustTransition.self, from: data)
        } catch let error as CatalogValidationError {
            throw error
        } catch {
            throw CatalogValidationError.invalidTrustTransition
        }
        guard let anchor = compiledAnchors[signingKeyID] else {
            throw CatalogValidationError.unknownSigningKey
        }
        guard anchor.status == .active, anchor.isUsable(for: transition.issuedAt) else {
            throw CatalogValidationError.inactiveSigningKey
        }
        guard let signature = decodeBase64URL(signatureBase64URL, expectedByteCount: 64) else {
            throw CatalogValidationError.invalidSignature
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: anchor.publicKey)
        guard publicKey.isValidSignature(signature, for: data) else {
            throw CatalogValidationError.invalidSignature
        }

        let trustedKeys = try transition.keys.map { try $0.trustedKey() }
        let transitionedByID = Dictionary(uniqueKeysWithValues: trustedKeys.map { ($0.id, $0) })
        for compiled in compiledAnchors.values {
            guard let transitioned = transitionedByID[compiled.id],
                  transitioned.publicKey == compiled.publicKey,
                  transitioned.validFrom == compiled.validFrom,
                  transitioned.validUntil == compiled.validUntil,
                  Self.validStatusSuccessor(from: compiled.status, to: transitioned.status)
            else {
                throw CatalogValidationError.invalidTrustTransition
            }
        }
        return VerifiedCatalogTrustTransition(
            transition: transition,
            trustedKeys: trustedKeys,
            canonicalBytes: data,
            signatureBase64URL: signatureBase64URL,
            signingKeyID: signingKeyID
        )
    }

    public func verifySuccessor(
        data: Data,
        signatureBase64URL: String,
        signingKeyID: CatalogKeyID,
        previous: VerifiedCatalogTrustTransition
    ) throws -> VerifiedCatalogTrustTransition {
        guard let priorSigner = previous.trustedKeys.first(where: { $0.id == signingKeyID }),
              priorSigner.status == .active
        else {
            throw CatalogValidationError.inactiveSigningKey
        }
        let candidate = try verify(
            data: data,
            signatureBase64URL: signatureBase64URL,
            signingKeyID: signingKeyID
        )
        if candidate.transition.revision == previous.transition.revision {
            guard candidate.canonicalBytes == previous.canonicalBytes else {
                throw CatalogValidationError.trustTransitionEquivocation
            }
            return previous
        }
        guard candidate.transition.revision > previous.transition.revision,
              candidate.transition.issuedAt >= previous.transition.issuedAt
        else {
            throw CatalogValidationError.staleTrustTransition
        }
        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.trustedKeys.map { ($0.id, $0) })
        for prior in previous.trustedKeys {
            guard let next = candidateByID[prior.id],
                  next.publicKey == prior.publicKey,
                  next.validFrom == prior.validFrom,
                  next.validUntil == prior.validUntil,
                  Self.validStatusSuccessor(from: prior.status, to: next.status)
            else {
                throw CatalogValidationError.invalidTrustTransition
            }
        }
        return candidate
    }

    private static func validStatusSuccessor(
        from old: CatalogSigningKeyStatus,
        to new: CatalogSigningKeyStatus
    ) -> Bool {
        switch old {
        case .active:
            return true
        case .retired:
            return new == .retired || new == .compromised
        case .compromised:
            return new == .compromised
        }
    }
}
