import Foundation

/// A stable catalog signing-key identifier.
public struct CatalogKeyID: Codable, Sendable, Hashable {
    public static let maximumUTF8Length = 64
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty,
              bytes.count <= Self.maximumUTF8Length,
              bytes.allSatisfy({
                  isLowercaseASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
              })
        else {
            throw CatalogValidationError.invalidKeyID
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Semantic role of a downloadable catalog artifact.
public enum CatalogArtifactRole: String, Codable, Sendable, CaseIterable {
    case thumbnail
    case poster
    case preview
    case imageDefault = "image_default"
    case videoDefault = "video_default"
    case video1080p = "video_1080p"
    case video1440p = "video_1440p"
    case video2160p = "video_2160p"

    var canonicalOrder: Int {
        switch self {
        case .thumbnail: 0
        case .poster: 1
        case .preview: 2
        case .imageDefault: 3
        case .videoDefault: 3
        case .video1080p: 4
        case .video1440p: 5
        case .video2160p: 6
        }
    }
}

/// Stable validation and verification failures safe to map to UI copy.
public enum CatalogValidationError: String, Error, Codable, Sendable, Equatable {
    case invalidKeyID = "invalid_key_id"
    case invalidIdentifier = "invalid_identifier"
    case invalidDigest = "invalid_digest"
    case invalidArtifact = "invalid_artifact"
    case invalidManifest = "invalid_manifest"
    case unsupportedSchema = "unsupported_schema"
    case invalidCanonicalJSON = "invalid_canonical_json"
    case duplicateJSONKey = "duplicate_json_key"
    case documentTooLarge = "document_too_large"
    case nestingTooDeep = "nesting_too_deep"
    case collectionTooLarge = "collection_too_large"
    case stringTooLarge = "string_too_large"
    case floatingPointNumber = "floating_point_number"
    case unapprovedHost = "unapproved_host"
    case unknownSigningKey = "unknown_signing_key"
    case inactiveSigningKey = "inactive_signing_key"
    case invalidSignature = "invalid_signature"
    case metadataMismatch = "metadata_mismatch"
    case revokedRelease = "revoked_release"
    case invalidTrustTransition = "invalid_trust_transition"
    case staleTrustTransition = "stale_trust_transition"
    case trustTransitionEquivocation = "trust_transition_equivocation"
    case staleRevocations = "stale_revocations"
    case revocationEquivocation = "revocation_equivocation"
}

func validateCanonicalUUID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 36 else { return false }
    let hyphens = Set([8, 13, 18, 23])
    return bytes.indices.allSatisfy { index in
        hyphens.contains(index) ? bytes[index] == 45 : isLowercaseHex(bytes[index])
    }
}

func validateSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy(isLowercaseHex)
}

/// Catalog network hosts must be canonical public DNS names. This excludes
/// loopback, link-local and single-label names even when configuration is
/// accidentally pointed at one of them.
public func validateCatalogPublicHostname(_ host: String) -> Bool {
    guard host == host.lowercased(),
          host.utf8.count <= 253,
          host.contains("."),
          !host.hasPrefix("."),
          !host.hasSuffix("."),
          !host.contains(":"),
          host != "localhost",
          !host.hasSuffix(".localhost"),
          !host.hasSuffix(".local"),
          !host.hasSuffix(".internal")
    else {
        return false
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
    return labels.allSatisfy { label in
        !label.isEmpty
            && label.utf8.count <= 63
            && label.first != "-"
            && label.last != "-"
            && label.utf8.allSatisfy {
                (48...57).contains($0) || (97...122).contains($0) || $0 == 45
            }
    }
}

private func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
}

private func isLowercaseASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...122).contains(byte)
}

func decodeBase64URL(_ value: String, expectedByteCount: Int) -> Data? {
    guard !value.contains("="),
          value.utf8.allSatisfy({
              (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45
                || $0 == 95
          })
    else {
        return nil
    }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    guard let data = Data(base64Encoded: base64), data.count == expectedByteCount else {
        return nil
    }
    return data
}
