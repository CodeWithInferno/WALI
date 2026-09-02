import Foundation
import WALICatalog

public enum CatalogContentRating: Sendable, Hashable {
    case everyone
    case teen
    case mature
    case unknown(String)
}

public enum CatalogCreatorVerification: Sendable, Hashable {
    case unverified
    case verified
    case featured
    case unknown(String)
}

public struct CatalogTaxonomySummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String

    public init(id: String, name: String, slug: String) {
        self.id = id
        self.name = name
        self.slug = slug
    }
}

public struct CatalogCreatorSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?
    public let verification: CatalogCreatorVerification

    public init(
        id: String,
        handle: String,
        displayName: String,
        avatarURL: URL?,
        verification: CatalogCreatorVerification
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.verification = verification
    }
}

public struct CatalogWallpaperSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let creator: CatalogCreatorSummary
    public let contentRating: CatalogContentRating
    public let primaryCategory: CatalogTaxonomySummary
    public let approvedTags: [CatalogTaxonomySummary]
    public let poster: CatalogArtifact
    public let preview: CatalogArtifact
    public let currentReleaseID: String
    public let revision: UInt64
    public let publishedAt: Date
    public let verifiedInstallCount: UInt64
    public let favoriteCount: UInt64
    public let saveCount: UInt64

    public init(
        id: String,
        slug: String,
        title: String,
        creator: CatalogCreatorSummary,
        contentRating: CatalogContentRating,
        primaryCategory: CatalogTaxonomySummary,
        approvedTags: [CatalogTaxonomySummary],
        poster: CatalogArtifact,
        preview: CatalogArtifact,
        currentReleaseID: String,
        revision: UInt64,
        publishedAt: Date,
        verifiedInstallCount: UInt64,
        favoriteCount: UInt64,
        saveCount: UInt64
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.creator = creator
        self.contentRating = contentRating
        self.primaryCategory = primaryCategory
        self.approvedTags = approvedTags
        self.poster = poster
        self.preview = preview
        self.currentReleaseID = currentReleaseID
        self.revision = revision
        self.publishedAt = publishedAt
        self.verifiedInstallCount = verifiedInstallCount
        self.favoriteCount = favoriteCount
        self.saveCount = saveCount
    }
}

public struct CatalogLicense: Sendable, Hashable {
    public let code: String
    public let name: String
    public let termsURL: URL
    public let attributionRequired: Bool
    public let commercialUseAllowed: Bool
    public let derivativesAllowed: Bool
    public let redistributionAllowed: Bool
    public let termsRevision: UInt32

    public init(
        code: String,
        name: String,
        termsURL: URL,
        attributionRequired: Bool,
        commercialUseAllowed: Bool,
        derivativesAllowed: Bool,
        redistributionAllowed: Bool,
        termsRevision: UInt32
    ) {
        self.code = code
        self.name = name
        self.termsURL = termsURL
        self.attributionRequired = attributionRequired
        self.commercialUseAllowed = commercialUseAllowed
        self.derivativesAllowed = derivativesAllowed
        self.redistributionAllowed = redistributionAllowed
        self.termsRevision = termsRevision
    }
}

public struct CatalogWallpaperDetail: Sendable, Hashable, Identifiable {
    public let summary: CatalogWallpaperSummary
    public let description: String
    public let edition: UInt64
    public let rightsHolder: String
    public let attributionText: String?
    public let sourceURL: URL?
    public let license: CatalogLicense
    public let durationMilliseconds: UInt64
    public let width: UInt32
    public let height: UInt32
    public let frameRateNumerator: UInt32
    public let frameRateDenominator: UInt32
    public let related: [CatalogWallpaperSummary]
    public let isFavorite: Bool
    public let favoriteRevision: UInt64
    public let isSaved: Bool
    public let savedRevision: UInt64

    public var id: String { summary.id }
    public var framesPerSecond: Double {
        Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    public init(
        summary: CatalogWallpaperSummary,
        description: String,
        edition: UInt64,
        rightsHolder: String,
        attributionText: String?,
        sourceURL: URL?,
        license: CatalogLicense,
        durationMilliseconds: UInt64,
        width: UInt32,
        height: UInt32,
        frameRateNumerator: UInt32,
        frameRateDenominator: UInt32,
        related: [CatalogWallpaperSummary],
        isFavorite: Bool,
        favoriteRevision: UInt64,
        isSaved: Bool,
        savedRevision: UInt64
    ) {
        self.summary = summary
        self.description = description
        self.edition = edition
        self.rightsHolder = rightsHolder
        self.attributionText = attributionText
        self.sourceURL = sourceURL
        self.license = license
        self.durationMilliseconds = durationMilliseconds
        self.width = width
        self.height = height
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.related = related
        self.isFavorite = isFavorite
        self.favoriteRevision = favoriteRevision
        self.isSaved = isSaved
        self.savedRevision = savedRevision
    }
}

public struct CatalogPage: Sendable, Hashable {
    public let items: [CatalogWallpaperSummary]
    public let nextCursor: String?

    public init(items: [CatalogWallpaperSummary], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct CatalogHomeSection: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case editorial, trending, new, forYou, category, unknown(String)
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let cursor: String?
    public let items: [CatalogWallpaperSummary]

    public init(
        id: String,
        title: String,
        kind: Kind,
        cursor: String?,
        items: [CatalogWallpaperSummary]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.cursor = cursor
        self.items = items
    }
}

public struct CatalogHome: Sendable, Hashable {
    public let sections: [CatalogHomeSection]

