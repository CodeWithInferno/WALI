import AppKit
import Foundation
import Observation
import OSLog
import WALICatalogRuntime
import WALIUI

public enum MarketplaceCreatorAccessState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case acceptingTerms
    case failed
}

@MainActor
@Observable
public final class MarketplaceCreatorContext {
    public private(set) var state: MarketplaceCreatorAccessState = .idle
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
        moderationModel?.updateAuthorization(authorization)
        state = .ready
    }

    func fail() {
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
        moderationModel?.updateAuthorization(restricted)
        state = .idle
    }
}

@MainActor
public final class MarketplaceCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.wali.WALI",
        category: "Marketplace"
    )

    public let model: WALIMarketplaceModel
    public let creatorContext: MarketplaceCreatorContext
    public let creatorGateway: (any CreatorStudioGateway)?
    private let gateway: (any CatalogGateway)?
    private let reportGateway: (any CatalogReportGateway)?
    private let accountGateway: (any AccountPrivacyGateway)?
    private let creatorAuthorizationGateway: (any CreatorAuthorizationGateway)?
    private let moderationGateway: (any ModerationGateway)?
    private let authStore: (any CatalogAuthSessionProviding)?
    private let mfaStore: (any AccountMFASessionProviding)?
    private let appleSignIn: AppleSignInCoordinator?
    private let installPreparer: CatalogInstallPreparer?
    private let presentationMediaCache: (any CatalogPresentationMediaCaching)?
    private let securityStore: CatalogSecurityStateStore?
    private let installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)?
    private let securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)?
    private var homeGeneration: UInt64 = 0
    private var browseGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var homeTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
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

    public init(
        model: WALIMarketplaceModel = WALIMarketplaceModel(),
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
        installPreparer: CatalogInstallPreparer? = nil,
        presentationMediaCache: (any CatalogPresentationMediaCaching)? = nil,
        securityStore: CatalogSecurityStateStore? = nil,
        installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)? = nil,
        securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)? = nil
    ) {
        self.model = model
        self.gateway = gateway
        self.reportGateway = reportGateway
        self.accountGateway = accountGateway
        self.creatorGateway = creatorGateway
        self.creatorAuthorizationGateway = creatorAuthorizationGateway
        self.moderationGateway = moderationGateway
        creatorContext = MarketplaceCreatorContext(
            creatorGateway: creatorGateway,
            uploadTransport: creatorUploadTransport,
            moderationGateway: moderationGateway,
            presentationMediaCache: presentationMediaCache
        )
        self.authStore = authStore
        self.mfaStore = mfaStore
        self.appleSignIn = appleSignIn
        self.installPreparer = installPreparer
        self.presentationMediaCache = presentationMediaCache
        self.securityStore = securityStore
        self.installHandler = installHandler
        self.securityHandler = securityHandler
    }

    public static func configured(
        bundle: Bundle = .main,
        installHandler: (@MainActor (PreparedCatalogInstall) async throws -> Void)? = nil,
        securityHandler: (@MainActor (CatalogSecuritySnapshot) async throws -> Void)? = nil
    ) -> MarketplaceCoordinator {
        guard let environment = try? CatalogEnvironment.from(bundle: bundle) else {
            return MarketplaceCoordinator()
        }
        let gateway = SupabaseCatalogGateway(environment: environment)
        var uploadHosts = environment.approvedCDNHosts
        if let supabaseHost = environment.supabaseURL.host { uploadHosts.insert(supabaseHost) }
        let uploadTransport = try? URLSessionCreatorUploadTransport(approvedHosts: uploadHosts)
        let authStore = gateway.makeAuthSessionStore()
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.wali.WALI"
        let securityStore = try? CatalogSecurityStateStore(
            environment: environment,
            cacheURL: try CatalogSecurityStateStore.defaultCacheURL(
                bundleIdentifier: bundleIdentifier
            )
        )
        return MarketplaceCoordinator(
            gateway: gateway,
            reportGateway: gateway,
            accountGateway: gateway,
            creatorGateway: gateway,
            creatorAuthorizationGateway: gateway,
            creatorUploadTransport: uploadTransport,
            moderationGateway: gateway,
            authStore: authStore,
            mfaStore: authStore,
            appleSignIn: AppleSignInCoordinator(sessionStore: authStore),
            installPreparer: try? CatalogInstallPreparer(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ),
            presentationMediaCache: try? CatalogPresentationMediaCache(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ),
            securityStore: securityStore,
            installHandler: installHandler,
            securityHandler: securityHandler
        )
    }

    public func start() {
        if model.homeState == .idle { loadHome() }
        observeAccount()
        securityTask?.cancel()
        securityTask = Task { [weak self] in
            _ = try? await self?.refreshCatalogSecurityState()
        }
    }

    public func stop() {
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

    public func loadHome() {
        homeTask?.cancel()
        homeGeneration &+= 1
        let generation = homeGeneration
        model.homeState = .loading
        guard let gateway else {
            model.homeState = .empty
            return
        }
        homeTask = Task { [weak self] in
            do {
                let home = try await gateway.home(
                    locale: Locale.current.identifier,
                    ratingCeiling: "mature"
                )
                try Task.checkCancellation()
                guard let self, generation == self.homeGeneration else { return }
                self.model.homeSections = await self.presentationSections(home.sections)
                try Task.checkCancellation()
                guard generation == self.homeGeneration else { return }
                self.model.homeState = home.sections.isEmpty ? .empty : .ready
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
        currentBrowseCategory = category
        currentBrowseTags = tags
        currentBrowseSort = sort
        currentSearchQuery = nil
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
                self.model.browseItems = await self.presentationCards(page.items)
                try Task.checkCancellation()
                guard generation == self.browseGeneration else { return }
                self.model.browseNextCursor = page.nextCursor
                self.model.browseState = page.items.isEmpty ? .empty : .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.browseGeneration else { return }
                self.model.browseState = Self.loadState(for: error)
            }
        }
    }

    public func search(_ query: String) {
        browseTask?.cancel()
        browseGeneration &+= 1
        let generation = browseGeneration
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentSearchQuery = nil
            model.searchItems = []
            model.searchNextCursor = nil
            model.browseState = .idle
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
                let response = try await gateway.search(CatalogSearchRequest(query: query))
                try Task.checkCancellation()
                guard let self, generation == self.browseGeneration else { return }
                self.model.searchItems = await self.presentationCards(response.page.items)
                try Task.checkCancellation()
                guard generation == self.browseGeneration else { return }
                self.model.searchNextCursor = response.page.nextCursor
                self.model.browseState = response.page.items.isEmpty ? .empty : .ready
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
        browseGeneration &+= 1
        let generation = browseGeneration
        browseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                browseTask = nil
                isLoadingMore = false
            }
            do {
                if let searchQuery {
                    let request = try CatalogSearchRequest(query: searchQuery, cursor: cursor)
                    let response = try await gateway.search(request)
                    try Task.checkCancellation()
                    guard generation == browseGeneration else { return }
                    let cards = await presentationCards(response.page.items)
                    try Task.checkCancellation()
                    guard generation == browseGeneration else { return }
                    model.searchItems = appendUnique(model.searchItems, cards)
                    model.searchNextCursor = response.page.nextCursor
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
                    let cards = await presentationCards(response.items)
                    try Task.checkCancellation()
                    guard generation == browseGeneration else { return }
                    model.browseItems = appendUnique(model.browseItems, cards)
                    model.browseNextCursor = response.nextCursor
                }
            } catch is CancellationError {
                return
            } catch {
                model.actionState = .failed(message: "More wallpapers could not be loaded.")
            }
        }
    }

    public func loadDetail(wallpaperID: String) {
        detailTask?.cancel()
        detailGeneration &+= 1
        let generation = detailGeneration
        model.selectedDetail = nil
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
                self.model.selectedDetail = await self.presentationDetail(detail)
                try Task.checkCancellation()
                guard generation == self.detailGeneration else { return }
                self.model.detailState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.detailGeneration else { return }
                self.model.detailState = Self.loadState(for: error)
            }
        }
    }

    public func signIn() {
        signIn(resuming: nil)
    }

    private func signIn(resuming action: DeferredAction?) {
        guard let appleSignIn,
              let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        else {
            deferredAction = nil
            pendingReport = nil
            if case .report = action {
                model.reportState = .failed(message: "Sign in is unavailable in this build.")
            } else {
                model.actionState = .failed(message: "Sign in is unavailable in this build.")
            }
            return
        }
        deferredAction = action
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await appleSignIn.signIn(presentingFrom: window)
                model.accountState = .signedIn(userID: state.userID)
                loadAccountProfile(for: state.userID)
                let pending = deferredAction
                deferredAction = nil
                resume(pending)
            } catch is CancellationError {
                if case .report = action { model.reportState = .idle }
                deferredAction = nil
                pendingReport = nil
                return
            } catch {
                if case .report = action {
                    model.reportState = .failed(message: "Sign in was not completed.")
                }
                deferredAction = nil
                pendingReport = nil
                model.accountState = .signedOut
            }
        }
    }

    public func signOut() {
        guard let authStore else { return }
        Task { [weak self] in
            do {
                try await authStore.signOut()
                self?.clearSubjectBoundState()
                self?.model.accountState = .signedOut
            } catch {
                return
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
              let creatorAuthorizationGateway,
              let version = creatorContext.metadata?.currentCreatorTermsVersion
        else { return }
        creatorTask?.cancel()
        creatorContext.beginAcceptingTerms()
        creatorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await creatorAuthorizationGateway.acceptCreatorTerms(
                    version: version,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                let metadata = try await creatorAuthorizationGateway.creatorMetadata()
                let moderationMetadata: ModerationMetadata?
                if authorization.canAccessModeration(), let moderationGateway {
                    moderationMetadata = try await moderationGateway.moderationMetadata()
                } else {
                    moderationMetadata = nil
                }
                try Task.checkCancellation()
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == userID,
                      authorization.subjectID == userID,
                      authorization.currentCreatorTermsVersion == metadata.currentCreatorTermsVersion
                else { return }
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
                creatorContext.fail()
            }
        }
    }

    public func requestAccountExport() {
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
        guard let snapshot = accountExportSnapshot else { return }
        pollAccountExport(snapshot)
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
                try await accountGateway.saveAccountExport(snapshot, to: destination)
                try Task.checkCancellation()
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .saved(fileName: destination.lastPathComponent)
            } catch is CancellationError {
                return
            } catch {
                guard accountSubjectMatchesCurrentProfile else { return }
                model.accountExportState = .failed(
                    message: "The export failed integrity verification and was not saved."
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
        guard let snapshot = accountDeletionSnapshot else { return }
        pollAccountDeletion(snapshot)
    }

    public func installSelectedWallpaper() {
        guard requireAuthentication(for: .install),
              let gateway,
              let installPreparer,
              let securityStore,
              let installHandler,
              let detail = model.selectedDetail
        else { return }
        let idempotencyKey = UUID().uuidString.lowercased()
        performAction {
            let security = try await self.refreshCatalogSecurityState(
                gateway: gateway,
                store: securityStore
            )
            let grant = try await gateway.requestInstall(
                wallpaperID: detail.id,
                releaseID: detail.currentReleaseID,
                expectedWallpaperRevision: detail.wallpaperRevision,
                idempotencyKey: idempotencyKey
            )
            let prepared = try await installPreparer.prepare(
                grant: grant,
                expectedWallpaperID: detail.id,
                expectedReleaseID: detail.currentReleaseID,
                security: security
            )
            do {
                try await installHandler(prepared)
            } catch {
                installPreparer.discard(quarantineReference: prepared.quarantineReference)
                throw error
            }
            installPreparer.discard(quarantineReference: prepared.quarantineReference)
            // Metrics are explicitly best effort: verified local playback must
            // remain available if the network disappears after installation.
            if let code = await Self.recordInstallWithRetry(operation: {
                try await gateway.recordInstall(
                    receipt: grant.receipt,
                    manifestDigest: prepared.manifestDigest,
                    releaseID: prepared.releaseID,
                    idempotencyKey: idempotencyKey
                )
            }) {
                Self.logger.error("Install metric could not be recorded; code=\(code, privacy: .public)")
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
        }
    }

    public func reportSelectedWallpaper(kind: CatalogReportKind, detail: String) {
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
            clearSubjectBoundState()
            model.accountState = .signedOut
            return
        }
        if previousUserID != nil, previousUserID != state.userID {
            clearSubjectBoundState()
        }
        model.accountState = .signedIn(userID: state.userID)
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
        }
    }

    private func clearSubjectBoundState() {
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
        creatorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await creatorAuthorizationGateway.authorizationSnapshot()
                let metadata = try await creatorAuthorizationGateway.creatorMetadata()
                let moderationMetadata: ModerationMetadata?
                if authorization.canAccessModeration(), let moderationGateway {
                    moderationMetadata = try await moderationGateway.moderationMetadata()
                } else {
                    moderationMetadata = nil
                }
                try Task.checkCancellation()
                guard case let .signedIn(currentUserID) = model.accountState,
                      currentUserID == expectedUserID,
                      authorization.subjectID == expectedUserID,
                      authorization.currentCreatorTermsVersion == metadata.currentCreatorTermsVersion
                else { return }
                creatorContext.apply(
                    authorization: authorization,
                    metadata: metadata,
                    moderationMetadata: moderationMetadata
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

    private func applyAccountExport(_ snapshot: AccountExportSnapshot) {
        accountExportSnapshot = snapshot
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
            for _ in 0..<150 {
                do {
                    try await Task.sleep(for: .seconds(2))
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

    private func pollAccountExport(_ snapshot: AccountExportSnapshot) {
        guard let accountGateway else { return }
        accountExportPollTask?.cancel()
        model.accountExportState = .working
        accountExportPollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await accountGateway.accountExportStatus(
                    id: snapshot.id,
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
            for _ in 0..<150 {
                do {
                    try await Task.sleep(for: .seconds(2))
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

    private func pollAccountDeletion(_ snapshot: AccountDeletionSnapshot) {
        guard let accountGateway else { return }
        accountDeletionPollTask?.cancel()
        model.accountDeletionState = .working
        accountDeletionPollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await accountGateway.accountDeletionStatus(
                    id: snapshot.id,
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
            saveCount: item.saveCount
        )
    }

    private func presentationCards(
        _ items: [CatalogWallpaperSummary]
    ) async -> [WALICatalogCardPresentation] {
        guard let presentationMediaCache else {
            return items.map { Self.card($0) }
        }
        return await withTaskGroup(of: (Int, WALICatalogCardPresentation).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let posterURL = try? await presentationMediaCache.localURL(for: item.poster)
                    return (index, Self.card(item, posterURL: posterURL))
                }
            }
            var values: [(Int, WALICatalogCardPresentation)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func presentationSections(
        _ sections: [CatalogHomeSection]
    ) async -> [WALICatalogSectionPresentation] {
        var result: [WALICatalogSectionPresentation] = []
        for section in sections {
            result.append(WALICatalogSectionPresentation(
                id: section.id,
                title: section.title,
                cards: await presentationCards(section.items)
            ))
        }
        return result
    }

    private func presentationDetail(
        _ value: CatalogWallpaperDetail
    ) async -> WALICatalogDetailPresentation {
        let posterURL = try? await presentationMediaCache?.localURL(for: value.summary.poster)
        let previewURL = try? await presentationMediaCache?.localURL(for: value.summary.preview)
        let related = await presentationCards(value.related)
        let totalSeconds = value.durationMilliseconds / 1_000
        let duration = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        return WALICatalogDetailPresentation(
            id: value.id,
            title: value.summary.title,
            creator: value.summary.creator.displayName,
            creatorHandle: value.summary.creator.handle,
            description: value.description,
            previewURL: previewURL ?? nil,
            posterURL: posterURL ?? nil,
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
            related: related
        )
    }

    private static func loadState(for error: Error) -> WALIMarketplaceLoadState {
        if let remote = error as? CatalogRemoteError,
           remote.code == "temporarily_unavailable" {
            return .offline
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
