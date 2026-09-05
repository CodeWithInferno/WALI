import Foundation
import WALICatalog

enum CatalogMappingError: String, Error, Sendable {
    case invalidResponse = "invalid_response"
    case responseTooLarge = "response_too_large"
    case unsupportedAPIVersion = "unsupported_api_version"
}

struct CatalogMapper: Sendable {
    private let remoteURLPolicy: CatalogRemoteURLPolicy

    init(remoteURLPolicy: CatalogRemoteURLPolicy) {
        self.remoteURLPolicy = remoteURLPolicy
    }

    func home(_ value: CatalogHomeDTO) throws -> CatalogHome {
        guard value.sections.count <= 8 else { throw CatalogMappingError.invalidResponse }
        return CatalogHome(sections: try value.sections.map(section))
    }

    func page(_ value: CatalogPageDTO) throws -> CatalogPage {
        try CatalogPage(items: mapPageItems(value.items), nextCursor: cursor(value.nextCursor))
    }

    func searchPage(_ value: CatalogSearchPageDTO) throws -> CatalogSearchPage {
        let page = try CatalogPage(items: mapPageItems(value.items), nextCursor: cursor(value.nextCursor))
        try requireBoundedText(value.rankingExplanation.formulaRevision, maximum: 80)
        if let modelRevision = value.rankingExplanation.modelRevision {
            try requireBoundedText(modelRevision, maximum: 80)
        }
        return CatalogSearchPage(
            page: page,
            rankingExplanation: CatalogRankingExplanation(
                formulaRevision: value.rankingExplanation.formulaRevision,
                modelRevision: value.rankingExplanation.modelRevision
            )
        )
    }

    func detail(_ value: WallpaperDetailDTO) throws -> CatalogWallpaperDetail {
        try requireBoundedText(value.description, maximum: 2_000)
        try requireBoundedText(value.rightsHolder, maximum: 160)
        if let attribution = value.attributionText {
            try requireBoundedText(attribution, maximum: 1_000, allowBlank: true)
        }
        guard value.edition > 0,
              value.edition <= 2_147_483_647,
              (1...600_000).contains(value.durationMilliseconds),
              (1...7_680).contains(value.width),
              (1...4_320).contains(value.height),
              value.frameRateNumerator > 0,
              value.frameRateDenominator > 0,
              Double(value.frameRateNumerator) / Double(value.frameRateDenominator) <= 240,
              value.videoDefault.role == "video_default",
              validRevision(value.favoriteRevision),
              validRevision(value.savedRevision),
              value.related.count <= 24,
              validExternalURL(value.sourceURL),
              validExternalURL(value.license.termsURL),
              value.license.redistributionAllowed,
              value.license.termsRevision > 0,
              value.license.termsRevision <= 2_147_483_647,
              isLicenseCode(value.license.code)
        else {
            throw CatalogMappingError.invalidResponse
        }
        try requireBoundedText(value.license.name, maximum: 120)
        return CatalogWallpaperDetail(
            summary: try summary(value.wallpaper),
            description: value.description,
            edition: value.edition,
            rightsHolder: value.rightsHolder,
            attributionText: value.attributionText,
            sourceURL: value.sourceURL,
            license: CatalogLicense(
                code: value.license.code,
                name: value.license.name,
                termsURL: value.license.termsURL,
                attributionRequired: value.license.attributionRequired,
                commercialUseAllowed: value.license.commercialUseAllowed,
                derivativesAllowed: value.license.derivativesAllowed,
                redistributionAllowed: value.license.redistributionAllowed,
                termsRevision: value.license.termsRevision
            ),
            durationMilliseconds: value.durationMilliseconds,
            width: value.width,
            height: value.height,
            frameRateNumerator: value.frameRateNumerator,
            frameRateDenominator: value.frameRateDenominator,
            videoDefault: try artifact(value.videoDefault),
            related: try value.related.map(summary),
            isFavorite: value.isFavorite,
            favoriteRevision: value.favoriteRevision,
            isSaved: value.isSaved,
            savedRevision: value.savedRevision
        )
    }

    func payload<T: Decodable & Sendable>(
        _ envelope: CatalogFunctionEnvelope<T>,
        apiVersion: String,
        expectedRequestID: String
    ) throws -> T {
        guard envelope.apiVersion == apiVersion,
              envelope.requestID == expectedRequestID,
              UUID(uuidString: expectedRequestID)?.uuidString.lowercased() == expectedRequestID,
              (envelope.data == nil) != (envelope.error == nil)
        else {
            throw CatalogMappingError.invalidResponse
        }
        if let error = envelope.error {
            guard !error.code.isEmpty, error.code.utf8.count <= 64,
                  error.code.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
            else { throw CatalogMappingError.invalidResponse }
            throw CatalogRemoteError(
                code: error.code,
                safeMessage: nil,
                retryable: error.retryable
            )
        }
        guard let data = envelope.data else { throw CatalogMappingError.invalidResponse }
        return data
    }

    private func section(_ value: HomeSectionDTO) throws -> CatalogHomeSection {
        try requireBoundedText(value.id, maximum: 80)
        try requireBoundedText(value.title, maximum: 120)
        guard value.items.count <= 24 else { throw CatalogMappingError.invalidResponse }
        let kind: CatalogHomeSection.Kind = switch value.kind {
        case "editorial": .editorial
        case "trending": .trending
        case "new": .new
        case "for_you": .forYou
        case "category": .category
        default: .unknown(value.kind)
        }
        return CatalogHomeSection(
            id: value.id,
            title: value.title,
            kind: kind,
            cursor: try cursor(value.cursor),
            items: try value.items.map(summary)
        )
    }