    public init(sections: [CatalogHomeSection]) {
        self.sections = sections
    }
}

public struct CatalogRankingExplanation: Sendable, Hashable {
    public let formulaRevision: String
    public let modelRevision: String?

    public init(formulaRevision: String, modelRevision: String?) {
        self.formulaRevision = formulaRevision
        self.modelRevision = modelRevision
    }
}

public struct CatalogSearchPage: Sendable, Hashable {
    public let page: CatalogPage
    public let rankingExplanation: CatalogRankingExplanation

    public init(page: CatalogPage, rankingExplanation: CatalogRankingExplanation) {
        self.page = page
        self.rankingExplanation = rankingExplanation
    }
}

struct TaxonomySummaryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let slug: String
}

struct CreatorSummaryDTO: Decodable, Sendable {
    let id: String
    let handle: String
    let displayName: String
    let avatarURL: URL?
    let verificationStatus: String

    enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case verificationStatus = "verification_status"
    }
}

struct ArtifactSummaryDTO: Decodable, Sendable {
    let role: String
    let url: URL
    let sha256: String
    let byteCount: UInt64
    let mediaType: String
    let width: UInt32
    let height: UInt32
    let durationMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case role, url, sha256, width, height
        case byteCount = "byte_count"
        case mediaType = "media_type"
        case durationMilliseconds = "duration_ms"
    }
}

struct WallpaperSummaryDTO: Decodable, Sendable {
    let id: String
    let slug: String
    let title: String
    let creator: CreatorSummaryDTO
    let contentRating: String
    let primaryCategory: TaxonomySummaryDTO
    let approvedTags: [TaxonomySummaryDTO]
    let poster: ArtifactSummaryDTO
    let preview: ArtifactSummaryDTO
    let currentReleaseID: String
    let revision: UInt64
    let publishedAt: String
    let verifiedInstallCount: UInt64
    let favoriteCount: UInt64
    let saveCount: UInt64

    enum CodingKeys: String, CodingKey {
        case id, slug, title, creator, poster, preview, revision
        case contentRating = "content_rating"
        case primaryCategory = "primary_category"
        case approvedTags = "approved_tags"
        case currentReleaseID = "current_release_id"
        case publishedAt = "published_at"
        case verifiedInstallCount = "verified_install_count"
        case favoriteCount = "favorite_count"
        case saveCount = "save_count"
    }
}

struct LicenseDTO: Decodable, Sendable {
    let code: String
    let name: String
    let termsURL: URL
    let attributionRequired: Bool
    let commercialUseAllowed: Bool
    let derivativesAllowed: Bool
    let redistributionAllowed: Bool
    let termsRevision: UInt32

    enum CodingKeys: String, CodingKey {
        case code, name
        case termsURL = "terms_url"
        case attributionRequired = "attribution_required"
        case commercialUseAllowed = "commercial_use_allowed"
        case derivativesAllowed = "derivatives_allowed"
        case redistributionAllowed = "redistribution_allowed"
        case termsRevision = "terms_revision"
    }
}

struct CatalogPageDTO: Decodable, Sendable {
    let items: [WallpaperSummaryDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct HomeSectionDTO: Decodable, Sendable {
    let id: String
    let title: String
    let kind: String
    let cursor: String?
    let items: [WallpaperSummaryDTO]
}

struct CatalogHomeDTO: Decodable, Sendable {
    let sections: [HomeSectionDTO]
}

struct RankingExplanationDTO: Decodable, Sendable {
    let formulaRevision: String
    let modelRevision: String?

    enum CodingKeys: String, CodingKey {
        case formulaRevision = "formula_revision"
        case modelRevision = "model_revision"
    }
}

struct CatalogSearchPageDTO: Decodable, Sendable {
    let items: [WallpaperSummaryDTO]
    let nextCursor: String?
    let rankingExplanation: RankingExplanationDTO

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case rankingExplanation = "ranking_explanation"
    }
}

struct WallpaperDetailDTO: Decodable, Sendable {
    let wallpaper: WallpaperSummaryDTO
    let description: String
    let edition: UInt64
    let rightsHolder: String
    let attributionText: String?
    let sourceURL: URL?
    let license: LicenseDTO
    let durationMilliseconds: UInt64
    let width: UInt32
    let height: UInt32
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let related: [WallpaperSummaryDTO]
    let isFavorite: Bool
    let favoriteRevision: UInt64
    let isSaved: Bool
    let savedRevision: UInt64

    enum CodingKeys: String, CodingKey {
        case wallpaper, description, edition, license, width, height, related
        case rightsHolder = "rights_holder"
        case attributionText = "attribution_text"
        case sourceURL = "source_url"
        case durationMilliseconds = "duration_ms"
        case frameRateNumerator = "frame_rate_numerator"
        case frameRateDenominator = "frame_rate_denominator"
        case isFavorite = "is_favorite"
        case favoriteRevision = "favorite_revision"
        case isSaved = "is_saved"
        case savedRevision = "saved_revision"
    }
}

struct CatalogFunctionEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let apiVersion: String
    let requestID: String
    let data: Payload?
    let error: CatalogFunctionErrorDTO?

    enum CodingKeys: String, CodingKey {
        case data, error
        case apiVersion = "api_version"
        case requestID = "request_id"
    }
}

struct CatalogFunctionErrorDTO: Decodable, Sendable {
    let code: String
    let message: String?
    let retryable: Bool
}
