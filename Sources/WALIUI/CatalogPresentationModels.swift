import Foundation
import Observation

public struct WALICatalogCardPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let creator: String
    public let category: String
    public let tags: [String]
    /// Decoder-ready app-owned files. Remote catalog URLs are never valid here.
    public let posterURL: URL?
    public let previewURL: URL?
    public let verifiedInstallCount: UInt64
    public var favoriteCount: UInt64
    public var saveCount: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32

    public init(
        id: String,
        title: String,
        creator: String,
        category: String,
        tags: [String],
        posterURL: URL?,
        previewURL: URL?,
        verifiedInstallCount: UInt64,
        favoriteCount: UInt64,
        saveCount: UInt64,
        pixelWidth: UInt32 = 1920,
        pixelHeight: UInt32 = 1200
    ) {
        self.id = id
        self.title = title
        self.creator = creator
        self.category = category
        self.tags = tags
        self.posterURL = posterURL?.isFileURL == true ? posterURL : nil
        self.previewURL = previewURL?.isFileURL == true ? previewURL : nil
        self.verifiedInstallCount = verifiedInstallCount
        self.favoriteCount = favoriteCount
        self.saveCount = saveCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum WALICatalogSectionLayout: Equatable, Sendable {
    case hero
    case row
}

public struct WALICatalogSectionPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let layout: WALICatalogSectionLayout
    public let cards: [WALICatalogCardPresentation]

    public init(
        id: String,
        title: String,
        layout: WALICatalogSectionLayout = .row,
        cards: [WALICatalogCardPresentation]
    ) {
        self.id = id
        self.title = title
        self.layout = layout
        self.cards = cards
    }
}

public struct WALICatalogDetailPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let creator: String
    public let creatorHandle: String
    public let description: String
    /// Decoder-ready app-owned files. Remote catalog URLs are never valid here.
    public let previewURL: URL?
    public let posterURL: URL?
    public let attribution: String?
    public let rightsHolder: String
    public let sourceURL: URL?
    public let licenseName: String
    public let licenseTermsURL: URL
    public let dimensions: String
    public let duration: String
    public let framesPerSecond: Double
    public let verifiedInstallCount: UInt64
    public var favoriteCount: UInt64
    public var saveCount: UInt64
    public let category: String
    public let tags: [String]
    public var isFavorite: Bool
    public var favoriteRevision: UInt64
    public var isSaved: Bool
    public var savedRevision: UInt64
    public let currentReleaseID: String
    public let wallpaperRevision: UInt64
    public let related: [WALICatalogCardPresentation]

    public init(
        id: String,
        title: String,
        creator: String,
        creatorHandle: String,
        description: String,
        previewURL: URL?,
        posterURL: URL?,
        attribution: String?,
        rightsHolder: String,
        sourceURL: URL?,
        licenseName: String,
        licenseTermsURL: URL,
        dimensions: String,
        duration: String,
        framesPerSecond: Double,
        verifiedInstallCount: UInt64,
        favoriteCount: UInt64,
        saveCount: UInt64,
        category: String,
        tags: [String],
        isFavorite: Bool,
        favoriteRevision: UInt64,
        isSaved: Bool,
        savedRevision: UInt64,
        currentReleaseID: String,
        wallpaperRevision: UInt64,
        related: [WALICatalogCardPresentation]
    ) {
        self.id = id
        self.title = title
        self.creator = creator
        self.creatorHandle = creatorHandle
        self.description = description
        self.previewURL = previewURL?.isFileURL == true ? previewURL : nil
        self.posterURL = posterURL?.isFileURL == true ? posterURL : nil
        self.attribution = attribution
        self.rightsHolder = rightsHolder
        self.sourceURL = sourceURL
        self.licenseName = licenseName
        self.licenseTermsURL = licenseTermsURL
        self.dimensions = dimensions
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.verifiedInstallCount = verifiedInstallCount
        self.favoriteCount = favoriteCount
        self.saveCount = saveCount
        self.category = category
        self.tags = tags
        self.isFavorite = isFavorite
        self.favoriteRevision = favoriteRevision
        self.isSaved = isSaved
        self.savedRevision = savedRevision
        self.currentReleaseID = currentReleaseID
        self.wallpaperRevision = wallpaperRevision
        self.related = related
    }
}

