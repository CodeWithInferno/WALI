import Foundation
import WALICatalog
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
final class MarketplaceCoordinatorTests: XCTestCase {
    private struct SecretBearingError: Error, CustomStringConvertible {
        let description = "authorization=Bearer secret-session-token"
    }

    private func waitForCreatorState(
        _ expectedState: MarketplaceCreatorAccessState,
        in coordinator: MarketplaceCoordinator,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while coordinator.creatorContext.state != expectedState, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return coordinator.creatorContext.state == expectedState
    }

    func testDiagnosticsExposeOnlyStableBoundedCodes() {
        XCTAssertEqual(
            MarketplaceCoordinator.diagnosticCode(for: SecretBearingError()),
            "internal_error"
        )
        XCTAssertEqual(
            MarketplaceCoordinator.diagnosticCode(for: CatalogRemoteError(
                code: "install_receipt_expired",
                safeMessage: "server prose must not be logged",
                retryable: false
            )),
            "install_receipt_expired"
        )
        XCTAssertEqual(
            MarketplaceCoordinator.diagnosticCode(for: CatalogRemoteError(
                code: "BAD code with secret",
                safeMessage: nil,
                retryable: false
            )),
            "remote_error"
        )
    }

    func testInstallReceiptRecordingRetriesOnlyTransientFailures() async {
        let transient = ReceiptRecordingProbe(failures: 1, retryable: true)
        let transientCode = await MarketplaceCoordinator.recordInstallWithRetry(
            delay: Duration.zero
        ) {
            try await transient.record()
        }
        XCTAssertNil(transientCode)
        let transientCalls = await transient.callCount
        XCTAssertEqual(transientCalls, 2)

        let permanent = ReceiptRecordingProbe(failures: 3, retryable: false)
        let permanentCode = await MarketplaceCoordinator.recordInstallWithRetry(
            delay: Duration.zero
        ) {
            try await permanent.record()
        }
        XCTAssertEqual(permanentCode, "install_receipt_invalid")
        let permanentCalls = await permanent.callCount
        XCTAssertEqual(permanentCalls, 1)
    }

    func testMissingConfigurationUsesHonestEmptyState() {
        let coordinator = MarketplaceCoordinator()

        coordinator.loadHome()

        XCTAssertEqual(coordinator.model.homeState, .empty)
        XCTAssertTrue(coordinator.model.homeSections.isEmpty)
    }

    func testNewerHomeRequestWinsWhenAnOlderRequestFinishesLater() async throws {
        let oldHome = CatalogHome(sections: [section(id: "old", title: "Old")])
        let newHome = CatalogHome(sections: [section(id: "new", title: "New")])
        let gateway = ScriptedCatalogGateway(homeSteps: [
            .value(oldHome, delay: .milliseconds(250)),
            .value(newHome, delay: .milliseconds(5)),
        ])
        let coordinator = MarketplaceCoordinator(gateway: gateway)

        coordinator.loadHome()
        try await Task.sleep(for: .milliseconds(20))
        coordinator.loadHome()
        try await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(coordinator.model.homeState, .ready)
        XCTAssertEqual(coordinator.model.homeSections.map(\.id), ["new"])
    }