    private func mapPageItems(_ values: [WallpaperSummaryDTO]) throws -> [CatalogWallpaperSummary] {
        guard values.count <= 50 else { throw CatalogMappingError.invalidResponse }
        return try values.map(summary)
    }

    private func summary(_ value: WallpaperSummaryDTO) throws -> CatalogWallpaperSummary {
        guard isUUID(value.id),
              isUUID(value.currentReleaseID),
              validRevision(value.revision),
              isSlug(value.slug, maximum: 120),
              value.approvedTags.count <= 20,
              value.approvedTags.map(\.slug) == value.approvedTags.map(\.slug).sorted(),
              value.poster.role == "poster",
              value.preview.role == "preview"
        else {
            throw CatalogMappingError.invalidResponse
        }
        try requireBoundedText(value.title, maximum: 120)
        return CatalogWallpaperSummary(
            id: value.id,
            slug: value.slug,
            title: value.title,
            creator: try creator(value.creator),
            contentRating: rating(value.contentRating),
            primaryCategory: try taxonomy(value.primaryCategory),
            approvedTags: try value.approvedTags.map(taxonomy),
            poster: try artifact(value.poster),
            preview: try artifact(value.preview),
            currentReleaseID: value.currentReleaseID,
            revision: value.revision,
            publishedAt: try exactTimestamp(value.publishedAt),
            verifiedInstallCount: value.verifiedInstallCount,
            favoriteCount: value.favoriteCount,
            saveCount: value.saveCount
        )
    }

    private func creator(_ value: CreatorSummaryDTO) throws -> CatalogCreatorSummary {
        guard isUUID(value.id),
              isCreatorHandle(value.handle),
              value.avatarURL.map(remoteURLPolicy.allowsMedia) ?? true
        else {
            throw CatalogMappingError.invalidResponse
        }
        try requireBoundedText(value.displayName, maximum: 80)
        let verification: CatalogCreatorVerification = switch value.verificationStatus {
        case "unverified": .unverified
        case "verified": .verified
        case "featured": .featured
        default: .unknown(value.verificationStatus)
        }
        return CatalogCreatorSummary(
            id: value.id,
            handle: value.handle,
            displayName: value.displayName,
            avatarURL: value.avatarURL,
            verification: verification
        )
    }

    private func taxonomy(_ value: TaxonomySummaryDTO) throws -> CatalogTaxonomySummary {
        guard isUUID(value.id), isSlug(value.slug, maximum: 80) else {
            throw CatalogMappingError.invalidResponse
        }
        try requireBoundedText(value.name, maximum: 80)
        return CatalogTaxonomySummary(id: value.id, name: value.name, slug: value.slug)
    }

    private func artifact(_ value: ArtifactSummaryDTO) throws -> CatalogArtifact {
        guard let role = CatalogArtifactRole(rawValue: value.role) else {
            throw CatalogMappingError.invalidResponse
        }
        guard remoteURLPolicy.allowsMedia(value.url) else {
            throw CatalogMappingError.invalidResponse
        }
        return try CatalogArtifact(
            role: role,
            url: value.url,
            sha256: value.sha256,
            byteCount: value.byteCount,
            mediaType: value.mediaType,
            width: value.width,
            height: value.height,
            durationMilliseconds: value.durationMilliseconds
        )
    }

    private func rating(_ value: String) -> CatalogContentRating {
        switch value {
        case "everyone": .everyone
        case "teen": .teen
        case "mature": .mature
        default: .unknown(value)
        }
    }

    private func cursor(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            throw CatalogMappingError.invalidResponse
        }
        return value
    }

    private func exactTimestamp(_ value: String) throws -> Date {
        guard (20...32).contains(value.utf8.count),
              value.hasSuffix("Z") || value.hasSuffix("+00:00")
        else {
            throw CatalogMappingError.invalidResponse
        }

        let formatOptions: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds]
        ]
        for options in formatOptions {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: value) {
                return date
            }
        }
        throw CatalogMappingError.invalidResponse
    }

    private func requireBoundedText(
        _ value: String,
        maximum: Int,
        allowBlank: Bool = false
    ) throws {
        guard Array(value.utf8) == Array(value.precomposedStringWithCanonicalMapping.utf8),
              value.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }),
              allowBlank || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CatalogMappingError.invalidResponse
        }
    }

    private func validExternalURL(_ value: URL?) -> Bool {
        guard let value else { return true }
        return CatalogRemoteURLPolicy.isCanonicalHTTPS(value)
    }

    private func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private func isSlug(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    private func isCreatorHandle(_ value: String) -> Bool {
        guard (3...32).contains(value.utf8.count), let first = value.utf8.first else {
            return false
        }
        guard (48...57).contains(first) || (97...122).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }

    private func validRevision(_ value: UInt64) -> Bool {
        value <= 9_007_199_254_740_991
    }

    private func isLicenseCode(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

public struct CatalogRemoteError: Error, Sendable, Equatable {
    public let code: String
    public let safeMessage: String?
    public let retryable: Bool

    public init(code: String, safeMessage: String?, retryable: Bool) {
        self.code = code
        self.safeMessage = safeMessage
        self.retryable = retryable
    }
}
