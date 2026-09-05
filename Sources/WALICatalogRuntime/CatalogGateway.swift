import Foundation

public enum CatalogBrowseSort: String, Codable, Sendable, Hashable {
    case featured
    case trending
    case newest
    case mostInstalled = "most_installed"
}

public struct CatalogBrowseRequest: Sendable, Hashable {
    public let category: String?
    public let tags: [String]
    public let sort: CatalogBrowseSort
    public let cursor: String?
    public let limit: Int

    public init(
        category: String? = nil,
        tags: [String] = [],
        sort: CatalogBrowseSort = .featured,
        cursor: String? = nil,
        limit: Int = 24
    ) throws {
        guard tags.count <= 10,
              Set(tags).count == tags.count,
              (1...50).contains(limit)
        else {
            throw CatalogRequestError.invalidRequest
        }
        try validateSlug(category)
        try tags.forEach { try validateSlug($0) }
        try validateCursor(cursor)
        self.category = category
        self.tags = tags
        self.sort = sort
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CatalogSearchRequest: Sendable, Hashable {
    public let query: String
    public let category: String?
    public let tags: [String]
    public let ratingCeiling: String
    public let minimumDurationMilliseconds: UInt64?
    public let maximumDurationMilliseconds: UInt64?
    public let cursor: String?
    public let limit: Int

    public init(
        query: String,
        category: String? = nil,
        tags: [String] = [],
        ratingCeiling: String = "mature",
        minimumDurationMilliseconds: UInt64? = nil,
        maximumDurationMilliseconds: UInt64? = nil,
        cursor: String? = nil,
        limit: Int = 24
    ) throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.count <= 200,
              Array(query.utf8) == Array(query.precomposedStringWithCanonicalMapping.utf8),
              tags.count <= 10,
              Set(tags).count == tags.count,
              ["everyone", "teen", "mature"].contains(ratingCeiling),
              (1...50).contains(limit),
              minimumDurationMilliseconds.map({ (1...600_000).contains($0) }) ?? true,
              maximumDurationMilliseconds.map({ (1...600_000).contains($0) }) ?? true,
              minimumDurationMilliseconds.map({ minimum in
                  maximumDurationMilliseconds.map { minimum <= $0 } ?? true
              }) ?? true
        else {
            throw CatalogRequestError.invalidRequest
        }
        try validateSlug(category)
        try tags.forEach { try validateSlug($0) }
        try validateCursor(cursor)
        self.query = query
        self.category = category
        self.tags = tags
        self.ratingCeiling = ratingCeiling
        self.minimumDurationMilliseconds = minimumDurationMilliseconds
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CatalogInteractionResult: Sendable, Hashable {
    public let desired: Bool
    public let revision: UInt64
    public let aggregateCount: UInt64
}

public struct CatalogInstallGrant: Sendable, Hashable {
    public let manifestBody: Data
    public let metadataBody: Data
    public let signatureBase64URL: String
    public let keyID: String
    public let receipt: String
    public let expiresAt: Date

    public init(
        manifestBody: Data,
        metadataBody: Data = Data(),
        signatureBase64URL: String,
        keyID: String,
        receipt: String,
        expiresAt: Date
    ) {
        self.manifestBody = manifestBody
        self.metadataBody = metadataBody
        self.signatureBase64URL = signatureBase64URL
        self.keyID = keyID
        self.receipt = receipt
        self.expiresAt = expiresAt
    }
}

public struct CatalogSignedDocument: Codable, Sendable, Hashable {
    public let revision: UInt64
    public let canonicalBody: Data
    public let signatureBase64URL: String
    public let keyID: String

    public init(
        revision: UInt64,
        canonicalBody: Data,
        signatureBase64URL: String,
        keyID: String
    ) {
        self.revision = revision
        self.canonicalBody = canonicalBody
        self.signatureBase64URL = signatureBase64URL
        self.keyID = keyID
    }
}

public struct CatalogSecurityState: Codable, Sendable, Hashable {
    public let trustTransition: CatalogSignedDocument?
    public let revocations: CatalogSignedDocument

    public init(
        trustTransition: CatalogSignedDocument?,
        revocations: CatalogSignedDocument
    ) {
        self.trustTransition = trustTransition
        self.revocations = revocations
    }
}

public enum CatalogReportKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case copyright
    case trademark
    case unsafeContent = "unsafe_content"
    case misleadingMetadata = "misleading_metadata"
    case technicalIssue = "technical_issue"
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .copyright: "Copyright"
        case .trademark: "Trademark"
        case .unsafeContent: "Unsafe content"
        case .misleadingMetadata: "Misleading metadata"
        case .technicalIssue: "Technical issue"
        case .other: "Other"
        }
    }
}

