import AppKit
import Foundation
import Observation
import OSLog
import WALICatalogRuntime
import WALIUI

private actor CreatorRequestTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var wasCancelledBeforeStarting = false

    func run(
        duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            guard !wasCancelledBeforeStarting else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            operationTask = Task {
                do {
                    resolve(.success(try await operation()))
                } catch {
                    resolve(.failure(error))
                }
            }
            timeoutTask = Task {
                do {
                    try await Task.sleep(for: duration)
                    resolve(.failure(CatalogRemoteError(
                        code: "request_timed_out",
                        safeMessage: nil,
                        retryable: true
                    )))
                } catch is CancellationError {
                    return
                } catch {
                    resolve(.failure(error))
                }
            }
        }
    }

    func cancel() {
        guard continuation != nil else {
            wasCancelledBeforeStarting = true
            return
        }
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

public enum MarketplaceCreatorAccessState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case acceptingTerms
    case failed
}

enum MarketplaceCreatorUnavailableReason: Sendable, Equatable {
    case signedOut
    case loading
    case failed
    case notConfigured
}

@MainActor
@Observable
public final class MarketplaceCreatorContext {
    public private(set) var state: MarketplaceCreatorAccessState = .idle
    public private(set) var lastFailureCode: String?
    public private(set) var metadata: CreatorMetadata?
    public private(set) var moderationMetadata: ModerationMetadata?
    public let studioModel: CreatorStudioModel?
    public let uploadCoordinator: CreatorUploadCoordinator?
    public let moderationModel: CreatorModerationModel?

    init(
        creatorGateway: (any CreatorStudioGateway)?,
        uploadTransport: (any CreatorResumableUploadTransport)?,
        moderationGateway: (any ModerationGateway)?,
        presentationMediaCache: (any CatalogPresentationMediaCaching)?
    ) {
        let restricted = CreatorAuthorizationSnapshot(
            subjectID: "",
            accountIsActive: false,
            sessionExpiresAt: .distantPast,
            creatorGrantRevision: nil,
            acceptedCreatorTermsVersion: nil,
            currentCreatorTermsVersion: "",
            moderatorGrantRevision: nil,
            assuranceLevel: .aal1
        )
        if let creatorGateway {
            studioModel = CreatorStudioModel(gateway: creatorGateway, authorization: restricted)
            if let uploadTransport {
                uploadCoordinator = CreatorUploadCoordinator(
                    gateway: creatorGateway,
                    transport: uploadTransport
                )
            } else {
                uploadCoordinator = nil
            }
        } else {
            studioModel = nil
            uploadCoordinator = nil
        }
        if let moderationGateway {
            moderationModel = CreatorModerationModel(
                gateway: moderationGateway,
                authorization: restricted,
                presentationMediaCache: presentationMediaCache
            )
        } else {
            moderationModel = nil
        }
    }

    func beginLoading() {
        state = .loading
    }

    func beginAcceptingTerms() {
        lastFailureCode = nil
        state = .acceptingTerms
    }

    public var canShowModeratorTools: Bool {
        moderationMetadata != nil && moderationModel?.canShowReviewQueue == true
    }

    func apply(
        authorization: CreatorAuthorizationSnapshot,
        metadata: CreatorMetadata?,
        moderationMetadata: ModerationMetadata?
    ) {
        self.metadata = metadata
        self.moderationMetadata = moderationMetadata
        studioModel?.updateAuthorization(authorization)
        uploadCoordinator?.updateAuthorization(authorization)
        moderationModel?.updateAuthorization(authorization)
        state = .ready
    }

    func fail(code: String = "temporarily_unavailable") {
        lastFailureCode = code
        state = .failed
    }

    func clear(subjectID: String = "") {
        metadata = nil
        moderationMetadata = nil
        let restricted = CreatorAuthorizationSnapshot(
            subjectID: subjectID,
            accountIsActive: false,
            sessionExpiresAt: .distantPast,
            creatorGrantRevision: nil,
            acceptedCreatorTermsVersion: nil,
            currentCreatorTermsVersion: "",
            moderatorGrantRevision: nil,
            assuranceLevel: .aal1
        )
        studioModel?.updateAuthorization(restricted)
        uploadCoordinator?.updateAuthorization(restricted)
        moderationModel?.updateAuthorization(restricted)
        state = .idle
    }
}

/// Shared foreground session and acknowledgement authority; windows own presentation.
@MainActor
struct MarketplaceForegroundServices {
    let environment: CatalogEnvironment
    let gateway: SupabaseCatalogGateway
    let installAcknowledgementStore: CatalogInstallAcknowledgementStore

    init?(bundle: Bundle) {
        guard let environment = try? CatalogEnvironment.from(bundle: bundle),
              let gateway = try? SupabaseCatalogGateway(environment: environment) else { return nil }
        self.environment = environment
        self.gateway = gateway
        installAcknowledgementStore = CatalogInstallAcknowledgementStore(fileURL: try? CatalogInstallAcknowledgementStore.defaultURL(
            bundleIdentifier: bundle.bundleIdentifier ?? "io.github.codewithinferno.wali.WALI", projectURL: environment.supabaseURL))
    }
}