    func testDiscoverHomeCarouselCollectsUniqueItemsFromEverySection() async throws {
        let rick = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", title: "Rick")
        let aurora = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2", title: "Aurora")
        let home = CatalogHome(sections: [
            CatalogHomeSection(
                id: "editorial",
                title: "Picks",
                kind: .editorial,
                cursor: nil,
                items: [rick]
            ),
            CatalogHomeSection(
                id: "trending",
                title: "Trending",
                kind: .trending,
                cursor: nil,
                items: [rick, aurora]
            ),
        ])
        let coordinator = MarketplaceCoordinator(
            gateway: ScriptedCatalogGateway(homeSteps: [.value(home, delay: .milliseconds(75))])
        )

        coordinator.loadHome()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.homeState == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.model.homeState, .ready)
        XCTAssertEqual(
            coordinator.model.homeSections.map(\.id),
            [WALIDiscoverLayout.heroSectionID, "editorial", "trending"]
        )
        XCTAssertEqual(coordinator.model.homeSections.first?.layout, WALIDiscoverLayout.heroSectionLayout)
        XCTAssertEqual(coordinator.model.homeSections.first?.title, WALIDiscoverLayout.heroSectionTitle)
        XCTAssertEqual(coordinator.model.homeSections.first?.cards.map(\.id), [rick.id, aurora.id])
        XCTAssertEqual(
            Array(coordinator.model.homeSections.dropFirst().map(\.layout)),
            [WALIDiscoverLayout.catalogSectionLayout, WALIDiscoverLayout.catalogSectionLayout]
        )
    }

    func testTemporaryFailureDoesNotClaimOfflineOrLeakServerText() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [
            .failure(CatalogRemoteError(
                code: "temporarily_unavailable",
                safeMessage: "sensitive upstream description",
                retryable: true
            )),
        ])
        let coordinator = MarketplaceCoordinator(gateway: gateway)

        coordinator.loadHome()
        try await Task.sleep(for: .milliseconds(30))

        guard case let .failed(message) = coordinator.model.homeState else {
            return XCTFail("A server failure must not claim the network is offline")
        }
        XCTAssertFalse(message.contains("sensitive upstream description"))
        XCTAssertTrue(coordinator.model.homeSections.isEmpty)
    }

    func testUnverifiedRemoteMediaURLsNeverReachPresentationModels() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
        let coordinator = MarketplaceCoordinator(gateway: gateway)

        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.model.detailState, .ready)
        XCTAssertNil(coordinator.model.selectedDetail?.posterURL)
        XCTAssertNil(coordinator.model.selectedDetail?.previewURL)
    }

    func testAuthenticatedReportIsBoundToSelectedReleaseAndShowsSafeSuccess() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
        let coordinator = MarketplaceCoordinator(gateway: gateway, reportGateway: gateway)
        coordinator.model.accountState = .signedIn(userID: "test-user")
        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        try await Task.sleep(for: .milliseconds(20))

        coordinator.reportSelectedWallpaper(
            kind: .technicalIssue,
            detail: "The preview has a visible encoding artifact."
        )
        try await Task.sleep(for: .milliseconds(20))

        let reports = await gateway.recordedReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.wallpaperID, Self.wallpaperID)
        XCTAssertEqual(reports.first?.releaseID, Self.releaseID)
        XCTAssertEqual(coordinator.model.reportState, .succeeded(message: "Report submitted for review."))
    }

    func testAuthEventsReplaceSubjectAndExpireWithoutRestartingApp() async throws {
        let auth = ScriptedAuthStore()
        let coordinator = MarketplaceCoordinator(authStore: auth)
        coordinator.start()

        await auth.emit(CatalogAuthState(
            userID: "11111111-1111-4111-8111-111111111111",
            expiresAt: .now.addingTimeInterval(2)
        ))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            coordinator.model.accountState,
            .signedIn(userID: "11111111-1111-4111-8111-111111111111")
        )

        await auth.emit(CatalogAuthState(
            userID: "22222222-2222-4222-8222-222222222222",
            expiresAt: .now.addingTimeInterval(0.05)
        ))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            coordinator.model.accountState,
            .signedIn(userID: "22222222-2222-4222-8222-222222222222")
        )
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
    }

    func testReportRetryReusesIdempotencyKeyUntilReceipt() async throws {
        let gateway = ScriptedCatalogGateway(
            homeSteps: [],
            detailValue: Self.detail(),
            reportFailuresRemaining: 1
        )
        let coordinator = MarketplaceCoordinator(gateway: gateway, reportGateway: gateway)
        coordinator.model.accountState = .signedIn(userID: "test-user")
        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        try await Task.sleep(for: .milliseconds(20))

        coordinator.reportSelectedWallpaper(kind: .other, detail: "Please review this item.")
        try await Task.sleep(for: .milliseconds(20))
        coordinator.reportSelectedWallpaper(kind: .other, detail: "Please review this item.")
        try await Task.sleep(for: .milliseconds(20))

        let reports = await gateway.recordedReports()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.idempotencyKey, reports.last?.idempotencyKey)
        XCTAssertEqual(coordinator.model.reportState, .succeeded(message: "Report submitted for review."))
    }

    func testAccountProfileIsBoundToTheAuthenticatedSubject() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        let mfa = ScriptedMFAStore(userID: userID)
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth, mfaStore: mfa)
        coordinator.start()

        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.model.accountProfile?.userID, userID)
        XCTAssertEqual(coordinator.model.accountProfile?.handle, "wallpaper-maker")
        XCTAssertEqual(coordinator.model.accountProfileState, .ready)
    }

    func testReadyAccountExportCanBeSavedAndDeletionNeverClaimsEarlyCompletion() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        let mfa = ScriptedMFAStore(userID: userID)
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth, mfaStore: mfa)
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.requestAccountExport()
        try await Task.sleep(for: .milliseconds(30))
        guard case .ready = coordinator.model.accountExportState else {
            return XCTFail("Expected a ready export")
        }

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "wali-account-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        coordinator.saveAccountExport(to: destination)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            coordinator.model.accountExportState,
            .saved(fileName: destination.lastPathComponent)
        )

        coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
        try await Task.sleep(for: .milliseconds(30))
        guard case let .pending(status, identityStatus, held) = coordinator.model.accountDeletionState else {
            return XCTFail("Expected an in-progress deletion")
        }
        XCTAssertEqual(status, "Removing marketplace data")
        XCTAssertEqual(identityStatus, "Sessions revoked")
        XCTAssertFalse(held)
    }

    func testDeletionEnrollsAndVerifiesTOTPBeforeSubmitting() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        let mfa = ScriptedMFAStore(userID: userID, startsFresh: false)
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth, mfaStore: mfa)
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
        try await Task.sleep(for: .milliseconds(30))
        guard case let .mfaSetup(secret, uri, errorMessage) = coordinator.model.accountDeletionState else {
            return XCTFail("Expected TOTP enrollment before deletion")
        }
        XCTAssertEqual(secret, "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(uri.hasPrefix("otpauth://totp/"))
        XCTAssertNil(errorMessage)

        coordinator.verifyAccountDeletionMFA(code: "123456")
        try await Task.sleep(for: .milliseconds(40))
        guard case .pending = coordinator.model.accountDeletionState else {
            return XCTFail("Expected deletion only after fresh MFA")
        }
    }

    func testAcceptingCreatorTermsCompletesWithTheConfirmedServerVersion() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(userID: userID)
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .seconds(1)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.creatorContext.state, .ready)
        coordinator.acceptCreatorTerms()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.creatorContext.state, .ready)
        let acceptedVersion = await creator.acceptedVersion()
        XCTAssertEqual(acceptedVersion, "2026-09-01")
    }

    func testCreatorTermsTimeoutAlwaysLeavesTheLoadingState() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID,
            acceptanceDelay: .seconds(5)
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .milliseconds(20)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.acceptCreatorTerms()
        let reachedFailedState = await waitForCreatorState(.failed, in: coordinator)

        XCTAssertTrue(reachedFailedState)
    }

    func testCreatorTermsTimeoutDoesNotWaitForAnOperationThatIgnoresCancellation() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID,
            acceptanceDelay: .seconds(5),
            ignoresAcceptanceCancellation: true
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .milliseconds(20)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.acceptCreatorTerms()
        let reachedFailedState = await waitForCreatorState(.failed, in: coordinator)

        XCTAssertTrue(reachedFailedState)
    }

    func testCreatorTermsRemainUnacceptedUntilTheServerConfirmsTheRequestedVersion() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID,
            confirmsAcceptance: false
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .seconds(1)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.acceptCreatorTerms()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.creatorContext.state, .failed)
        let acceptedVersion = await creator.acceptedVersion()
        XCTAssertNil(acceptedVersion)
    }

    func testUnsupportedCreatorTermsVersionNeverSendsAnAcceptanceCommand() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID,
            termsVersion: "2027-01-01"
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .seconds(1)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.acceptCreatorTerms()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.creatorContext.state, .ready)
        let requestCount = await creator.acceptanceRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testAccountSwitchCannotRedirectCreatorTermsAcceptance() async throws {
        let firstUserID = "11111111-1111-4111-8111-111111111111"
        let secondUserID = "22222222-2222-4222-8222-222222222222"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: firstUserID,
            acceptanceDelay: .milliseconds(80),
            ignoresAcceptanceCancellation: true
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .seconds(1)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: firstUserID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        coordinator.acceptCreatorTerms()
        try await Task.sleep(for: .milliseconds(10))
        await creator.switchAuthenticatedSubject(to: secondUserID)
        await auth.emit(CatalogAuthState(userID: secondUserID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(120))

        let expectedSubjects = await creator.acceptanceExpectedSubjects()
        let acceptedVersion = await creator.acceptedVersion()
        XCTAssertEqual(expectedSubjects, [firstUserID])
        XCTAssertNil(acceptedVersion)
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: secondUserID))
    }

    func testMismatchedCreatorAuthorizationFailsInsteadOfRemainingLoading() async throws {
        let signedInUserID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: "22222222-2222-4222-8222-222222222222"
        )
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator,
            authStore: auth,
            creatorRequestTimeout: .seconds(1)
        )
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: signedInUserID, expiresAt: .now.addingTimeInterval(60)))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.creatorContext.state, .failed)
    }

    private func section(id: String, title: String) -> CatalogHomeSection {
        CatalogHomeSection(id: id, title: title, kind: .editorial, cursor: nil, items: [])
    }

    private static let wallpaperID = "11111111-1111-4111-8111-111111111111"
    private static let releaseID = "22222222-2222-4222-8222-222222222222"

    private static func summary(id: String, title: String) -> CatalogWallpaperSummary {
        let poster = try! CatalogArtifact(
            role: .poster,
            url: URL(string: "https://catalog.wali.example/poster-\(id)")!,
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            mediaType: "image/jpeg",
            width: 1,
            height: 1,
            durationMilliseconds: 0
        )
        let preview = try! CatalogArtifact(
            role: .preview,
            url: URL(string: "https://catalog.wali.example/preview-\(id)")!,
            sha256: String(repeating: "b", count: 64),
            byteCount: 1,
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1_000
        )
        return CatalogWallpaperSummary(
            id: id,
            slug: title.lowercased().replacingOccurrences(of: " ", with: "-"),
            title: title,
            creator: .init(
                id: "33333333-3333-4333-8333-333333333333",
                handle: "artist",
                displayName: "Artist",
                avatarURL: nil,
                verification: .verified
            ),
            contentRating: .everyone,
            primaryCategory: .init(
                id: "44444444-4444-4444-8444-444444444444",
                name: "Nature",
                slug: "nature"
            ),
            approvedTags: [],
            poster: poster,
            preview: preview,
            currentReleaseID: releaseID,
            revision: 1,
            publishedAt: .now,
            verifiedInstallCount: 0,
            favoriteCount: 0,
            saveCount: 0
        )
    }

    private static func detail() -> CatalogWallpaperDetail {
        let summary = summary(id: wallpaperID, title: "Report Test")
        return CatalogWallpaperDetail(
            summary: summary,
            description: "A test wallpaper.",
            edition: 1,
            rightsHolder: "Artist",
            attributionText: nil,
            sourceURL: nil,
            license: .init(
                code: "CC0-1.0",
                name: "CC0",
                termsURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!,
                attributionRequired: false,
                commercialUseAllowed: true,
                derivativesAllowed: true,
                redistributionAllowed: true,
                termsRevision: 1
            ),
            durationMilliseconds: 1_000,
            width: 1,
            height: 1,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            videoDefault: summary.preview,
            related: [],
            isFavorite: false,
            favoriteRevision: 0,
            isSaved: false,
            savedRevision: 0
        )
    }
}