public struct CatalogReportRequest: Sendable, Hashable {
    public let wallpaperID: String
    public let releaseID: String?
    public let kind: CatalogReportKind
    public let detail: String
    public let idempotencyKey: String

    public init(
        wallpaperID: String,
        releaseID: String?,
        kind: CatalogReportKind,
        detail: String,
        idempotencyKey: String
    ) throws {
        guard Self.isCanonicalUUID(wallpaperID),
              releaseID.map(Self.isCanonicalUUID) ?? true,
              (1...2_000).contains(detail.count),
              detail.utf8.count <= 8_000,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detail == detail.precomposedStringWithCanonicalMapping,
              !detail.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (16...64).contains(idempotencyKey.utf8.count),
              idempotencyKey.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            throw CatalogRequestError.invalidRequest
        }
        self.wallpaperID = wallpaperID
        self.releaseID = releaseID
        self.kind = kind
        self.detail = detail
        self.idempotencyKey = idempotencyKey
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public struct CatalogReportReceipt: Sendable, Hashable {
    public let id: String
    public let status: String
    public let createdAt: Date

    public init(id: String, status: String, createdAt: Date) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
    }
}

public struct MarketplaceAccountProfile: Sendable, Hashable {
    public let id: String
    public let handle: String
    public let displayName: String
    public let status: String
    public let revision: UInt64

    public init(id: String, handle: String, displayName: String, status: String, revision: UInt64) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              (1...40).contains(handle.utf8.count),
              (1...120).contains(displayName.count),
              ["active", "suspended", "deletion_pending", "deleted"].contains(status),
              revision <= 9_007_199_254_740_991
        else { throw CatalogMappingError.invalidResponse }
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.status = status
        self.revision = revision
    }
}

public enum AccountExportStatus: String, Codable, Sendable, Hashable {
    case queued
    case processing
    case ready
    case expired
    case failed
}

public struct AccountExportSnapshot: Sendable, Hashable {
    public let id: String
    public let subjectID: String
    public let status: AccountExportStatus
    public let expiresAt: Date
    public let completedAt: Date?
    public let byteCount: UInt64?
    public let sha256: String?
    public let downloadURL: URL?
    public let downloadExpiresAt: Date?

    public init(
        id: String,
        subjectID: String,
        status: AccountExportStatus,
        expiresAt: Date,
        completedAt: Date?,
        byteCount: UInt64?,
        sha256: String?,
        downloadURL: URL?,
        downloadExpiresAt: Date?
    ) throws {
        let hasDownload = byteCount != nil || sha256 != nil || downloadURL != nil || downloadExpiresAt != nil
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              UUID(uuidString: subjectID)?.uuidString.lowercased() == subjectID,
              expiresAt > Date(timeIntervalSince1970: 0),
              (status == .ready) == hasDownload,
              status != .ready || (
                  (2...104_857_600).contains(byteCount ?? 0)
                      && sha256?.utf8.count == 64
                      && sha256?.utf8.allSatisfy({
                          (48...57).contains($0) || (97...102).contains($0)
                      }) == true
                      && downloadURL != nil
                      && downloadExpiresAt != nil
              )
        else { throw CatalogMappingError.invalidResponse }
        self.id = id
        self.subjectID = subjectID
        self.status = status
        self.expiresAt = expiresAt
        self.completedAt = completedAt
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.downloadExpiresAt = downloadExpiresAt
    }
}

public enum AccountDeletionStatus: String, Codable, Sendable, Hashable {
    case pending
    case processing
    case held
    case awaitingAuthCleanup = "awaiting_auth_cleanup"
    case completed
    case failed
    case cancelled
}

public enum AccountIdentityDeletionStatus: String, Codable, Sendable, Hashable {
    case sessionRevocationPending = "session_revocation_pending"
    case sessionsRevoked = "sessions_revoked"
    case operatorCleanupRequired = "operator_cleanup_required"
    case completed
}

public struct AccountDeletionSnapshot: Sendable, Hashable {
    public let id: String
    public let subjectID: String
    public let status: AccountDeletionStatus
    public let identityStatus: AccountIdentityDeletionStatus
    public let revision: UInt64
    public let requestedAt: Date
    public let completedAt: Date?
    public let held: Bool

    public init(
        id: String,
        subjectID: String,
        status: AccountDeletionStatus,
        identityStatus: AccountIdentityDeletionStatus,
        revision: UInt64,
        requestedAt: Date,
        completedAt: Date?,
        held: Bool
    ) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              UUID(uuidString: subjectID)?.uuidString.lowercased() == subjectID,
              revision <= 9_007_199_254_740_991,
              held == (status == .held),
              (status == .completed) == (identityStatus == .completed && completedAt != nil)
        else { throw CatalogMappingError.invalidResponse }
        self.id = id
        self.subjectID = subjectID
        self.status = status
        self.identityStatus = identityStatus
        self.revision = revision
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.held = held
    }
}