@MainActor
public final class MarketplaceCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALI",
        category: "Marketplace"
    )

    public let model: WALIMarketplaceModel
    public let discovery = CatalogDiscoveryModel()
    public let isMarketplaceAvailable: Bool
    public let authenticationMethod: CatalogAuthenticationMethod
    let emailSignIn = EmailCodeSignInModel()
    static let unavailableAccountMessage = "Marketplace accounts are unavailable in this build. Your local wallpapers remain available in Library."

    public var canShowCreatorTools: Bool {
        guard isMarketplaceAvailable, case .signedIn = model.accountState else { return false }
        return true
    }

    /// Explains why the route cannot present Studio without its required metadata and adapters.
    var creatorStudioUnavailableReason: MarketplaceCreatorUnavailableReason {
        guard case .signedIn = model.accountState else { return .signedOut }
        switch creatorContext.state {
        case .loading, .acceptingTerms:
            return .loading
        case .failed:
            return .failed
        case .idle, .ready:
            return .notConfigured
        }
    }

    public var canShowModeratorTools: Bool {
        isMarketplaceAvailable && creatorContext.canShowModeratorTools
    }
    public let creatorContext: MarketplaceCreatorContext
    public let creatorGateway: (any CreatorStudioGateway)?
    public let moderatorAccess: ModeratorAccessModel?
    private let gateway: (any CatalogGateway)?
    private let reportGateway: (any CatalogReportGateway)?
    private let accountGateway: (any AccountPrivacyGateway)?
    private let creatorAuthorizationGateway: (any CreatorAuthorizationGateway)?
    private let moderationGateway: (any ModerationGateway)?
    private let authStore: (any CatalogAuthSessionProviding)?
    private let mfaStore: (any AccountMFASessionProviding)?
    private let appleSignIn: AppleSignInCoordinator?
    private let emailAuth: (any CatalogEmailAuthenticating)?
    private let emailNow: @MainActor () -> Date
    private var emailOwnerID: UUID?
    private var emailAttempt: CatalogEmailAuthAttempt?
    private var emailGeneration: UInt64 = 0
    private var emailTask: Task<Void, Never>?
    private var emailCancellationTask: Task<Void, Never>?
    private var pendingEmailFailure: (error: CatalogEmailAuthError, retryPhase: EmailCodeSignInPhase)?
    private var emailIntent: EmailIntent?
    private var acceptsAuthenticationResults = true
    private let installPreparer: CatalogInstallPreparer?
    private let presentationMediaCache: (any CatalogPresentationMediaCaching)?
    private var savedMediaLease = CatalogMediaLease()
    private var homeMediaLease = CatalogMediaLease()
    private var browseMediaLease = CatalogMediaLease()
    private var searchMediaLease = CatalogMediaLease()
    private var detailMediaLease = CatalogMediaLease()
    private let securityStore: CatalogSecurityStateStore?
    private let installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)?
    private let securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)?
    private let creatorRequestTimeout: Duration
    private var homeGeneration: UInt64 = 0
    private var browseGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var taxonomyTask: Task<Void, Never>?
    private var preferencesTask: Task<Void, Never>?
    private var savedTask: Task<Void, Never>?
    private var savedGeneration: UInt64 = 0
    private var pendingPreferenceWrite: (subjectID: String, categories: [String], rating: String, optOut: Bool, revision: UInt64, key: String)?
    let installAcknowledgementStore: CatalogInstallAcknowledgementStore
    private var recordGeneration: UInt64 = 0
    private var recordTask: Task<Void, Never>?
    private var recordRetryRequested = false
    private var homeTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailTargetID: String?
    private var actionTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var selectedInstallMedia: (wallpaperID: String, releaseID: String, revision: UInt64, kind: CatalogMediaKind)?
    private var retryableInstall: (detail: WALICatalogDetailPresentation, kind: CatalogMediaKind)?
    private var reportTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var accountExportPollTask: Task<Void, Never>?
    private var accountDeletionPollTask: Task<Void, Never>?
    private var accountMFATask: Task<Void, Never>?
    private var creatorTask: Task<Void, Never>?
    private var securityTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var sessionExpiryTask: Task<Void, Never>?
    private var deferredAction: DeferredAction?
    private var pendingReport: CatalogReportRequest?
    private var retryableReport: CatalogReportRequest?
    private var accountExportSnapshot: AccountExportSnapshot?
    private var accountDeletionSnapshot: AccountDeletionSnapshot?
    private var accountExportRecoveryID: String?
    private var accountDeletionRecoveryID: String?
    private var accountExportRequestKey: String?
    private var accountDeletionRequestKey: String?
    private var accountMFAFactorID: String?
    private var accountMFAEnrollmentFactorID: String?
    private var pendingAccountDeletionConfirmation: String?
    private var currentBrowseCategory: String?
    private var currentBrowseTags: [String] = []
    private var currentBrowseSort: CatalogBrowseSort = .featured
    private var currentSearchQuery: String?
    private var isLoadingMore = false

    private enum DeferredAction {
        case favorite
        case saved
        case install
        case report
    }

    private struct EmailIntent {
        let action: DeferredAction?
        let wallpaperID: String?
        let releaseID: String?
        let detailGeneration: UInt64
        let report: CatalogReportRequest?
    }

    private struct CreatorAcceptanceResult: Sendable {
        let authorization: CreatorAuthorizationSnapshot
        let metadata: CreatorMetadata?
        let moderationMetadata: ModerationMetadata?
    }

    public init(
        model: WALIMarketplaceModel = WALIMarketplaceModel(),
        isMarketplaceAvailable: Bool = true,
        authenticationMethod: CatalogAuthenticationMethod = .nativeApple,
        gateway: (any CatalogGateway)? = nil,
        reportGateway: (any CatalogReportGateway)? = nil,
        accountGateway: (any AccountPrivacyGateway)? = nil,
        creatorGateway: (any CreatorStudioGateway)? = nil,
        creatorAuthorizationGateway: (any CreatorAuthorizationGateway)? = nil,
        creatorUploadTransport: (any CreatorResumableUploadTransport)? = nil,
        moderationGateway: (any ModerationGateway)? = nil,
        authStore: (any CatalogAuthSessionProviding)? = nil,
        mfaStore: (any AccountMFASessionProviding)? = nil,
        appleSignIn: AppleSignInCoordinator? = nil,
        emailAuth: (any CatalogEmailAuthenticating)? = nil,
        installPreparer: CatalogInstallPreparer? = nil,
        presentationMediaCache: (any CatalogPresentationMediaCaching)? = nil,
        securityStore: CatalogSecurityStateStore? = nil,
        installAcknowledgementStore: CatalogInstallAcknowledgementStore? = nil,
        installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)? = nil,
        securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)? = nil,
        creatorRequestTimeout: Duration = .seconds(15),
        emailNow: (@MainActor () -> Date)? = nil
    ) {
        let isMarketplaceAvailable = isMarketplaceAvailable && authenticationMethod != .disabled
        self.model = model
        self.isMarketplaceAvailable = isMarketplaceAvailable
        self.authenticationMethod = isMarketplaceAvailable ? authenticationMethod : .disabled
        self.gateway = isMarketplaceAvailable ? gateway : nil
        self.reportGateway = isMarketplaceAvailable ? reportGateway : nil
        self.accountGateway = isMarketplaceAvailable ? accountGateway : nil
        self.creatorGateway = isMarketplaceAvailable ? creatorGateway : nil
        self.creatorAuthorizationGateway = isMarketplaceAvailable ? creatorAuthorizationGateway : nil
        self.moderationGateway = isMarketplaceAvailable ? moderationGateway : nil
        creatorContext = MarketplaceCreatorContext(
            creatorGateway: isMarketplaceAvailable ? creatorGateway : nil,
            uploadTransport: isMarketplaceAvailable ? creatorUploadTransport : nil,
            moderationGateway: isMarketplaceAvailable ? moderationGateway : nil,
            presentationMediaCache: isMarketplaceAvailable ? presentationMediaCache : nil
        )
        self.authStore = isMarketplaceAvailable ? authStore : nil
        self.mfaStore = isMarketplaceAvailable ? mfaStore : nil
        moderatorAccess = self.mfaStore.map { ModeratorAccessModel(store: $0) }
        self.appleSignIn = isMarketplaceAvailable ? appleSignIn : nil
        self.emailAuth = isMarketplaceAvailable && authenticationMethod == .emailOTP ? emailAuth : nil
        self.emailNow = emailNow ?? { .now }
        self.installPreparer = isMarketplaceAvailable ? installPreparer : nil
        self.presentationMediaCache = isMarketplaceAvailable ? presentationMediaCache : nil
        self.securityStore = isMarketplaceAvailable ? securityStore : nil
        self.installAcknowledgementStore = installAcknowledgementStore ?? CatalogInstallAcknowledgementStore()
        self.installHandler = isMarketplaceAvailable ? installHandler : nil
        self.securityHandler = isMarketplaceAvailable ? securityHandler : nil
        self.creatorRequestTimeout = creatorRequestTimeout
        moderatorAccess?.onVerified = { [weak self] in
            guard let self, case let .signedIn(subjectID) = model.accountState else { return }
            loadCreatorContext(for: subjectID)
        }
    }

    public static func configured(
        bundle: Bundle = .main,
        installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)? = nil,
        securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)? = nil
    ) -> MarketplaceCoordinator {
        configured(
            services: MarketplaceForegroundServices(bundle: bundle),
            bundle: bundle,
            installHandler: installHandler,
            securityHandler: securityHandler
        )
    }

    static func configured(
        services: MarketplaceForegroundServices?,
        bundle: Bundle = .main,
        installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)? = nil,
        securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)? = nil
    ) -> MarketplaceCoordinator {
        guard let services else {
            return MarketplaceCoordinator(isMarketplaceAvailable: false)
        }
        let environment = services.environment
        let gateway = services.gateway
        var uploadHosts = environment.approvedCDNHosts
        if let supabaseHost = environment.supabaseURL.host { uploadHosts.insert(supabaseHost) }
        let uploadTransport = try? URLSessionCreatorUploadTransport(approvedHosts: uploadHosts)
        let authStore = gateway.makeAuthSessionStore()
        let bundleIdentifier = bundle.bundleIdentifier ?? "io.github.codewithinferno.wali.WALI"
        let securityStore = try? CatalogSecurityStateStore(
            environment: environment,
            cacheURL: try CatalogSecurityStateStore.defaultCacheURL(
                bundleIdentifier: bundleIdentifier
            )
        )
        return MarketplaceCoordinator(
            authenticationMethod: environment.authenticationMethod,
            gateway: gateway,
            reportGateway: gateway,
            accountGateway: gateway,
            creatorGateway: gateway,
            creatorAuthorizationGateway: gateway,
            creatorUploadTransport: uploadTransport,
            moderationGateway: gateway,
            authStore: authStore,
            mfaStore: authStore,
            appleSignIn: environment.authenticationMethod == .nativeApple
                ? AppleSignInCoordinator(sessionStore: authStore) : nil,
            emailAuth: environment.authenticationMethod == .emailOTP ? authStore : nil,
            installPreparer: try? CatalogInstallPreparer(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ),
            presentationMediaCache: try? CatalogPresentationMediaCache(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ),
            securityStore: securityStore,
            installAcknowledgementStore: services.installAcknowledgementStore,
            installHandler: installHandler,
            securityHandler: securityHandler
        )
    }

    public func start() {
        acceptsAuthenticationResults = true
        guard isMarketplaceAvailable else {
            model.homeState = .empty
            return
        }
        Self.logger.info("Marketplace lifecycle started")
        loadTaxonomy()
        if model.homeState == .idle { loadHome() }
        observeAccount()
        securityTask?.cancel()
        securityTask = Task { [weak self] in
            _ = try? await self?.refreshCatalogSecurityState()
        }
    }

    public func stop() {
        acceptsAuthenticationResults = false
        detachEmailFlow()
        Self.logger.info("Marketplace lifecycle stopped")
        taxonomyTask?.cancel()
        preferencesTask?.cancel()
        savedTask?.cancel()
        recordTask?.cancel()
        installTask?.cancel()
        moderatorAccess?.cancel()
        authenticationTask?.cancel()
        homeTask?.cancel()
        browseTask?.cancel()
        detailTask?.cancel()
        actionTask?.cancel()
        reportTask?.cancel()
        accountTask?.cancel()
        accountExportPollTask?.cancel()
        accountDeletionPollTask?.cancel()
        accountMFATask?.cancel()
        creatorTask?.cancel()
        securityTask?.cancel()
        sessionTask?.cancel()
        sessionExpiryTask?.cancel()
    }

    public func loadTaxonomy() {
        guard let gateway else { return }
        taxonomyTask?.cancel()
        discovery.taxonomyState = .loading
        taxonomyTask = Task { [weak self] in
            do {
                async let categories = gateway.categories()
                async let tags = gateway.tags()
                let options = try await (categories, tags)
                try Task.checkCancellation()
                self?.discovery.categories = options.0
                self?.discovery.tags = options.1
                self?.discovery.taxonomyState = options.0.isEmpty ? .empty : .ready
            } catch is CancellationError { return }
            catch { self?.discovery.taxonomyState = Self.loadState(for: error) }
        }
    }

    public func loadPreferences() {
        guard let gateway, case let .signedIn(subjectID) = model.accountState else { return }
        preferencesTask?.cancel()
        discovery.preferencesState = .loading
        preferencesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await gateway.catalogPreferences()
                try Task.checkCancellation()
                guard model.accountState == .signedIn(userID: subjectID), value.userID == subjectID else { return }
                discovery.preferences = value
                discovery.preferencesState = .ready
                refreshAfterPublication()
            } catch is CancellationError { return }
            catch {
                guard model.accountState == .signedIn(userID: subjectID) else { return }
                discovery.preferencesState = Self.loadState(for: error)
            }
        }
    }

    public func savePreferences(categoryIDs: [String], ratingCeiling: String, personalizationOptOut: Bool) {
        guard let gateway, case let .signedIn(subjectID) = model.accountState,
              let current = discovery.preferences, current.userID == subjectID,
              discovery.preferencesSaveState != .working,
              categoryIDs.count <= 12, Set(categoryIDs).count == categoryIDs.count,
              Set(categoryIDs).isSubset(of: Set(discovery.categories.map(\.id))) else { return }
        let categories = categoryIDs.sorted()
        let prior = pendingPreferenceWrite
        let write = prior?.subjectID == subjectID && prior?.categories == categories && prior?.rating == ratingCeiling
            && prior?.optOut == personalizationOptOut ? prior! :
            (subjectID, categories, ratingCeiling, personalizationOptOut, current.revision, UUID().uuidString.lowercased())
        pendingPreferenceWrite = write
        discovery.preferencesSaveState = .working
        preferencesTask?.cancel()
        preferencesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await gateway.setCatalogPreferences(categoryIDs: write.1, ratingCeiling: write.2,
                    personalizationOptOut: write.3, expectedRevision: write.4, idempotencyKey: write.5)
                try Task.checkCancellation()
                guard model.accountState == .signedIn(userID: subjectID), updated.userID == subjectID else { return }
                discovery.preferences = updated
                discovery.preferencesSaveState = .succeeded(message: "Discover preferences saved.")
                pendingPreferenceWrite = nil
                refreshAfterPublication()
            } catch is CancellationError { return }
            catch {
                guard model.accountState == .signedIn(userID: subjectID) else { return }
                if let remote = error as? CatalogRemoteError, ["stale_revision", "revision_mismatch"].contains(remote.code) {
                    pendingPreferenceWrite = nil
                    loadPreferences()
                    discovery.preferencesSaveState = .failed(message: "Preferences changed elsewhere. Review them and save again.")
                } else {
                    discovery.preferencesSaveState = .failed(message: "Preferences could not be saved. Try again.")
                }
            }
        }
    }

    public func refreshCatalogSurfaces() {
        loadHome()
        if let query = currentSearchQuery { search(query) }
        else if model.browseState != .idle {
            loadBrowse(category: currentBrowseCategory, tags: currentBrowseTags, sort: currentBrowseSort)
        }
    }

    public func refreshAfterPublication() {
        refreshCatalogSurfaces()
        if discovery.savedState != .idle { loadSavedWallpapers() }
        if let wallpaperID = model.selectedDetail?.id { loadDetail(wallpaperID: wallpaperID) }
    }

    public func loadSavedWallpapers(loadMore: Bool = false) {
        guard let gateway, case let .signedIn(subjectID) = model.accountState else {
            discovery.savedItems = []; discovery.savedState = .empty
            return
        }
        if loadMore && (discovery.isLoadingSavedPage || discovery.savedNextCursor == nil) { return }
        savedTask?.cancel()
        savedGeneration &+= 1
        let generation = savedGeneration
        let cursor = loadMore ? discovery.savedNextCursor : nil
        discovery.savedPageError = nil
        if loadMore { discovery.isLoadingSavedPage = true }
        else { discovery.savedState = .loading; discovery.savedNextCursor = nil }
        savedTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == savedGeneration { discovery.isLoadingSavedPage = false } }
            do {
                let page = try await gateway.savedWallpapers(cursor: cursor)
                try Task.checkCancellation()
                guard generation == savedGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                if !loadMore { savedMediaLease = CatalogMediaLease() }
                let cards = page.items.map { Self.card($0) }
                discovery.savedItems = loadMore ? appendUnique(discovery.savedItems, cards) : cards
                discovery.savedNextCursor = page.nextCursor
                discovery.savedState = discovery.savedItems.isEmpty ? .empty : .ready
                _ = await presentationCards(page.items, retaining: savedMediaLease) { [weak self] card in
                    guard let self, generation == savedGeneration,
                          model.accountState == .signedIn(userID: subjectID) else { return }
                    discovery.savedItems = discovery.savedItems.map { $0.id == card.id ? $0.withMedia(from: card) : $0 }
                }
            } catch is CancellationError { return }
            catch {
                guard generation == savedGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                if loadMore { discovery.savedPageError = "More saved wallpapers could not be loaded." }
                else { discovery.savedState = Self.loadState(for: error) }
            }
        }
    }

    public func retryInstallRecording() {
        guard gateway != nil, case .signedIn = model.accountState else { return }
        guard recordTask == nil else { recordRetryRequested = true; return }
        recordRetryRequested = false
        discovery.isRetryingInstallRecord = true
        recordTask = Task { [weak self] in await self?.recordPendingInstall() }
    }

    private func recordPendingInstall() async {
        guard let gateway, case let .signedIn(subjectID) = model.accountState else { recordTask = nil; return }
        let generation = recordGeneration
        discovery.isRetryingInstallRecord = true
        defer {
            if generation == recordGeneration {
                discovery.isRetryingInstallRecord = false
                recordTask = nil
                if recordRetryRequested && !Task.isCancelled { retryInstallRecording() }
            }
        }
        do {
            let entries = try await installAcknowledgementStore.pending(subjectID: subjectID)
            guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
            discovery.canRetryInstallRecord = !entries.isEmpty
            for pending in entries {
                try Task.checkCancellation()
                guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                let code = await Self.recordInstallWithRetry {
                    try await gateway.recordInstall(receipt: pending.receipt, manifestDigest: pending.manifestDigest,
                        releaseID: pending.releaseID, idempotencyKey: pending.idempotencyKey)
                }
                guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                if let code {
                    if ["install_receipt_expired", "install_receipt_invalid", "install_receipt_consumed", "idempotency_conflict", "manifest_invalid"].contains(code) {
                        try await installAcknowledgementStore.remove(pending)
                        guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                        discovery.installRecordingFailure = "The wallpaper is in your Library. Its download count could not be recorded because the confirmation is no longer valid."
                        discovery.canRetryInstallRecord = false
                        continue
                    }
                    discovery.installRecordingFailure = "The wallpaper is in your Library. Its download count has not been updated yet. Try again when connected."
                    discovery.canRetryInstallRecord = true
                    return
                }
                try await installAcknowledgementStore.remove(pending)
                guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
                discovery.installRecordingFailure = nil
                discovery.canRetryInstallRecord = false
                if model.selectedDetail?.id == pending.wallpaperID { loadDetail(wallpaperID: pending.wallpaperID) }
                refreshCatalogSurfaces()
            }
        } catch is CancellationError { return }
        catch {
            guard generation == recordGeneration, model.accountState == .signedIn(userID: subjectID) else { return }
            discovery.installRecordingFailure = "The wallpaper is in your Library. Download confirmation recovery is unavailable. Try again."
            discovery.canRetryInstallRecord = true
        }
    }

    public func loadHome() {
        homeTask?.cancel()
        homeGeneration &+= 1
        let generation = homeGeneration
        let started = Date()
        model.homeState = .loading
        guard let gateway else {
            model.homeState = .empty
            return
        }
        let ratingCeiling = discovery.preferences?.ratingCeiling ?? "teen"
        homeTask = Task { [weak self] in
            do {
                let home = try await gateway.home(
                    locale: Locale.current.identifier,
                    ratingCeiling: ratingCeiling
                )
                try Task.checkCancellation()
                guard let self, generation == self.homeGeneration else { return }
                self.homeMediaLease = CatalogMediaLease()
                self.model.homeSections = self.presentationSections(home.sections)
                self.model.homeState = self.model.homeSections.isEmpty ? .empty : .ready
                Self.logger.info("Discover metadata ready; durationMs=\(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public)")
                await self.hydrateHome(home.sections, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.homeGeneration else { return }
                self.model.homeState = Self.loadState(for: error)
            }
        }
    }

    public func loadBrowse(
        category: String? = nil,
        tags: [String] = [],
        sort: CatalogBrowseSort = .featured
    ) {
        browseTask?.cancel()
        browseGeneration &+= 1
        let generation = browseGeneration
        let started = Date()
        currentBrowseCategory = category
        currentBrowseTags = tags
        discovery.selectedCategory = category
        discovery.selectedTags = Set(tags)
        currentBrowseSort = sort
        currentSearchQuery = nil
        isLoadingMore = false
        model.browsePageError = nil
        model.browseNextCursor = nil
        model.browseState = .loading
        guard let gateway else {
            model.browseState = .empty
            return
        }
        browseTask = Task { [weak self] in
            do {
                let request = try CatalogBrowseRequest(category: category, tags: tags, sort: sort)
                let page = try await gateway.browse(request)
                try Task.checkCancellation()
                guard let self, generation == self.browseGeneration else { return }
                self.browseMediaLease = CatalogMediaLease()
                self.model.browseItems = page.items.map { Self.card($0) }
                self.model.browseNextCursor = page.nextCursor
                self.model.browseState = page.items.isEmpty ? .empty : .ready
                Self.logger.info("Browse metadata ready; durationMs=\(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public)")
                await self.hydrateBrowse(page.items, generation: generation, searching: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.browseGeneration else { return }
                self.model.browseState = Self.loadState(for: error)
            }
        }
    }

    public func search(_ query: String, category: String? = nil, tags: [String]? = nil, sort: CatalogBrowseSort? = nil) {
        if let sort { currentBrowseSort = sort }
        if tags != nil {
            currentBrowseCategory = category
            currentBrowseTags = tags ?? []
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        browseTask?.cancel()
        isLoadingMore = false
        model.browsePageError = nil
        browseGeneration &+= 1
        let generation = browseGeneration
        guard !query.isEmpty else {
            currentSearchQuery = nil
            model.searchItems = []
            model.searchNextCursor = nil
            loadBrowse(category: currentBrowseCategory, tags: currentBrowseTags, sort: currentBrowseSort)
            return
        }
        currentSearchQuery = query
        model.searchNextCursor = nil
        model.browseState = .loading
        guard let gateway else {
            model.browseState = .empty
            return
        }
        browseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let response = try await gateway.search(CatalogSearchRequest(query: query, category: self?.currentBrowseCategory,
                    tags: self?.currentBrowseTags ?? [], ratingCeiling: self?.discovery.preferences?.ratingCeiling ?? "teen", sort: self?.currentBrowseSort))
                try Task.checkCancellation()
                guard let self, generation == self.browseGeneration else { return }
                self.searchMediaLease = CatalogMediaLease()
                self.model.searchItems = response.page.items.map { Self.card($0) }
                self.model.searchNextCursor = response.page.nextCursor
                self.model.browseState = response.page.items.isEmpty ? .empty : .ready
                await self.hydrateBrowse(response.page.items, generation: generation, searching: true)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.browseGeneration else { return }
                self.model.browseState = Self.loadState(for: error)
            }
        }
    }

    public func loadNextBrowsePage() {
        guard !isLoadingMore, model.browseState == .ready else { return }
        let searchQuery = currentSearchQuery
        let cursor = searchQuery == nil ? model.browseNextCursor : model.searchNextCursor
        guard let cursor, let gateway else { return }

        isLoadingMore = true
        model.browsePageError = nil
        browseGeneration &+= 1
        let generation = browseGeneration
        browseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == browseGeneration {
                    browseTask = nil
                    isLoadingMore = false
                }
            }
            do {
                if let searchQuery {
                    let request = try CatalogSearchRequest(query: searchQuery, category: currentBrowseCategory, tags: currentBrowseTags,
                        ratingCeiling: discovery.preferences?.ratingCeiling ?? "teen", sort: currentBrowseSort, cursor: cursor)
                    let response = try await gateway.search(request)
                    try Task.checkCancellation()
                    guard generation == browseGeneration else { return }
                    model.searchItems = appendUnique(model.searchItems, response.page.items.map { Self.card($0) })
                    model.searchNextCursor = response.page.nextCursor
                    await hydrateBrowse(response.page.items, generation: generation, searching: true)
                } else {
                    let request = try CatalogBrowseRequest(
                        category: currentBrowseCategory,
                        tags: currentBrowseTags,
                        sort: currentBrowseSort,
                        cursor: cursor
                    )
                    let response = try await gateway.browse(request)
                    try Task.checkCancellation()
                    guard generation == browseGeneration else { return }
                    model.browseItems = appendUnique(model.browseItems, response.items.map { Self.card($0) })
                    model.browseNextCursor = response.nextCursor
                    await hydrateBrowse(response.items, generation: generation, searching: false)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == browseGeneration else { return }
                model.browsePageError = "More wallpapers couldn’t be loaded."
            }
        }
    }

    public func loadDetail(wallpaperID: String) {
        detailTask?.cancel()
        detailTargetID = wallpaperID
        detailGeneration &+= 1
        let generation = detailGeneration
        Self.logger.info("Wallpaper detail requested; generation=\(generation, privacy: .public)")
        model.selectedDetail = nil
        selectedInstallMedia = nil
        detailMediaLease = CatalogMediaLease()
        model.detailState = .loading
        guard let gateway else {
            model.detailState = .empty
            return
        }
        detailTask = Task { [weak self] in
            do {
                let detail = try await gateway.detail(wallpaperID: wallpaperID)
                try Task.checkCancellation()
                guard let self, generation == self.detailGeneration else { return }
                self.selectedInstallMedia = (detail.id, detail.summary.currentReleaseID, detail.summary.revision, detail.media.kind)
                self.model.selectedDetail = self.presentationDetail(detail)
                self.model.detailState = .ready
                Self.logger.info("Wallpaper metadata ready; generation=\(generation, privacy: .public)")
                await self.hydrateDetail(detail, generation: generation)
            } catch is CancellationError {
                Self.logger.info("Wallpaper detail cancelled; generation=\(generation, privacy: .public)")
                return
            } catch {
                guard let self, generation == self.detailGeneration else { return }
                self.model.detailState = Self.loadState(for: error)
            }
        }
    }

    public func cancelDetail(wallpaperID: String) {
        guard detailTargetID == wallpaperID else { return }
        Self.logger.info("Wallpaper detail view left; generation=\(self.detailGeneration, privacy: .public)")
        detailTask?.cancel()
        detailTargetID = nil
        detailGeneration &+= 1
    }

    public func signIn() {
        signIn(resuming: nil)
    }

    private func signIn(resuming action: DeferredAction?) {
        guard isMarketplaceAvailable else {
            deferredAction = nil
            pendingReport = nil
            model.authenticationState = .failed(message: Self.unavailableAccountMessage)
            if case .report = action {
                model.reportState = .failed(message: Self.unavailableAccountMessage)
            } else if action != nil {
                model.actionState = .failed(message: Self.unavailableAccountMessage)
            }
            return
        }
        guard acceptsAuthenticationResults, model.authenticationState != .working else { return }
        if authenticationMethod == .emailOTP {
            guard emailAuth != nil else {
                model.authenticationState = .failed(message: "Email sign-in is unavailable. Please try again later.")
                pendingReport = nil
                return
            }
            emailGeneration &+= 1
            emailOwnerID = UUID()
            emailAttempt = nil
            emailIntent = EmailIntent(
                action: action,
                wallpaperID: model.selectedDetail?.id,
                releaseID: model.selectedDetail?.currentReleaseID,
                detailGeneration: detailGeneration,
                report: pendingReport
            )
            pendingReport = nil
            deferredAction = nil
            emailSignIn.clear()
            emailSignIn.isPresented = true
            model.authenticationState = .working
            return
        }
        guard let appleSignIn,
              let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        else {
            deferredAction = nil
            pendingReport = nil
            model.authenticationState = .failed(message: "Sign in with Apple is unavailable. Reopen WALI and try again.")
            if case .report = action {
                model.reportState = .failed(message: "Sign in is unavailable in this build.")
            } else {
                model.actionState = .failed(message: "Sign in is unavailable in this build.")
            }
            return
        }
        deferredAction = action
        model.authenticationState = .working
        if case .report = action {
            model.reportState = .working
        } else if action != nil {
            model.actionState = .working
        }
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await appleSignIn.signIn(presentingFrom: window)
                try Task.checkCancellation()
                model.authenticationState = .idle
                if case .report = action { model.reportState = .idle }
                else if action != nil { model.actionState = .idle }
                model.accountState = .signedIn(userID: state.userID)
                if discovery.preferences?.userID != state.userID { loadPreferences() }
                retryInstallRecording()
                loadAccountProfile(for: state.userID)
                let pending = deferredAction
                deferredAction = nil
                resume(pending)
            } catch is CancellationError {
                model.authenticationState = .idle
                if case .report = action { model.reportState = .idle }
                else if action != nil { model.actionState = .idle }
                deferredAction = nil
                pendingReport = nil
                return
            } catch {
                let message = "Sign in with Apple couldn’t be completed. Try again."
                model.authenticationState = .failed(message: message)
                if case .report = action {
                    model.reportState = .failed(message: message)
                } else if action != nil {
                    model.actionState = .failed(message: message)
                }
                deferredAction = nil
                pendingReport = nil
            }
        }
    }

    func requestEmailCode() {
        guard emailSignIn.isPresented, emailSignIn.phase == .email,
              let emailAuth, let ownerID = emailOwnerID else { return }
        let email = emailSignIn.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= 254 else {
            emailSignIn.message = Self.emailMessage(for: CatalogEmailAuthError.invalidEmail)
            return
        }
        let generation = emailGeneration
        emailSignIn.phase = .requesting
        emailSignIn.message = nil
        emailTask = Task { [weak self] in
            do {
                let attempt = try await emailAuth.beginEmailSignIn(email: email, ownerID: ownerID)
                guard let self, isCurrentEmailFlow(ownerID: ownerID, generation: generation),
                      emailSignIn.phase != .cancelling else { return }
                emailAttempt = attempt
                emailSignIn.email = attempt.email
                emailSignIn.code = ""
                emailSignIn.resendAvailableAt = attempt.resendAvailableAt
                emailSignIn.phase = .code
            } catch {
                self?.handleEmailFailure(error, ownerID: ownerID, generation: generation, retryPhase: .email)
            }
        }
    }

    func resendEmailCode() {
        guard emailSignIn.isPresented, emailSignIn.phase == .code,
              let emailAuth, let ownerID = emailOwnerID, let attempt = emailAttempt else { return }
        guard attempt.resendAvailableAt <= emailNow() else {
            emailSignIn.message = "Please wait before requesting another code."
            return
        }
        let generation = emailGeneration
        emailSignIn.phase = .resending
        emailSignIn.code = ""
        emailSignIn.message = nil
        emailTask = Task { [weak self] in
            do {
                let renewed = try await emailAuth.resendEmailCode(attemptID: attempt.id, ownerID: ownerID)
                guard let self, isCurrentEmailFlow(ownerID: ownerID, generation: generation),
                      emailSignIn.phase != .cancelling else { return }
                emailAttempt = renewed
                emailSignIn.resendAvailableAt = renewed.resendAvailableAt
                emailSignIn.phase = .code
            } catch {
                self?.handleEmailFailure(error, ownerID: ownerID, generation: generation, retryPhase: .code)
            }
        }
    }

    func verifyEmailCode() {
        guard emailSignIn.isPresented, emailSignIn.phase == .code,
              let emailAuth, let authStore, let ownerID = emailOwnerID, let attempt = emailAttempt else { return }
        let code = emailSignIn.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.utf8.count <= 16 else {
            emailSignIn.message = Self.emailMessage(for: CatalogEmailAuthError.invalidCode)
            return
        }
        let generation = emailGeneration
        emailSignIn.phase = .verifying
        emailSignIn.message = nil
        emailSignIn.code = ""
        emailTask = Task { [weak self] in
            do {
                let accepted = try await emailAuth.verifyEmailCode(
                    code: code,
                    attemptID: attempt.id,
                    ownerID: ownerID,
                    onAdmissionCommitted: { [weak self] in
                        await self?.emailAdmissionDidCommit(ownerID: ownerID, generation: generation)
                    }
                )
                // A completed isolated verification alone is not current account authority.
                let current = await authStore.currentState()
                guard let self, isCurrentEmailFlow(ownerID: ownerID, generation: generation) else { return }
                guard let current, current.userID == accepted.userID, current.expiresAt > emailNow() else {
                    handleEmailFailure(CatalogEmailAuthError.superseded, ownerID: ownerID, generation: generation, retryPhase: .email)
                    return
                }
                if case let .signedIn(subjectID) = model.accountState, subjectID != accepted.userID {
                    handleEmailFailure(CatalogEmailAuthError.superseded, ownerID: ownerID, generation: generation, retryPhase: .email)
                    return
                }
                let intent = emailIntent
                finishEmailPresentation()
                applyAccountState(current)
                resumeEmailIntent(intent)
            } catch {
                self?.handleEmailFailure(error, ownerID: ownerID, generation: generation, retryPhase: .code)
            }
        }
    }

    func changeSignInEmail() {
        guard emailSignIn.isPresented, emailSignIn.phase == .code else { return }
        let address = emailSignIn.email
        let intent = emailIntent
        detachEmailFlow()
        emailOwnerID = UUID()
        emailIntent = intent
        emailSignIn.email = address
        emailSignIn.isPresented = true
        model.authenticationState = .working
    }

    func cancelEmailSignIn() {
        guard emailSignIn.isPresented, emailSignIn.canCancel,
              let emailAuth, let ownerID = emailOwnerID else { return }
        let generation = emailGeneration
        let attempt = emailAttempt
        emailSignIn.phase = .cancelling
        emailSignIn.message = nil
        emailSignIn.code = ""
        emailTask?.cancel()
        emailCancellationTask = Task { [weak self] in
            let cancelled: Bool
            if let attempt {
                cancelled = await emailAuth.cancelEmailSignIn(attemptID: attempt.id, ownerID: ownerID)
            } else {
                await emailAuth.detachEmailSignIn(ownerID: ownerID)
                cancelled = true
            }
            guard let self, isCurrentEmailFlow(ownerID: ownerID, generation: generation) else { return }
            if cancelled {
                finishEmailPresentation()
            } else {
                // The service owns this boundary; an already committed login is not cancelled.
                emailSignIn.phase = .completing
                if let pending = pendingEmailFailure {
                    pendingEmailFailure = nil
                    let failure: CatalogEmailAuthError
                    if case .cancelled = pending.error { failure = .admissionFailed }
                    else { failure = pending.error }
                    handleEmailFailure(failure, ownerID: ownerID, generation: generation, retryPhase: pending.retryPhase)
                }
            }
        }
    }

    private func emailAdmissionDidCommit(ownerID: UUID, generation: UInt64) {
        guard isCurrentEmailFlow(ownerID: ownerID, generation: generation) else { return }
        emailSignIn.phase = .completing
        emailSignIn.code = ""
        emailSignIn.message = nil
    }

    private func isCurrentEmailFlow(ownerID: UUID, generation: UInt64) -> Bool {
        acceptsAuthenticationResults && emailSignIn.isPresented
            && emailOwnerID == ownerID && emailGeneration == generation
    }

    private func finishEmailPresentation() {
        emailGeneration &+= 1
        emailOwnerID = nil
        emailAttempt = nil
        emailIntent = nil
        pendingEmailFailure = nil
        emailSignIn.clear()
        model.authenticationState = .idle
    }

    private func detachEmailFlow() {
        let ownerID = emailOwnerID
        emailTask?.cancel()
        emailCancellationTask?.cancel()
        finishEmailPresentation()
        if let ownerID, let emailAuth {
            Task { await emailAuth.detachEmailSignIn(ownerID: ownerID) }
        }
    }

    private func resumeEmailIntent(_ intent: EmailIntent?) {
        guard acceptsAuthenticationResults, let intent, let action = intent.action,
              let wallpaperID = intent.wallpaperID,
              model.selectedDetail?.id == wallpaperID,
              model.selectedDetail?.currentReleaseID == intent.releaseID,
              detailGeneration == intent.detailGeneration else { return }
        if case .report = action {
            guard let report = intent.report, report.wallpaperID == wallpaperID,
                  report.releaseID == intent.releaseID else { return }
            submitReport(report)
        } else {
            resume(action)
        }
    }

    private func handleEmailFailure(
        _ error: Error, ownerID: UUID, generation: UInt64, retryPhase: EmailCodeSignInPhase
    ) {
        guard isCurrentEmailFlow(ownerID: ownerID, generation: generation) else { return }
        if emailSignIn.phase == .cancelling {
            let safeError = (error as? CatalogEmailAuthError) ?? .admissionFailed
            pendingEmailFailure = (safeError, retryPhase)
            switch safeError {
            case .cancelled, .superseded: break
            default: emailSignIn.message = Self.emailMessage(for: safeError)
            }
            return
        }
        if let error = error as? CatalogEmailAuthError {
            switch error {
            case .cancelled:
                finishEmailPresentation()
                return
            case .superseded:
                finishEmailPresentation()
                model.authenticationState = .failed(message: Self.emailMessage(for: error))
                return
            case let .resendTooSoon(retryAt):
                emailSignIn.resendAvailableAt = retryAt
            case .admissionFailed, .expiredAttempt:
                let message = Self.emailMessage(for: error)
                let address = emailSignIn.email
                detachEmailFlow()
                emailOwnerID = UUID()
                emailSignIn.email = address
                emailSignIn.isPresented = true
                emailSignIn.message = message
                model.authenticationState = .working
                return
            default: break
            }
        }
        emailSignIn.phase = retryPhase
        emailSignIn.code = ""
        emailSignIn.message = Self.emailMessage(for: error)
    }

    static func emailMessage(for error: Error) -> String {
        guard let error = error as? CatalogEmailAuthError else {
            return "Sign-in couldn’t be completed. Please try again."
        }
        switch error {
        case .invalidEmail: return "Enter a valid email address."
        case .invalidCode: return "Enter the one-time code from your email."
        case .invalidOrExpiredCode: return "That code is invalid or expired. Check it or request a new code."
        case .rateLimited, .resendTooSoon: return "Please wait before requesting another code."
        case .timedOut: return "The request timed out. Check your connection and try again."
        case .networkUnavailable: return "Check your internet connection and try again."
        case .expiredAttempt: return "This sign-in attempt expired. Request a new code."
        case .attemptInProgress: return "Another sign-in is completing. Please wait and try again."
        case .superseded: return "Your sign-in session changed. Continue with the current account or try again."
        case .admissionFailed: return "Sign-in couldn’t be completed. Request a new code to try again."
        case .unavailable: return "Email sign-in is unavailable. Please try again later."
        case .cancelled: return "Sign-in was cancelled before completion."
        }
    }

    public func signOut() {
        guard isMarketplaceAvailable else {
            model.authenticationState = .failed(message: Self.unavailableAccountMessage)
            return
        }
        guard model.authenticationState != .working || emailSignIn.isPresented else { return }
        guard let authStore else {
            model.authenticationState = .failed(message: "Sign out is unavailable. Reopen WALI and try again.")
            return
        }
        detachEmailFlow()
        model.authenticationState = .working
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authStore.signOut()
                try Task.checkCancellation()
                clearSubjectBoundState()
                model.accountState = .signedOut
                refreshCatalogSurfaces()
                model.authenticationState = .idle
            } catch is CancellationError {
                model.authenticationState = .idle
            } catch {
                model.authenticationState = .failed(message: "Sign out couldn’t be completed. Check your connection and try again.")
            }
        }
    }

    public func refreshAccountPrivacy() {
        guard case let .signedIn(userID) = model.accountState else { return }
        loadAccountProfile(for: userID)
        loadCreatorContext(for: userID)
    }

    public func acceptCreatorTerms() {
        guard case let .signedIn(userID) = model.accountState,
              let creatorAuthorizationGateway
        else { return }
        let version = creatorContext.studioModel?.authorization.currentCreatorTermsVersion
            ?? creatorContext.metadata?.currentCreatorTermsVersion
        guard let version, CreatorTermsDocument.supported(version: version) != nil else { return }
        creatorTask?.cancel()
        creatorContext.beginAcceptingTerms()
        let moderationGateway = self.moderationGateway
        let existingMetadata = creatorContext.metadata
        creatorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await Self.withTimeout(creatorRequestTimeout) {
                    try await creatorAuthorizationGateway.acceptCreatorTerms(
                        expectedSubjectID: userID,
                        version: version,
                        idempotencyKey: UUID().uuidString.lowercased()
                    )
                }
                try Task.checkCancellation()
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == userID
                else { return }
                guard resultAuthorization(authorization, matches: userID, version: version) else {
                    creatorContext.fail(code: "invalid_response")
                    return
                }
                let metadata = (try? await creatorAuthorizationGateway.creatorMetadata())
                    ?? existingMetadata
                guard let metadata,
                      metadata.currentCreatorTermsVersion == version
                else {
                    creatorContext.fail(code: "temporarily_unavailable")
                    return
                }
                let moderationMetadata: ModerationMetadata?
                if authorization.canAccessModeration(), let moderationGateway {
                    moderationMetadata = try? await moderationGateway.moderationMetadata()
                } else {
                    moderationMetadata = nil
                }
                guard model.accountState == .signedIn(userID: userID), !Task.isCancelled else { return }
                creatorContext.apply(
                    authorization: authorization,
                    metadata: metadata,
                    moderationMetadata: moderationMetadata
                )
            } catch is CancellationError {
                return
            } catch {
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == userID
                else { return }
                creatorContext.fail(code: Self.diagnosticCode(for: error))
            }
        }
    }

    private func resultAuthorization(
        _ authorization: CreatorAuthorizationSnapshot,
        matches userID: String,
        version: String
    ) -> Bool {
        authorization.subjectID == userID
            && authorization.currentCreatorTermsVersion == version
            && authorization.acceptedCreatorTermsVersion == version
    }

    public func requestAccountExport() {
        switch model.accountExportState {
        case .working, .queued, .processing: return
        default: break
        }
        guard case .signedIn = model.accountState,
              model.accountProfile != nil,
              let accountGateway
        else {
            model.accountExportState = .failed(message: "Sign in to export your account data.")
            return
        }
        let key = accountExportRequestKey ?? UUID().uuidString.lowercased()
        accountExportRequestKey = key
        accountTask?.cancel()
        model.accountExportState = .working
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await accountGateway.requestAccountExport(idempotencyKey: key)
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile,
                      accountSubjectMatchesCurrentProfile(snapshot.subjectID)
                else { return }
                accountExportRequestKey = nil
                applyAccountExport(snapshot)
                beginAccountExportPollingIfNeeded(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .failed(message: "Your export could not be requested. Try again.")
            }
        }
    }

    public func refreshAccountExport() {
        guard let id = accountExportSnapshot?.id ?? accountExportRecoveryID else { return }
        pollAccountExport(id: id)
    }

    public func chooseAccountExportDestination() {
        guard let snapshot = accountExportSnapshot, snapshot.status == .ready else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "WALI-account-export.json"
        panel.title = "Save WALI Account Export"
        panel.prompt = "Save Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        saveAccountExport(to: destination)
    }

    public func saveAccountExport(to destination: URL) {
        guard let snapshot = accountExportSnapshot, let accountGateway else { return }
        accountTask?.cancel()
        model.accountExportState = .working
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The save panel may remain open longer than the short-lived grant.
                let fresh = try await accountGateway.accountExportStatus(
                    id: snapshot.id,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile(fresh.subjectID) else { return }
                accountExportSnapshot = fresh
                try await accountGateway.saveAccountExport(fresh, to: destination)
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .saved(fileName: destination.lastPathComponent)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .failed(
                    message: "The export could not be saved. Refresh its status and try again."
                )
            }
        }
    }

    public func requestAccountDeletion(confirmation: String) {
        guard case .signedIn = model.accountState,
              let profile = model.accountProfile,
              accountGateway != nil,
              mfaStore != nil
        else {
            model.accountDeletionState = .failed(message: "Account details are unavailable. Refresh and try again.")
            return
        }
        guard confirmation == "DELETE MY WALI" else {
            model.accountDeletionState = .failed(message: "Enter DELETE MY WALI exactly to continue.")
            return
        }
        let key = accountDeletionRequestKey ?? UUID().uuidString.lowercased()
        accountDeletionRequestKey = key
        pendingAccountDeletionConfirmation = confirmation
        prepareAccountDeletionAuthorization(profile: profile, confirmation: confirmation, key: key)
    }

    public func verifyAccountDeletionMFA(code: String) {
        guard code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) }),
              let factorID = accountMFAFactorID,
              let mfaStore,
              let confirmation = pendingAccountDeletionConfirmation,
              let key = accountDeletionRequestKey,
              let profile = model.accountProfile
        else {
            model.accountDeletionState = .failed(message: "Enter the six-digit code from your authenticator app.")
            return
        }
        accountMFATask?.cancel()
        let previousPresentation = model.accountDeletionState
        model.accountDeletionState = .working
        accountMFATask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await mfaStore.verifyTOTP(factorID: factorID, code: code)
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile,
                      case let .signedIn(userID) = model.accountState,
                      status.subjectID == userID,
                      status.isFresh()
                else { return }
                accountMFAEnrollmentFactorID = nil
                submitAccountDeletion(profile: profile, confirmation: confirmation, key: key)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                switch previousPresentation {
                case let .mfaSetup(secret, uri, _):
                    model.accountDeletionState = .mfaSetup(
                        secret: secret,
                        uri: uri,
                        errorMessage: "That code could not be verified. Check the code and try again."
                    )
                default:
                    model.accountDeletionState = .mfaChallenge(
                        errorMessage: "That code could not be verified. Check the code and try again."
                    )
                }
            }
        }
    }

    public func cancelAccountDeletionMFA() {
        accountMFATask?.cancel()
        let enrollmentFactorID = accountMFAEnrollmentFactorID
        accountMFAFactorID = nil
        accountMFAEnrollmentFactorID = nil
        pendingAccountDeletionConfirmation = nil
        accountDeletionRequestKey = nil
        model.accountDeletionState = .idle
        guard let enrollmentFactorID, let mfaStore else { return }
        Task { try? await mfaStore.cancelTOTPEnrollment(factorID: enrollmentFactorID) }
    }

    private func prepareAccountDeletionAuthorization(
        profile: WALIAccountProfilePresentation,
        confirmation: String,
        key: String,
        forceChallenge: Bool = false
    ) {
        guard let mfaStore else {
            model.accountDeletionState = .failed(message: "Two-factor authentication is unavailable in this build.")
            return
        }
        accountMFATask?.cancel()
        model.accountDeletionState = .working
        accountMFATask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await mfaStore.mfaStatus()
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile,
                      case let .signedIn(userID) = model.accountState,
                      status.subjectID == userID
                else { return }
                if !forceChallenge && status.isFresh() {
                    submitAccountDeletion(profile: profile, confirmation: confirmation, key: key)
                    return
                }
                if let factorID = status.verifiedTOTPFactorID {
                    accountMFAFactorID = factorID
                    accountMFAEnrollmentFactorID = nil
                    model.accountDeletionState = .mfaChallenge(errorMessage: nil)
                    return
                }
                let enrollment = try await mfaStore.beginTOTPEnrollment()
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile,
                      enrollment.subjectID == userID
                else {
                    try? await mfaStore.cancelTOTPEnrollment(factorID: enrollment.factorID)
                    return
                }
                accountMFAFactorID = enrollment.factorID
                accountMFAEnrollmentFactorID = enrollment.factorID
                model.accountDeletionState = .mfaSetup(
                    secret: enrollment.secret,
                    uri: enrollment.uri.absoluteString,
                    errorMessage: nil
                )
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountDeletionState = .failed(
                    message: "Two-factor authentication could not be prepared. Try again."
                )
            }
        }
    }

    private func submitAccountDeletion(
        profile: WALIAccountProfilePresentation,
        confirmation: String,
        key: String
    ) {
        guard let accountGateway else { return }
        accountTask?.cancel()
        model.accountDeletionState = .working
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await accountGateway.requestAccountDeletion(
                    expectedProfileRevision: profile.revision,
                    confirmation: confirmation,
                    idempotencyKey: key
                )
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile,
                      accountSubjectMatchesCurrentProfile(snapshot.subjectID)
                else { return }
                accountDeletionRequestKey = nil
                pendingAccountDeletionConfirmation = nil
                accountMFAFactorID = nil
                accountMFAEnrollmentFactorID = nil
                accountDeletionSnapshot = snapshot
                applyAccountDeletion(snapshot)
                beginAccountDeletionPollingIfNeeded(snapshot)
            } catch is CancellationError {
                return
            } catch let remote as CatalogRemoteError where [
                "reauthentication_required",
                "recent_auth_required",
            ].contains(remote.code) {
                guard accountSubjectMatchesCurrentProfile else { return }
                prepareAccountDeletionAuthorization(
                    profile: profile,
                    confirmation: confirmation,
                    key: key,
                    forceChallenge: true
                )
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountDeletionState = .failed(message: "Account deletion could not be requested. Try again.")
            }
        }
    }

    public func refreshAccountDeletion() {
        guard let id = accountDeletionSnapshot?.id ?? accountDeletionRecoveryID else { return }
        pollAccountDeletion(id: id)
    }

    public func installSelectedWallpaper() {
        guard requireAuthentication(for: .install), let detail = model.selectedDetail,
              let media = selectedInstallMedia, media.wallpaperID == detail.id,
              media.releaseID == detail.currentReleaseID, media.revision == detail.wallpaperRevision else { return }
        startCatalogInstall(detail, mediaKind: media.kind)
    }

    public func retryCatalogInstall() {
        guard requireAuthentication(for: .install), let retryableInstall else { return }
        startCatalogInstall(retryableInstall.detail, mediaKind: retryableInstall.kind)
    }

    public func cancelCatalogInstall() {
        guard model.catalogInstall?.canCancel == true else { return }
        installTask?.cancel()
        model.catalogInstall?.phase = .cancelled
    }

    private func startCatalogInstall(_ detail: WALICatalogDetailPresentation, mediaKind: CatalogMediaKind) {
        guard model.catalogInstall?.isActive != true,
              let gateway, let installPreparer, let securityStore, let installHandler,
              case let .signedIn(installSubjectID) = model.accountState else { return }
        let operationID = UUID()
        let idempotencyKey = operationID.uuidString.lowercased()
        retryableInstall = (detail, mediaKind)
        model.catalogInstall = .init(id: operationID, wallpaperID: detail.id,
            releaseID: detail.currentReleaseID, title: detail.title)
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let security = try await refreshCatalogSecurityState(gateway: gateway, store: securityStore)
                try Task.checkCancellation()
                let grant = try await gateway.requestInstall(
                    wallpaperID: detail.id, releaseID: detail.currentReleaseID, mediaKind: mediaKind,
                    expectedWallpaperRevision: detail.wallpaperRevision, idempotencyKey: idempotencyKey)
                try Task.checkCancellation()
                let prepared = try await installPreparer.prepare(grant: grant,
                    expectedWallpaperID: detail.id, expectedReleaseID: detail.currentReleaseID, security: security
                ) { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard let self, var current = model.catalogInstall, current.id == operationID,
                              current.canCancel, expected > 0 else { return }
                        current.receivedBytes = min(received, expected)
                        current.expectedBytes = expected
                        current.phase = received == expected ? .verifying : .downloading
                        model.catalogInstall = current
                    }
                }
                defer { installPreparer.discard(quarantineReference: prepared.quarantineReference) }
                try Task.checkCancellation()
                guard model.catalogInstall?.id == operationID else { return }
                // Once handed to the agent, local publication owns completion.
                // Do not offer a cancel button that cannot cancel that operation.
                model.catalogInstall?.phase = .installing
                try await installHandler(prepared)
                // Persist the acknowledgement immediately after agent success,
                // even if the foreground account changed while the agent worked.
                // It can only be sent when its original subject is signed in.
                do {
                    let acknowledgement = try CatalogInstallAcknowledgement(subjectID: installSubjectID,
                    wallpaperID: detail.id, releaseID: prepared.releaseID, receipt: grant.receipt,
                    manifestDigest: prepared.manifestDigest, idempotencyKey: idempotencyKey, expiresAt: grant.expiresAt)
                    try await installAcknowledgementStore.enqueue(acknowledgement)
                }
                catch {
                    if model.accountState == .signedIn(userID: installSubjectID) {
                        discovery.installRecordingFailure = "The wallpaper is in your Library. Its download confirmation could not be saved for recovery."
                        discovery.canRetryInstallRecord = true
                    }
                }
                try Task.checkCancellation()
                guard model.catalogInstall?.id == operationID else { return }
                model.catalogInstall?.phase = .completed
                retryableInstall = nil
                if model.selectedDetail?.id == detail.id, model.actionState != .working {
                    model.actionState = .succeeded(message: "Added to Library")
                }
                guard case let .signedIn(currentSubjectID) = model.accountState,
                      currentSubjectID == installSubjectID else { return }
                retryInstallRecording()
            } catch is CancellationError {
                if model.catalogInstall?.id == operationID { model.catalogInstall?.phase = .cancelled }
            } catch {
                guard model.catalogInstall?.id == operationID else { return }
                let code = Self.diagnosticCode(for: error)
                Self.logger.error("Catalog install failed; code=\(code, privacy: .public)")
                let message = code == "stale_revision"
                    ? "This wallpaper changed. Open it again to download the latest version."
                    : "The download couldn’t be completed. Try again."
                model.catalogInstall?.phase = .failed(message)
            }
        }
    }

    private func refreshCatalogSecurityState() async throws -> CatalogSecuritySnapshot {
        guard let gateway, let securityStore else {
            throw CatalogSecurityStateError.unavailable
        }
        return try await refreshCatalogSecurityState(gateway: gateway, store: securityStore)
    }

    private func refreshCatalogSecurityState(
        gateway: any CatalogGateway,
        store: CatalogSecurityStateStore
    ) async throws -> CatalogSecuritySnapshot {
        let snapshot: CatalogSecuritySnapshot
        do {
            snapshot = try await store.accept(gateway.securityState())
        } catch let error as CatalogRemoteError where error.retryable {
            snapshot = try await store.lastKnownGood()
        }
        if let securityHandler {
            try await securityHandler(snapshot)
        }
        return snapshot
    }

    public func toggleFavorite() {
        guard requireAuthentication(for: .favorite),
              let gateway,
              let detail = model.selectedDetail
        else { return }
        let desired = !detail.isFavorite
        performAction {
            let result = try await gateway.setFavorite(
                wallpaperID: detail.id,
                desired: desired,
                expectedRevision: detail.favoriteRevision,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            guard var current = self.model.selectedDetail, current.id == detail.id else { return }
            current.isFavorite = result.desired
            current.favoriteRevision = result.revision
            current.favoriteCount = result.aggregateCount
            self.model.selectedDetail = current
            self.refreshCatalogSurfaces()
        }
    }

    public func toggleSaved() {
        guard requireAuthentication(for: .saved),
              let gateway,
              let detail = model.selectedDetail
        else { return }
        let desired = !detail.isSaved
        performAction {
            let result = try await gateway.setSaved(
                wallpaperID: detail.id,
                desired: desired,
                expectedRevision: detail.savedRevision,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            guard var current = self.model.selectedDetail, current.id == detail.id else { return }
            current.isSaved = result.desired
            current.savedRevision = result.revision
            current.saveCount = result.aggregateCount
            self.model.selectedDetail = current
            self.loadSavedWallpapers()
            self.refreshCatalogSurfaces()
        }
    }

    public func reportSelectedWallpaper(kind: CatalogReportKind, detail: String) {
        guard isMarketplaceAvailable else {
            signIn(resuming: .report)
            return
        }
        guard reportGateway != nil,
              let selected = model.selectedDetail
        else {
            model.reportState = .failed(message: "That report could not be prepared.")
            return
        }
        let request: CatalogReportRequest
        if let retryableReport,
           retryableReport.wallpaperID == selected.id,
           retryableReport.releaseID == selected.currentReleaseID,
           retryableReport.kind == kind,
           retryableReport.detail == detail {
            request = retryableReport
        } else if let fresh = try? CatalogReportRequest(
                  wallpaperID: selected.id,
                  releaseID: selected.currentReleaseID,
                  kind: kind,
                  detail: detail,
                  idempotencyKey: UUID().uuidString.lowercased()
              ) {
            request = fresh
            retryableReport = fresh
        } else {
            model.reportState = .failed(message: "That report could not be prepared.")
            return
        }
        guard case .signedIn = model.accountState else {
            pendingReport = request
            signIn(resuming: .report)
            return
        }
        pendingReport = nil
        submitReport(request)
    }

    private func submitReport(_ request: CatalogReportRequest) {
        guard let reportGateway else { return }
        reportTask?.cancel()
        model.reportState = .working
        reportTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await reportGateway.report(request)
                try Task.checkCancellation()
                retryableReport = nil
                model.reportState = .succeeded(message: "Report submitted for review.")
            } catch is CancellationError {
                return
            } catch {
                let code = Self.diagnosticCode(for: error)
                Self.logger.error("Report submission failed; code=\(code, privacy: .public)")
                model.reportState = .failed(message: "The report could not be submitted. Try again.")
            }
        }
    }

    private func observeAccount() {
        guard let authStore else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            let changes = await authStore.stateChanges()
            for await state in changes {
                guard !Task.isCancelled else { return }
                applyAccountState(state)
            }
        }
    }

    private func applyAccountState(_ state: CatalogAuthState?) {
        let previousUserID: String? = switch model.accountState {
        case let .signedIn(userID): userID
        case .signedOut: nil
        }
        sessionExpiryTask?.cancel()
        guard let state, state.expiresAt > .now else {
            if previousUserID != nil {
                clearSubjectBoundState()
                model.accountState = .signedOut
                refreshCatalogSurfaces()
            } else { model.accountState = .signedOut }
            return
        }
        let changedSubject = previousUserID != nil && previousUserID != state.userID
        let reloadSavedForNewSubject = changedSubject && discovery.savedState != .idle
        if changedSubject { clearSubjectBoundState() }
        model.accountState = .signedIn(userID: state.userID)
        if changedSubject { refreshCatalogSurfaces() }
        if reloadSavedForNewSubject { loadSavedWallpapers() }
        if discovery.preferences?.userID != state.userID { loadPreferences() }
        retryInstallRecording()
        if model.accountProfile?.userID != state.userID {
            loadAccountProfile(for: state.userID)
        }
        loadCreatorContext(for: state.userID)
        sessionExpiryTask = Task { [weak self] in
            let delay = max(0, state.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  case let .signedIn(currentUserID) = model.accountState,
                  currentUserID == state.userID
            else { return }
            clearSubjectBoundState()
            model.accountState = .signedOut
            refreshCatalogSurfaces()
        }
    }

    private func clearSubjectBoundState() {
        preferencesTask?.cancel()
        savedTask?.cancel()
        recordTask?.cancel()
        savedGeneration &+= 1
        pendingPreferenceWrite = nil
        recordGeneration &+= 1
        recordTask = nil
        recordRetryRequested = false
        discovery.preferences = nil
        discovery.preferencesState = .idle
        discovery.preferencesSaveState = .idle
        discovery.savedItems = []
        discovery.savedState = .idle
        discovery.savedNextCursor = nil
        discovery.savedPageError = nil
        discovery.isLoadingSavedPage = false
        discovery.installRecordingFailure = nil
        discovery.isRetryingInstallRecord = false
        discovery.canRetryInstallRecord = false
        savedMediaLease = CatalogMediaLease()
        detailTask?.cancel()
        detailGeneration &+= 1
        detailTargetID = nil
        model.selectedDetail = nil
        selectedInstallMedia = nil
        model.detailState = .idle
        browseTask?.cancel()
        browseGeneration &+= 1
        isLoadingMore = false
        model.browseItems = []
        model.searchItems = []
        model.browseNextCursor = nil
        model.searchNextCursor = nil
        model.browsePageError = nil
        if model.browseState != .idle { model.browseState = .loading }
        browseMediaLease = CatalogMediaLease()
        searchMediaLease = CatalogMediaLease()
        homeTask?.cancel()
        homeGeneration &+= 1
        model.homeSections = []
        model.homeState = .idle
        installTask?.cancel()
        model.catalogInstall = nil
        retryableInstall = nil
        moderatorAccess?.cancel()
        actionTask?.cancel()
        reportTask?.cancel()
        accountTask?.cancel()
        accountExportPollTask?.cancel()
        accountDeletionPollTask?.cancel()
        accountMFATask?.cancel()
        creatorTask?.cancel()
        pendingReport = nil
        retryableReport = nil
        deferredAction = nil
        accountExportSnapshot = nil
        accountDeletionSnapshot = nil
        accountExportRecoveryID = nil
        accountDeletionRecoveryID = nil
        accountExportRequestKey = nil
        accountDeletionRequestKey = nil
        accountMFAFactorID = nil
        accountMFAEnrollmentFactorID = nil
        pendingAccountDeletionConfirmation = nil
        creatorContext.clear()
        model.accountProfile = nil
        model.accountProfileState = .idle
        model.accountExportState = .idle
        model.accountDeletionState = .idle
        model.actionState = .idle
        model.reportState = .idle
    }

    private var accountSubjectMatchesCurrentProfile: Bool {
        guard case let .signedIn(userID) = model.accountState else { return false }
        return model.accountProfile?.userID == userID
    }

    private func accountSubjectMatchesCurrentProfile(_ subjectID: String) -> Bool {
        guard case let .signedIn(userID) = model.accountState else { return false }
        return userID == subjectID && model.accountProfile?.userID == subjectID
    }

    private func loadAccountProfile(for expectedUserID: String) {
        guard let accountGateway else {
            model.accountProfileState = .failed(message: "Account services are unavailable in this build.")
            return
        }
        accountTask?.cancel()
        model.accountProfile = nil
        model.accountProfileState = .loading
        accountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await accountGateway.accountProfile()
                try Task.checkCancellation()
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == expectedUserID,
                      profile.id == expectedUserID
                else {
                    clearSubjectBoundState()
                    model.accountState = .signedOut
                    return
                }
                model.accountProfile = WALIAccountProfilePresentation(
                    userID: profile.id,
                    handle: profile.handle,
                    displayName: profile.displayName,
                    status: profile.status,
                    revision: profile.revision
                )
                model.accountProfileState = .ready
                await restoreAccountOperations(for: expectedUserID)
            } catch is CancellationError {
                return
            } catch {
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == expectedUserID
                else { return }
                model.accountProfileState = .failed(message: "Account details could not be loaded.")
            }
        }
    }

    private func loadCreatorContext(for expectedUserID: String) {
        guard let creatorAuthorizationGateway else {
            creatorContext.clear(subjectID: expectedUserID)
            return
        }
        creatorTask?.cancel()
        creatorContext.beginLoading()
        let moderationGateway = self.moderationGateway
        creatorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.withTimeout(creatorRequestTimeout) {
                    let authorization = try await creatorAuthorizationGateway.authorizationSnapshot()
                    let metadata: CreatorMetadata?
                    if authorization.currentCreatorTermsVersion.isEmpty {
                        // Staff MFA and review authorization do not activate creator terms.
                        metadata = nil
                    } else {
                        metadata = try await creatorAuthorizationGateway.creatorMetadata()
                    }
                    let moderationMetadata: ModerationMetadata?
                    if authorization.canAccessModeration(), let moderationGateway {
                        moderationMetadata = try await moderationGateway.moderationMetadata()
                    } else {
                        moderationMetadata = nil
                    }
                    return CreatorAcceptanceResult(
                        authorization: authorization,
                        metadata: metadata,
                        moderationMetadata: moderationMetadata
                    )
                }
                try Task.checkCancellation()
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == expectedUserID
                else { return }
                guard result.authorization.subjectID == expectedUserID,
                      result.authorization.currentCreatorTermsVersion == (result.metadata?.currentCreatorTermsVersion ?? "")
                else {
                    creatorContext.fail()
                    return
                }
                creatorContext.apply(
                    authorization: result.authorization,
                    metadata: result.metadata,
                    moderationMetadata: result.moderationMetadata
                )
            } catch is CancellationError {
                return
            } catch {
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == expectedUserID
                else { return }
                creatorContext.fail()
            }
        }
    }

    private func restoreAccountOperations(for subjectID: String) async {
        guard let accountGateway else { return }
        do {
            let references = try await accountGateway.accountOperationReferences()
            try Task.checkCancellation()
            guard accountSubjectMatchesCurrentProfile(subjectID),
                  let references, references.subjectID == subjectID
            else { return }
            if accountExportSnapshot == nil, let id = references.exportID {
                accountExportRecoveryID = id
                pollAccountExport(id: id)
            }
            if accountDeletionSnapshot == nil, let id = references.deletionID {
                accountDeletionRecoveryID = id
                pollAccountDeletion(id: id)
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Account operation recovery references could not be restored")
        }
    }

    private func applyAccountExport(_ snapshot: AccountExportSnapshot) {
        accountExportSnapshot = snapshot
        accountExportRecoveryID = snapshot.id
        switch snapshot.status {
        case .queued:
            model.accountExportState = .queued
        case .processing:
            model.accountExportState = .processing
        case .ready:
            guard let expiresAt = snapshot.downloadExpiresAt else {
                model.accountExportState = .failed(message: "The export response was incomplete.")
                return
            }
            model.accountExportState = .ready(expiresAt: expiresAt)
        case .expired:
            model.accountExportState = .failed(message: "This export expired. Request a new one.")
        case .failed:
            model.accountExportState = .failed(message: "The export could not be prepared. Try again.")
        }
    }

    private func beginAccountExportPollingIfNeeded(_ snapshot: AccountExportSnapshot) {
        guard snapshot.status == .queued || snapshot.status == .processing else { return }
        accountExportPollTask?.cancel()
        accountExportPollTask = Task { [weak self] in
            guard let self, let accountGateway else { return }
            var current = snapshot
            for _ in 0..<60 {
                do {
                    try await Task.sleep(for: .seconds(5))
                    let next = try await accountGateway.accountExportStatus(
                        id: current.id,
                        idempotencyKey: UUID().uuidString.lowercased()
                    )
                    try Task.checkCancellation()
                    guard accountSubjectMatchesCurrentProfile(next.subjectID) else { return }
                    current = next
                    applyAccountExport(next)
                    if next.status != .queued && next.status != .processing { return }
                } catch is CancellationError {
                    return
                } catch {
                    guard accountSubjectMatchesCurrentProfile else { return }
                    model.accountExportState = .failed(message: "Export status could not be refreshed.")
                    return
                }
            }
            if current.status == .queued || current.status == .processing {
                model.accountExportState = .failed(message: "The export is taking longer than expected. Refresh to check again.")
            }
        }
    }

    private func pollAccountExport(id: String) {
        guard let accountGateway else { return }
        accountExportPollTask?.cancel()
        model.accountExportState = .working
        accountExportPollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await accountGateway.accountExportStatus(
                    id: id,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile(next.subjectID) else { return }
                applyAccountExport(next)
                beginAccountExportPollingIfNeeded(next)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .failed(message: "Export status could not be refreshed.")
            }
        }
    }

    private func applyAccountDeletion(_ snapshot: AccountDeletionSnapshot) {
        accountDeletionSnapshot = snapshot
        accountDeletionRecoveryID = snapshot.id
        if snapshot.status == .completed, let completedAt = snapshot.completedAt {
            model.accountDeletionState = .completed(completedAt: completedAt)
            return
        }
        if snapshot.status == .failed || snapshot.status == .cancelled {
            model.accountDeletionState = .failed(message: "The deletion request did not complete.")
            return
        }
        model.accountDeletionState = .pending(
            status: Self.accountDeletionLabel(snapshot.status),
            identityStatus: Self.identityDeletionLabel(snapshot.identityStatus),
            held: snapshot.held
        )
    }

    private func beginAccountDeletionPollingIfNeeded(_ snapshot: AccountDeletionSnapshot) {
        guard snapshot.status != .completed,
              snapshot.status != .failed,
              snapshot.status != .cancelled,
              snapshot.status != .held
        else { return }
        accountDeletionPollTask?.cancel()
        accountDeletionPollTask = Task { [weak self] in
            guard let self, let accountGateway else { return }
            var current = snapshot
            for _ in 0..<60 {
                do {
                    try await Task.sleep(for: .seconds(5))
                    let next = try await accountGateway.accountDeletionStatus(
                        id: current.id,
                        idempotencyKey: UUID().uuidString.lowercased()
                    )
                    try Task.checkCancellation()
                    guard accountSubjectMatchesCurrentProfile(next.subjectID) else { return }
                    current = next
                    accountDeletionSnapshot = next
                    applyAccountDeletion(next)
                    if next.status == .completed || next.status == .failed
                        || next.status == .cancelled || next.status == .held {
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard accountSubjectMatchesCurrentProfile else { return }
                    model.accountDeletionState = .failed(message: "Deletion status could not be refreshed.")
                    return
                }
            }
        }
    }

    private func pollAccountDeletion(id: String) {
        guard let accountGateway else { return }
        accountDeletionPollTask?.cancel()
        model.accountDeletionState = .working
        accountDeletionPollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await accountGateway.accountDeletionStatus(
                    id: id,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile(next.subjectID) else { return }
                accountDeletionSnapshot = next
                applyAccountDeletion(next)
                beginAccountDeletionPollingIfNeeded(next)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountDeletionState = .failed(message: "Deletion status could not be refreshed.")
            }
        }
    }

    private static func accountDeletionLabel(_ status: AccountDeletionStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .processing: "Removing marketplace data"
        case .held: "On hold"
        case .awaitingAuthCleanup: "Finishing identity removal"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private static func identityDeletionLabel(_ status: AccountIdentityDeletionStatus) -> String {
        switch status {
        case .sessionRevocationPending: "Session revocation pending"
        case .sessionsRevoked: "Sessions revoked"
        case .operatorCleanupRequired: "Identity cleanup pending"
        case .completed: "Identity removed"
        }
    }

    private func requireAuthentication(for action: DeferredAction) -> Bool {
        guard isMarketplaceAvailable else {
            signIn(resuming: action)
            return false
        }
        guard case .signedIn = model.accountState else {
            signIn(resuming: action)
            return false
        }
        return true
    }

    private func resume(_ action: DeferredAction?) {
        switch action {
        case .favorite: toggleFavorite()
        case .saved: toggleSaved()
        case .install: installSelectedWallpaper()
        case .report:
            guard let pendingReport else { break }
            self.pendingReport = nil
            submitReport(pendingReport)
        case nil: break
        }
    }

    private func performAction(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        actionTask?.cancel()
        model.actionState = .working
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                try Task.checkCancellation()
                if model.actionState == .working {
                    model.actionState = .idle
                }
            } catch is CancellationError {
                return
            } catch let error as CatalogRemoteError where error.code == "stale_revision" {
                model.actionState = .failed(message: "This wallpaper changed. Refresh and try again.")
            } catch {
                let code = Self.diagnosticCode(for: error)
                Self.logger.error("Marketplace action failed; code=\(code, privacy: .public)")
                model.actionState = .failed(message: "That action could not be completed.")
            }
        }
    }

    static func diagnosticCode(for error: Error) -> String {
        if let remote = error as? CatalogRemoteError {
            let bytes = Array(remote.code.utf8)
            guard (1...64).contains(bytes.count), bytes.allSatisfy({ byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 95
            }) else { return "remote_error" }
            return remote.code
        }
        if let request = error as? CatalogRequestError { return request.rawValue }
        if let download = error as? CatalogDownloadError { return download.rawValue }
        if let media = error as? CatalogPresentationMediaCacheError { return media.rawValue }
        return "internal_error"
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = CreatorRequestTimeoutRace<Value>()
        return try await withTaskCancellationHandler {
            try await race.run(duration: duration, operation: operation)
        } onCancel: {
            Task { await race.cancel() }
        }
    }

    static func recordInstallWithRetry(
        maximumAttempts: Int = 3,
        delay: Duration = .seconds(1),
        operation: @escaping @Sendable () async throws -> Void
    ) async -> String? {
        let attempts = max(1, maximumAttempts)
        for attempt in 1...attempts {
            do {
                try await operation()
                return nil
            } catch is CancellationError {
                return "cancelled"
            } catch let remote as CatalogRemoteError where remote.retryable && attempt < attempts {
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                } catch {
                    return "cancelled"
                }
            } catch {
                return diagnosticCode(for: error)
            }
        }
        return "temporarily_unavailable"
    }

    private nonisolated static func card(
        _ item: CatalogWallpaperSummary,
        posterURL: URL? = nil,
        previewURL: URL? = nil
    ) -> WALICatalogCardPresentation {
        WALICatalogCardPresentation(
            id: item.id,
            title: item.title,
            creator: item.creator.displayName,
            category: item.primaryCategory.name,
            tags: item.approvedTags.map(\.name),
            posterURL: posterURL,
            previewURL: previewURL,
            verifiedInstallCount: item.verifiedInstallCount,
            favoriteCount: item.favoriteCount,
            saveCount: item.saveCount,
            pixelWidth: item.poster.width,
            pixelHeight: item.poster.height
        )
    }

    private func presentationCards(
        _ items: [CatalogWallpaperSummary],
        retaining lease: CatalogMediaLease,
        includePreview: Bool = false,
        onCard: (@MainActor (WALICatalogCardPresentation) -> Void)? = nil
    ) async -> [WALICatalogCardPresentation] {
        guard let presentationMediaCache else {
            return items.map { Self.card($0) }
        }
        return await withTaskGroup(of: (Int, WALICatalogCardPresentation).self) { group in
            var pending = Array(items.enumerated()).makeIterator()
            func enqueue(_ entry: (offset: Int, element: CatalogWallpaperSummary)) {
                group.addTask {
                    let posterURL = try? await presentationMediaCache.localURL(for: entry.element.poster, retaining: lease)
                    var previewURL: URL?
                    if includePreview, !Task.isCancelled, let preview = entry.element.preview {
                        previewURL = try? await presentationMediaCache.localURL(for: preview, retaining: lease)
                    }
                    return (entry.offset, Self.card(entry.element, posterURL: posterURL, previewURL: previewURL))
                }
            }
            for _ in 0..<4 { if let entry = pending.next() { enqueue(entry) } }
            var values: [(Int, WALICatalogCardPresentation)] = []
            while let value = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                values.append(value)
                onCard?(value.1)
                if let entry = pending.next() { enqueue(entry) }
            }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func presentationSections(
        _ sections: [CatalogHomeSection]
    ) -> [WALICatalogSectionPresentation] {
        let heroSummaries = WALIDiscoverLayout.carouselItems(from: sections.map(\.items))
        var result: [WALICatalogSectionPresentation] = []
        if !heroSummaries.isEmpty {
            result.append(WALICatalogSectionPresentation(
                id: WALIDiscoverLayout.heroSectionID,
                title: WALIDiscoverLayout.heroSectionTitle,
                layout: WALIDiscoverLayout.heroSectionLayout,
                cards: heroSummaries.map { Self.card($0) }
            ))
        }
        for section in sections where !section.items.isEmpty {
            result.append(WALICatalogSectionPresentation(
                id: section.id,
                title: section.title,
                layout: WALIDiscoverLayout.catalogSectionLayout,
                cards: section.items.map { Self.card($0) }
            ))
        }
        return result
    }

    private func hydrateBrowse(_ items: [CatalogWallpaperSummary], generation: UInt64, searching: Bool) async {
        _ = await presentationCards(items, retaining: searching ? searchMediaLease : browseMediaLease) { [weak self] card in
            guard let self, generation == browseGeneration else { return }
            if searching {
                model.searchItems = model.searchItems.map { $0.id == card.id ? $0.withMedia(from: card) : $0 }
            } else {
                model.browseItems = model.browseItems.map { $0.id == card.id ? $0.withMedia(from: card) : $0 }
            }
        }
    }

    private func hydrateHome(_ sections: [CatalogHomeSection], generation: UInt64) async {
        var seen: Set<String> = []
        let items = sections.flatMap(\.items).filter { seen.insert($0.id).inserted }
        let update: @MainActor (WALICatalogCardPresentation) -> Void = { [weak self] card in
            guard let self, generation == homeGeneration else { return }
            model.homeSections = model.homeSections.map { section in
                WALICatalogSectionPresentation(id: section.id, title: section.title, layout: section.layout,
                    cards: section.cards.map { $0.id == card.id ? $0.withMedia(from: card) : $0 })
            }
        }
        _ = await presentationCards(items, retaining: homeMediaLease, onCard: update)
        guard !Task.isCancelled, generation == homeGeneration else { return }
        let heroes = WALIDiscoverLayout.carouselItems(from: sections.map(\.items))
        _ = await presentationCards(heroes, retaining: homeMediaLease, includePreview: true, onCard: update)
    }

    private enum DetailMediaUpdate: Sendable {
        case poster(URL?)
        case preview(URL?)
        case related([WALICatalogCardPresentation])
    }

    private func hydrateDetail(_ value: CatalogWallpaperDetail, generation: UInt64) async {
        guard let presentationMediaCache else { return }
        let lease = detailMediaLease
        await withTaskGroup(of: DetailMediaUpdate.self) { group in
            var pendingHeroMedia = 2
            group.addTask {
                .poster(try? await presentationMediaCache.localURL(for: value.summary.poster, retaining: lease))
            }
            group.addTask {
                guard case let .video(artifact, _, _, _) = value.media else { return .preview(nil) }
                let playback = try? await presentationMediaCache.localURL(for: artifact, retaining: lease)
                guard !Task.isCancelled else { return .preview(nil) }
                if let playback { return .preview(playback) }
                guard let preview = value.summary.preview else { return .preview(nil) }
                return .preview(try? await presentationMediaCache.localURL(for: preview, retaining: lease))
            }
            group.addTask { [weak self] in
                .related(await self?.presentationCards(value.related, retaining: lease) ?? [])
            }
            for await update in group {
                guard !Task.isCancelled, generation == detailGeneration,
                      var current = model.selectedDetail, current.id == value.id,
                      current.currentReleaseID == value.summary.currentReleaseID else {
                    group.cancelAll()
                    return
                }
                // Patch the latest value so a media completion cannot undo a
                // Favorite or Save action performed while the preview loads.
                switch update {
                case let .poster(url):
                    current.updateVerifiedPoster(url)
                    pendingHeroMedia -= 1
                case let .preview(url):
                    current.updateVerifiedPreview(url)
                    pendingHeroMedia -= 1
                case let .related(cards): current.updateRelated(cards)
                }
                if pendingHeroMedia == 0 { current.finishLoadingMedia() }
                model.selectedDetail = current
            }
        }
    }

    private func presentationDetail(
        _ value: CatalogWallpaperDetail
    ) -> WALICatalogDetailPresentation {
        let duration = value.durationMilliseconds.map { milliseconds in
            let totalSeconds = milliseconds / 1_000
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
        return WALICatalogDetailPresentation(
            id: value.id,
            title: value.summary.title,
            creator: value.summary.creator.displayName,
            creatorHandle: value.summary.creator.handle,
            description: value.description,
            previewURL: nil,
            posterURL: nil,
            attribution: value.attributionText,
            rightsHolder: value.rightsHolder,
            sourceURL: value.sourceURL,
            licenseName: value.license.name,
            licenseTermsURL: value.license.termsURL,
            dimensions: "\(value.width) × \(value.height)",
            duration: duration,
            framesPerSecond: value.framesPerSecond,
            verifiedInstallCount: value.summary.verifiedInstallCount,
            favoriteCount: value.summary.favoriteCount,
            saveCount: value.summary.saveCount,
            category: value.summary.primaryCategory.name,
            tags: value.summary.approvedTags.map(\.name),
            isFavorite: value.isFavorite,
            favoriteRevision: value.favoriteRevision,
            isSaved: value.isSaved,
            savedRevision: value.savedRevision,
            currentReleaseID: value.summary.currentReleaseID,
            wallpaperRevision: value.summary.revision,
            related: value.related.map { Self.card($0) },
            isLoadingMedia: presentationMediaCache != nil
        )
    }

    private static func loadState(for error: Error) -> WALIMarketplaceLoadState {
        if let remote = error as? CatalogRemoteError {
            if remote.code == "network_unavailable" { return .offline }
            if remote.retryable {
                return .failed(message: "The marketplace is temporarily unavailable. Try again in a moment.")
            }
        }
        return .failed(message: "The marketplace could not be loaded.")
    }

    private func appendUnique(
        _ existing: [WALICatalogCardPresentation],
        _ incoming: [WALICatalogCardPresentation]
    ) -> [WALICatalogCardPresentation] {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }
}