private actor ScriptedMFAStore: AccountMFASessionProviding {
    private let userID: String
    private let startsFresh: Bool
    private var verified = false

    init(userID: String, startsFresh: Bool = true) {
        self.userID = userID
        self.startsFresh = startsFresh
    }

    func mfaStatus() async throws -> CatalogMFAStatus {
        let isFresh = startsFresh || verified
        return CatalogMFAStatus(
            subjectID: userID,
            currentLevel: isFresh ? .aal2 : .aal1,
            verifiedTOTPFactorID: startsFresh ? "44444444-4444-4444-8444-444444444444" : nil,
            latestMFAAt: isFresh ? .now : nil
        )
    }

    func beginTOTPEnrollment() async throws -> CatalogTOTPEnrollment {
        CatalogTOTPEnrollment(
            subjectID: userID,
            factorID: "55555555-5555-4555-8555-555555555555",
            secret: "JBSWY3DPEHPK3PXP",
            uri: URL(string: "otpauth://totp/WALI:test?secret=JBSWY3DPEHPK3PXP")!
        )
    }

    func verifyTOTP(factorID: String, code: String) async throws -> CatalogMFAStatus {
        guard factorID == "55555555-5555-4555-8555-555555555555", code == "123456" else {
            throw CatalogRequestError.invalidRequest
        }
        verified = true
        return try await mfaStatus()
    }

    func cancelTOTPEnrollment(factorID: String) async throws {}
}

