import Foundation
import WALIModel

public typealias CatalogSchemaVersion = RecordSchemaVersion

public struct CatalogArtifact: Codable, Sendable, Hashable {
    public static let maximumByteCount: UInt64 = 2_147_483_648

    public let role: CatalogArtifactRole
    public let url: URL
    public let sha256: String
    public let byteCount: UInt64
    public let mediaType: String
    public let width: UInt32
    public let height: UInt32
    public let durationMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case role, url, sha256, width, height
        case byteCount = "byte_count"
        case mediaType = "media_type"
        case durationMilliseconds = "duration_ms"
    }

    public init(
        role: CatalogArtifactRole,
        url: URL,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        width: UInt32,
        height: UInt32,
        durationMilliseconds: UInt64
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.host.map(validateCatalogPublicHostname) == true,
              url.absoluteString.utf8.count <= 2_048,
              validateSHA256(sha256),
              (1...Self.maximumByteCount).contains(byteCount),
              ["video/mp4", "image/avif", "image/jpeg", "image/png"].contains(mediaType),
              (1...7_680).contains(width),
              (1...4_320).contains(height),
              durationMilliseconds <= 600_000
        else {
            throw CatalogValidationError.invalidArtifact
        }
        let videoRole = role == .preview
            || role == .videoDefault
            || role == .video1080p
            || role == .video1440p
            || role == .video2160p
        guard videoRole == (mediaType == "video/mp4"),
              videoRole ? durationMilliseconds > 0 : durationMilliseconds == 0
        else {
            throw CatalogValidationError.invalidArtifact
        }
        self.role = role
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: container.decode(CatalogArtifactRole.self, forKey: .role),
            url: container.decode(URL.self, forKey: .url),
            sha256: container.decode(String.self, forKey: .sha256),
            byteCount: container.decode(UInt64.self, forKey: .byteCount),
            mediaType: container.decode(String.self, forKey: .mediaType),
            width: container.decode(UInt32.self, forKey: .width),
            height: container.decode(UInt32.self, forKey: .height),
            durationMilliseconds: container.decode(UInt64.self, forKey: .durationMilliseconds)
        )
    }
}

public struct CatalogManifest: Codable, Sendable, Hashable {
    public static let minimumArtifactCount = 4
    public static let maximumArtifactCount = 7

    public let schema: CatalogSchemaVersion
    public let keyID: CatalogKeyID
    public let wallpaperID: String
    public let releaseID: String
    public let edition: UInt64
    public let issuedAt: Date
    public let artifacts: [CatalogArtifact]
    public let metadataDigest: String

    enum CodingKeys: String, CodingKey {
        case schema, edition, artifacts
        case keyID = "key_id"
        case wallpaperID = "wallpaper_id"
        case releaseID = "release_id"
        case issuedAt = "issued_at"
        case metadataDigest = "metadata_digest"
    }

    public init(
        schema: CatalogSchemaVersion,
        keyID: CatalogKeyID,
        wallpaperID: String,
        releaseID: String,
        edition: UInt64,
        issuedAt: Date,
        artifacts: [CatalogArtifact],
        metadataDigest: String
    ) throws {
        guard schema == .current else { throw CatalogValidationError.unsupportedSchema }
        guard validateCanonicalUUID(wallpaperID),
              validateCanonicalUUID(releaseID),
              (1...2_147_483_647).contains(edition),
              artifacts.count >= Self.minimumArtifactCount,
              artifacts.count <= Self.maximumArtifactCount,
              validateSHA256(metadataDigest),
              Set(artifacts.map(\.role)).count == artifacts.count,
              Set(artifacts.map(\.role)).isSuperset(of: [
                  .thumbnail, .poster, .preview, .videoDefault
              ]),
              artifacts == artifacts.sorted(by: Self.artifactOrder)
        else {
            throw CatalogValidationError.invalidManifest
        }
        self.schema = schema
        self.keyID = keyID
        self.wallpaperID = wallpaperID
        self.releaseID = releaseID
        self.edition = edition
        self.issuedAt = issuedAt
        self.artifacts = artifacts
        self.metadataDigest = metadataDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(CatalogSchemaVersion.self, forKey: .schema),
            keyID: container.decode(CatalogKeyID.self, forKey: .keyID),
            wallpaperID: container.decode(String.self, forKey: .wallpaperID),
            releaseID: container.decode(String.self, forKey: .releaseID),
            edition: container.decode(UInt64.self, forKey: .edition),
            issuedAt: try parseCatalogTimestamp(
                container.decode(String.self, forKey: .issuedAt)
            ),
            artifacts: container.decode([CatalogArtifact].self, forKey: .artifacts),
            metadataDigest: container.decode(String.self, forKey: .metadataDigest)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(wallpaperID, forKey: .wallpaperID)
        try container.encode(releaseID, forKey: .releaseID)
        try container.encode(edition, forKey: .edition)
        try container.encode(formatCatalogTimestamp(issuedAt), forKey: .issuedAt)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(metadataDigest, forKey: .metadataDigest)
    }

    private static func artifactOrder(_ lhs: CatalogArtifact, _ rhs: CatalogArtifact) -> Bool {
        if lhs.role.canonicalOrder == rhs.role.canonicalOrder { return lhs.sha256 < rhs.sha256 }
        return lhs.role.canonicalOrder < rhs.role.canonicalOrder
    }
}

func parseCatalogTimestamp(_ value: String) throws -> Date {
    guard value.utf8.count == 20,
          value[value.index(value.startIndex, offsetBy: 4)] == "-",
          value[value.index(value.startIndex, offsetBy: 7)] == "-",
          value[value.index(value.startIndex, offsetBy: 10)] == "T",
          value[value.index(value.startIndex, offsetBy: 13)] == ":",
          value[value.index(value.startIndex, offsetBy: 16)] == ":",
          value.last == "Z"
    else {
        throw CatalogValidationError.invalidManifest
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        throw CatalogValidationError.invalidManifest
    }
    return date
}

func formatCatalogTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