public enum CatalogRequestError: String, Error, Sendable {
    case invalidRequest = "invalid_request"
    case invalidConfiguration = "invalid_configuration"
    case notConfigured = "not_configured"
}

public protocol CatalogGateway: Sendable {
    func home(locale: String, ratingCeiling: String) async throws -> CatalogHome
    func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage
    func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage
    func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail
    func setFavorite(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult
    func setSaved(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult
    func requestInstall(
        wallpaperID: String,
        releaseID: String,
        expectedWallpaperRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInstallGrant
    func recordInstall(
        receipt: String,
        manifestDigest: String,
        releaseID: String,
        idempotencyKey: String
    ) async throws
    func securityState() async throws -> CatalogSecurityState
}

public protocol CatalogReportGateway: Sendable {
    func report(_ request: CatalogReportRequest) async throws -> CatalogReportReceipt
}

public struct AccountPrivacyOperationReferences: Sendable {
    public let subjectID: String
    public let exportID: String?
    public let deletionID: String?

    public init(subjectID: String, exportID: String?, deletionID: String?) throws {
        guard UUID(uuidString: subjectID)?.uuidString.lowercased() == subjectID,
              [exportID, deletionID].compactMap({ $0 }).allSatisfy({
                  UUID(uuidString: $0)?.uuidString.lowercased() == $0
              })
        else { throw CatalogMappingError.invalidResponse }
        self.subjectID = subjectID
        self.exportID = exportID
        self.deletionID = deletionID
    }
}

public protocol AccountPrivacyGateway: Sendable {
    func accountProfile() async throws -> MarketplaceAccountProfile
    func accountOperationReferences() async throws -> AccountPrivacyOperationReferences?
    func requestAccountExport(idempotencyKey: String) async throws -> AccountExportSnapshot
    func accountExportStatus(id: String, idempotencyKey: String) async throws -> AccountExportSnapshot
    func saveAccountExport(_ snapshot: AccountExportSnapshot, to destination: URL) async throws
    func requestAccountDeletion(
        expectedProfileRevision: UInt64,
        confirmation: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionSnapshot
    func accountDeletionStatus(id: String, idempotencyKey: String) async throws -> AccountDeletionSnapshot
}

public extension AccountPrivacyGateway {
    func accountOperationReferences() async throws -> AccountPrivacyOperationReferences? { nil }
}

public extension CatalogGateway {
    func securityState() async throws -> CatalogSecurityState {
        throw CatalogRequestError.notConfigured
    }
}

/// Deterministic local gateway for previews, UI development, and offline fallback.
public actor DeterministicCatalogGateway: CatalogGateway {
    private let homeValue: CatalogHome
    private let details: [String: CatalogWallpaperDetail]

    public init(home: CatalogHome, details: [String: CatalogWallpaperDetail] = [:]) {
        homeValue = home
        self.details = details
    }

    public func home(locale: String, ratingCeiling: String) async throws -> CatalogHome {
        homeValue
    }

    public func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage {
        CatalogPage(items: homeValue.sections.flatMap(\.items), nextCursor: nil)
    }

    public func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage {
        let matches = homeValue.sections.flatMap(\.items).filter {
            $0.title.localizedCaseInsensitiveContains(request.query)
        }
        return CatalogSearchPage(
            page: CatalogPage(items: matches, nextCursor: nil),
            rankingExplanation: CatalogRankingExplanation(
                formulaRevision: "deterministic-preview-v1",
                modelRevision: nil
            )
        )
    }

    public func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail {
        guard let detail = details[wallpaperID] else {
            throw CatalogRemoteError(code: "not_found", safeMessage: nil, retryable: false)
        }
        return detail
    }

    public func setFavorite(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        throw CatalogRequestError.notConfigured
    }

    public func setSaved(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        throw CatalogRequestError.notConfigured
    }

    public func requestInstall(
        wallpaperID: String,
        releaseID: String,
        expectedWallpaperRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInstallGrant {
        throw CatalogRequestError.notConfigured
    }

    public func recordInstall(
        receipt: String,
        manifestDigest: String,
        releaseID: String,
        idempotencyKey: String
    ) async throws {
        throw CatalogRequestError.notConfigured
    }
}

private func validateSlug(_ value: String?) throws {
    guard let value else { return }
    guard !value.isEmpty,
          value.count <= 80,
          value.utf8.allSatisfy({
              (48...57).contains($0) || (97...122).contains($0) || $0 == 45
          })
    else {
        throw CatalogRequestError.invalidRequest
    }
}

private func validateCursor(_ value: String?) throws {
    guard let value else { return }
    guard !value.isEmpty,
          value.utf8.count <= 1_024,
          value.utf8.allSatisfy({
              (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
          })
    else {
        throw CatalogRequestError.invalidRequest
    }
}