private actor ScriptedAuthStore: CatalogAuthSessionProviding {
    private let stream: AsyncStream<CatalogAuthState?>
    private let continuation: AsyncStream<CatalogAuthState?>.Continuation

    init() {
        let pair = AsyncStream<CatalogAuthState?>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func currentState() async -> CatalogAuthState? { nil }

    func stateChanges() async -> AsyncStream<CatalogAuthState?> { stream }

    func signOut() async throws {
        continuation.yield(nil)
    }

    func emit(_ state: CatalogAuthState?) {
        continuation.yield(state)
    }
}

private actor ReceiptRecordingProbe {
    private var failures: Int
    private let retryable: Bool
    private(set) var callCount = 0

    init(failures: Int, retryable: Bool) {
        self.failures = failures
        self.retryable = retryable
    }

    func record() throws {
        callCount += 1
        if failures > 0 {
            failures -= 1
            throw CatalogRemoteError(
                code: retryable ? "temporarily_unavailable" : "install_receipt_invalid",
                safeMessage: nil,
                retryable: retryable
            )
        }
    }
}

private actor ScriptedCatalogGateway: CatalogGateway, CatalogReportGateway {
    enum HomeStep: Sendable {
        case value(CatalogHome, delay: Duration)
        case failure(CatalogRemoteError)
    }

    private var homeSteps: [HomeStep]
    private let detailValue: CatalogWallpaperDetail?
    private var reports: [CatalogReportRequest] = []
    private var reportFailuresRemaining: Int

    init(
        homeSteps: [HomeStep],
        detailValue: CatalogWallpaperDetail? = nil,
        reportFailuresRemaining: Int = 0
    ) {
        self.homeSteps = homeSteps
        self.detailValue = detailValue
        self.reportFailuresRemaining = reportFailuresRemaining
    }

    func home(locale: String, ratingCeiling: String) async throws -> CatalogHome {
        guard !homeSteps.isEmpty else {
            throw CatalogRemoteError(code: "temporarily_unavailable", safeMessage: nil, retryable: true)
        }
        let step = homeSteps.removeFirst()
        switch step {
        case let .value(value, delay):
            try? await Task.sleep(for: delay)
            return value
        case let .failure(error):
            throw error
        }
    }

    func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage {
        throw CatalogRequestError.notConfigured
    }

    func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage {
        throw CatalogRequestError.notConfigured
    }

    func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail {
        guard let detailValue, detailValue.summary.id == wallpaperID else {
            throw CatalogRequestError.notConfigured
        }
        return detailValue
    }

    func setFavorite(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        throw CatalogRequestError.notConfigured
    }

    func setSaved(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        throw CatalogRequestError.notConfigured
    }

    func requestInstall(
        wallpaperID: String,
        releaseID: String,
        expectedWallpaperRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInstallGrant {
        throw CatalogRequestError.notConfigured
    }

    func recordInstall(
        receipt: String,
        manifestDigest: String,
        releaseID: String,
        idempotencyKey: String
    ) async throws {
        throw CatalogRequestError.notConfigured
    }

    func report(_ request: CatalogReportRequest) async throws -> CatalogReportReceipt {
        reports.append(request)
        if reportFailuresRemaining > 0 {
            reportFailuresRemaining -= 1
            throw CatalogRemoteError(code: "temporarily_unavailable", safeMessage: nil, retryable: true)
        }
        return CatalogReportReceipt(id: UUID().uuidString.lowercased(), status: "open", createdAt: .now)
    }

    func recordedReports() -> [CatalogReportRequest] {
        reports
    }
}

private actor ScriptedAccountPrivacyGateway: AccountPrivacyGateway {
    private let userID: String

    init(userID: String) {
        self.userID = userID
    }

    func accountProfile() async throws -> MarketplaceAccountProfile {
        try MarketplaceAccountProfile(
            id: userID,
            handle: "wallpaper-maker",
            displayName: "Wallpaper Maker",
            status: "active",
            revision: 4
        )
    }

    func requestAccountExport(idempotencyKey: String) async throws -> AccountExportSnapshot {
        try AccountExportSnapshot(
            id: "22222222-2222-4222-8222-222222222222",
            subjectID: userID,
            status: .ready,
            expiresAt: .now.addingTimeInterval(3_600),
            completedAt: .now,
            byteCount: 2,
            sha256: String(repeating: "a", count: 64),
            downloadURL: URL(string: "https://catalog.wali.example/export")!,
            downloadExpiresAt: .now.addingTimeInterval(300)
        )
    }

    func accountExportStatus(id: String, idempotencyKey: String) async throws -> AccountExportSnapshot {
        try await requestAccountExport(idempotencyKey: idempotencyKey)
    }

    func saveAccountExport(_ snapshot: AccountExportSnapshot, to destination: URL) async throws {
        try Data("{}".utf8).write(to: destination, options: .withoutOverwriting)
    }

    func requestAccountDeletion(
        expectedProfileRevision: UInt64,
        confirmation: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionSnapshot {
        guard expectedProfileRevision == 4, confirmation == "DELETE MY WALI" else {
            throw CatalogRequestError.invalidRequest
        }
        return try AccountDeletionSnapshot(
            id: "33333333-3333-4333-8333-333333333333",
            subjectID: userID,
            status: .processing,
            identityStatus: .sessionsRevoked,
            revision: 1,
            requestedAt: .now,
            completedAt: nil,
            held: false
        )
    }

    func accountDeletionStatus(id: String, idempotencyKey: String) async throws -> AccountDeletionSnapshot {
        try await requestAccountDeletion(
            expectedProfileRevision: 4,
            confirmation: "DELETE MY WALI",
            idempotencyKey: idempotencyKey
        )
    }
}

private actor ScriptedCreatorAuthorizationGateway: CreatorAuthorizationGateway {
    private var authenticatedSubjectID: String
    private let termsVersion: String
    private let acceptanceDelay: Duration
    private let ignoresAcceptanceCancellation: Bool
    private let confirmsAcceptance: Bool
    private var accepted: String?
    private var acceptanceRequests = 0
    private var expectedSubjects: [String] = []

    init(
        userID: String,
        termsVersion: String = "2026-09-01",
        acceptanceDelay: Duration = .zero,
        ignoresAcceptanceCancellation: Bool = false,
        confirmsAcceptance: Bool = true
    ) {
        authenticatedSubjectID = userID
        self.termsVersion = termsVersion
        self.acceptanceDelay = acceptanceDelay
        self.ignoresAcceptanceCancellation = ignoresAcceptanceCancellation
        self.confirmsAcceptance = confirmsAcceptance
    }

    func authorizationSnapshot() async throws -> CreatorAuthorizationSnapshot {
        snapshot(subjectID: authenticatedSubjectID, acceptedVersion: accepted)
    }

    func creatorMetadata() async throws -> CreatorMetadata {
        try CreatorMetadata(
            categories: [CreatorTaxonomyOption(id: UUID(), name: "Nature", slug: "nature")],
            tags: [],
            licenses: [CreatorLicenseOption(
                id: UUID(),
                name: "Original work",
                code: "original",
                requirements: CreatorRightsRequirements(
                    requiresSourceURL: false,
                    requiresAttribution: false,
                    requiresProof: false
                )
            )],
            currentCreatorTermsVersion: termsVersion
        )
    }

    func acceptCreatorTerms(
        expectedSubjectID: String,
        version: String,
        idempotencyKey: String
    ) async throws -> CreatorAuthorizationSnapshot {
        acceptanceRequests += 1
        expectedSubjects.append(expectedSubjectID)
        if ignoresAcceptanceCancellation {
            await withCheckedContinuation { continuation in
                Task {
                    try? await Task.sleep(for: acceptanceDelay)
                    continuation.resume()
                }
            }
        } else {
            try await Task.sleep(for: acceptanceDelay)
        }
        guard expectedSubjectID == authenticatedSubjectID,
              version == termsVersion,
              UUID(uuidString: idempotencyKey) != nil
        else {
            throw CatalogRequestError.invalidRequest
        }
        if confirmsAcceptance {
            accepted = version
        }
        return snapshot(subjectID: authenticatedSubjectID, acceptedVersion: accepted)
    }

    func acceptedVersion() -> String? { accepted }

    func acceptanceRequestCount() -> Int { acceptanceRequests }

    func acceptanceExpectedSubjects() -> [String] { expectedSubjects }

    func switchAuthenticatedSubject(to subjectID: String) {
        authenticatedSubjectID = subjectID
        accepted = nil
    }

    private func snapshot(
        subjectID: String,
        acceptedVersion: String?
    ) -> CreatorAuthorizationSnapshot {
        CreatorAuthorizationSnapshot(
            subjectID: subjectID,
            accountIsActive: true,
            sessionExpiresAt: .now.addingTimeInterval(60),
            creatorGrantRevision: acceptedVersion == nil ? nil : 1,
            acceptedCreatorTermsVersion: acceptedVersion,
            currentCreatorTermsVersion: termsVersion,
            moderatorGrantRevision: nil,
            assuranceLevel: .aal1
        )
    }
}