public enum WALIMarketplaceLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case offline
    case failed(message: String)
}

@MainActor
@Observable
public final class WALIMarketplaceModel {
    public var homeSections: [WALICatalogSectionPresentation]
    public var browseItems: [WALICatalogCardPresentation]
    public var searchItems: [WALICatalogCardPresentation]
    public var browseNextCursor: String?
    public var searchNextCursor: String?
    public var selectedDetail: WALICatalogDetailPresentation?
    public var homeState: WALIMarketplaceLoadState
    public var browseState: WALIMarketplaceLoadState
    public var detailState: WALIMarketplaceLoadState
    public var accountState: WALIAccountPresentation
    public var accountProfile: WALIAccountProfilePresentation?
    public var accountProfileState: WALIAccountPrivacyLoadState
    public var accountExportState: WALIAccountExportPresentation
    public var accountDeletionState: WALIAccountDeletionPresentation
    public var actionState: WALIMarketplaceActionState
    public var reportState: WALIMarketplaceActionState

    public init(
        homeSections: [WALICatalogSectionPresentation] = [],
        browseItems: [WALICatalogCardPresentation] = [],
        searchItems: [WALICatalogCardPresentation] = [],
        browseNextCursor: String? = nil,
        searchNextCursor: String? = nil,
        selectedDetail: WALICatalogDetailPresentation? = nil,
        homeState: WALIMarketplaceLoadState = .idle,
        browseState: WALIMarketplaceLoadState = .idle,
        detailState: WALIMarketplaceLoadState = .idle,
        accountState: WALIAccountPresentation = .signedOut,
        accountProfile: WALIAccountProfilePresentation? = nil,
        accountProfileState: WALIAccountPrivacyLoadState = .idle,
        accountExportState: WALIAccountExportPresentation = .idle,
        accountDeletionState: WALIAccountDeletionPresentation = .idle,
        actionState: WALIMarketplaceActionState = .idle,
        reportState: WALIMarketplaceActionState = .idle
    ) {
        self.homeSections = homeSections
        self.browseItems = browseItems
        self.searchItems = searchItems
        self.browseNextCursor = browseNextCursor
        self.searchNextCursor = searchNextCursor
        self.selectedDetail = selectedDetail
        self.homeState = homeState
        self.browseState = browseState
        self.detailState = detailState
        self.accountState = accountState
        self.accountProfile = accountProfile
        self.accountProfileState = accountProfileState
        self.accountExportState = accountExportState
        self.accountDeletionState = accountDeletionState
        self.actionState = actionState
        self.reportState = reportState
    }
}

public enum WALIMarketplaceActionState: Equatable, Sendable {
    case idle
    case working
    case succeeded(message: String)
    case failed(message: String)
}

public enum WALIAccountPresentation: Equatable, Sendable {
    case signedOut
    case signedIn(userID: String)
}

public struct WALIAccountProfilePresentation: Equatable, Sendable {
    public let userID: String
    public let handle: String
    public let displayName: String
    public let status: String
    public let revision: UInt64

    public init(userID: String, handle: String, displayName: String, status: String, revision: UInt64) {
        self.userID = userID
        self.handle = handle
        self.displayName = displayName
        self.status = status
        self.revision = revision
    }
}

public enum WALIAccountPrivacyLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(message: String)
}

public enum WALIAccountExportPresentation: Equatable, Sendable {
    case idle
    case working
    case queued
    case processing
    case ready(expiresAt: Date)
    case saved(fileName: String)
    case failed(message: String)
}

public enum WALIAccountDeletionPresentation: Equatable, Sendable {
    case idle
    case working
    case mfaSetup(secret: String, uri: String, errorMessage: String?)
    case mfaChallenge(errorMessage: String?)
    case pending(status: String, identityStatus: String, held: Bool)
    case completed(completedAt: Date)
    case failed(message: String)
}
