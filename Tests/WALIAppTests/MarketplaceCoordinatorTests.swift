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

    func testSearchPreservesTheSelectedBrowseCategoryAndTags() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [])
        let coordinator = MarketplaceCoordinator(gateway: gateway)
        coordinator.loadBrowse(category: "nature", tags: ["calm"], sort: .newest)
        coordinator.search("forest")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await gateway.searchRequests.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = await gateway.searchRequests.last
        XCTAssertEqual(request?.category, "nature")
        XCTAssertEqual(request?.tags, ["calm"])
        XCTAssertEqual(request?.sort, .newest)
        coordinator.stop()
    }

    func testSigningOutClearsPrivateDetailInteractionState() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
        let auth = ScriptedAuthStore()
        let coordinator = MarketplaceCoordinator(gateway: gateway, authStore: auth)
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: "11111111-1111-4111-8111-111111111111", expiresAt: .now.addingTimeInterval(60)))
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.accountState == .signedOut, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.detailState == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(coordinator.model.selectedDetail)
        await auth.emit(nil)
        deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.accountState != .signedOut, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(coordinator.model.selectedDetail)
        coordinator.stop()
    }

    func testSavedPaginationAndAccountSwitchKeepOwnerStateSeparate() async throws {
        let first = Self.summary(id: Self.wallpaperID, title: "First")
        let second = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2", title: "Second")
        let otherOwner = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3", title: "Other account bookmark")
        let gateway = ScriptedCatalogGateway(homeSteps: [], savedPages: [
            .init(items: [first], nextCursor: "saved-page-2"), .init(items: [first, second], nextCursor: nil),
            .init(items: [otherOwner], nextCursor: nil)
        ])
        let auth = ScriptedAuthStore()
        let coordinator = MarketplaceCoordinator(gateway: gateway, authStore: auth)
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: "11111111-1111-4111-8111-111111111111", expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountState != .signedOut }
        coordinator.loadSavedWallpapers()
        await assertEmailEventually { coordinator.discovery.savedState == .ready }
        coordinator.loadSavedWallpapers(loadMore: true)
        await assertEmailEventually { coordinator.discovery.savedItems.count == 2 }
        XCTAssertEqual(coordinator.discovery.savedItems.map(\.id), [first.id, second.id])
        let cursors = await gateway.savedCursors
        XCTAssertEqual(cursors, [nil, "saved-page-2"])
        await auth.emit(CatalogAuthState(userID: "22222222-2222-4222-8222-222222222222", expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountState == .signedIn(userID: "22222222-2222-4222-8222-222222222222") }
        await assertEmailEventually { coordinator.discovery.savedItems.map(\.id) == [otherOwner.id] }
        XCTAssertEqual(coordinator.discovery.savedState, .ready)
        XCTAssertNil(coordinator.discovery.savedNextCursor)
        coordinator.stop()
    }

    func testAcknowledgementRetryOnlyRunsForItsOriginalSignedInSubject() async throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let store = CatalogInstallAcknowledgementStore()
        let entry = try CatalogInstallAcknowledgement(subjectID: first, wallpaperID: Self.wallpaperID,
            releaseID: Self.releaseID, receipt: "33333333-3333-4333-8333-333333333333", manifestDigest: String(repeating: "a", count: 64),
            idempotencyKey: "record_recovery_test_0001", expiresAt: .now.addingTimeInterval(300))
        try await store.enqueue(entry)
        let gateway = ScriptedCatalogGateway(homeSteps: [], recordingSucceeds: true)
        let coordinator = MarketplaceCoordinator(gateway: gateway, installAcknowledgementStore: store)
        coordinator.model.accountState = .signedIn(userID: second)
        coordinator.retryInstallRecording()
        await assertEmailEventually { !coordinator.discovery.isRetryingInstallRecord }
        let before = await gateway.recordedKeys
        XCTAssertTrue(before.isEmpty)
        coordinator.model.accountState = .signedIn(userID: first)
        coordinator.retryInstallRecording()
        await assertEmailEventually { await gateway.recordedKeys.count == 1 }
        await assertEmailEventually { !coordinator.discovery.isRetryingInstallRecord }
        let keys = await gateway.recordedKeys
        XCTAssertEqual(keys, [entry.idempotencyKey])
        let remaining = try await store.pending(subjectID: first)
        XCTAssertTrue(remaining.isEmpty)
        coordinator.stop()
    }

    func testAcknowledgementEnqueuedDuringRecordingDrainsWithoutAnotherRefresh() async throws {
        let subject = "11111111-1111-4111-8111-111111111111"
        let store = CatalogInstallAcknowledgementStore()
        let first = try CatalogInstallAcknowledgement(subjectID: subject, wallpaperID: Self.wallpaperID,
            releaseID: Self.releaseID, receipt: "33333333-3333-4333-8333-333333333333", manifestDigest: String(repeating: "a", count: 64),
            idempotencyKey: "record_concurrent_test_0001", expiresAt: .now.addingTimeInterval(300))
        let second = try CatalogInstallAcknowledgement(subjectID: subject, wallpaperID: Self.wallpaperID,
            releaseID: Self.releaseID, receipt: "44444444-4444-4444-8444-444444444444", manifestDigest: String(repeating: "b", count: 64),
            idempotencyKey: "record_concurrent_test_0002", expiresAt: .now.addingTimeInterval(300))
        try await store.enqueue(first)
        let gateway = ScriptedCatalogGateway(homeSteps: [], recordingSucceeds: true, holdFirstRecord: true)
        let coordinator = MarketplaceCoordinator(gateway: gateway, installAcknowledgementStore: store)
        coordinator.model.accountState = .signedIn(userID: subject)
        coordinator.retryInstallRecording()
        await assertEmailEventually { await gateway.recordedKeys.count == 1 }
        try await store.enqueue(second)
        coordinator.retryInstallRecording()
        await gateway.releaseFirstRecord()
        await assertEmailEventually { await gateway.recordedKeys.count == 2 }
        await assertEmailEventually { !coordinator.discovery.isRetryingInstallRecord }
        let keys = await gateway.recordedKeys
        XCTAssertEqual(keys, [first.idempotencyKey, second.idempotencyKey])
        let remaining = try await store.pending(subjectID: subject)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(coordinator.discovery.canRetryInstallRecord)
        coordinator.stop()
    }

    func testTwoConfiguredWindowsPreserveEachOthersPendingAcknowledgements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WALI-Windows-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Fixture.bundle/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let bundleID = "private.wali.acknowledgement-test." + UUID().uuidString
        let projectURL = URL(string: "https://example.supabase.co")!
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundlePackageType": "BNDL",
            "WALIMarketplaceEnabled": "YES", "WALIAuthenticationMethod": "native_apple",
            "WALIMarketplaceURL": projectURL.absoluteString, "WALIMarketplacePublishableKey": "public-test-key",
            "WALIApprovedCDNHosts": "catalog.wali.example", "WALICatalogSigningKeyID": "test-key",
            "WALICatalogSigningPublicKeyBase64": Data(repeating: 1, count: 32).base64EncodedString()
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let fileURL = try CatalogInstallAcknowledgementStore.defaultURL(bundleIdentifier: bundleID, projectURL: projectURL)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }
        let services = try XCTUnwrap(MarketplaceForegroundServices(bundle: bundle))
        let firstWindow = MarketplaceCoordinator.configured(services: services, bundle: bundle)
        let secondWindow = MarketplaceCoordinator.configured(services: services, bundle: bundle)
        let subject = "11111111-1111-4111-8111-111111111111"
        _ = try await firstWindow.installAcknowledgementStore.pending(subjectID: subject)
        _ = try await secondWindow.installAcknowledgementStore.pending(subjectID: subject)
        let first = try CatalogInstallAcknowledgement(subjectID: subject, wallpaperID: Self.wallpaperID,
            releaseID: Self.releaseID, receipt: "33333333-3333-4333-8333-333333333333", manifestDigest: String(repeating: "a", count: 64),
            idempotencyKey: "record_window_test_0001", expiresAt: .now.addingTimeInterval(300))
        let second = try CatalogInstallAcknowledgement(subjectID: subject, wallpaperID: Self.wallpaperID,
            releaseID: Self.releaseID, receipt: "44444444-4444-4444-8444-444444444444", manifestDigest: String(repeating: "b", count: 64),
            idempotencyKey: "record_window_test_0002", expiresAt: .now.addingTimeInterval(300))
        try await firstWindow.installAcknowledgementStore.enqueue(first)
        try await secondWindow.installAcknowledgementStore.enqueue(second)
        try await firstWindow.installAcknowledgementStore.remove(first)
        let restored = try await CatalogInstallAcknowledgementStore(fileURL: fileURL).pending(subjectID: subject)
        XCTAssertEqual(restored, [second], "Completing one window's install must preserve another window's durable confirmation")
        firstWindow.stop()
        secondWindow.stop()
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

    func testUnavailableFactoryRejectsSignInWithoutSuggestingARelaunch() throws {
        for enabled in ["NO", "YES"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WALI-Marketplace-Availability-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundleURL = root.appendingPathComponent("Unavailable.bundle")
            let contents = bundleURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "private.wali.marketplace-availability." + UUID().uuidString,
                "CFBundlePackageType": "BNDL",
                "WALIMarketplaceEnabled": enabled,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
            let bundle = try XCTUnwrap(Bundle(url: bundleURL))
            let coordinator = MarketplaceCoordinator.configured(bundle: bundle)
            XCTAssertFalse(coordinator.isMarketplaceAvailable)
            XCTAssertFalse(coordinator.canShowCreatorTools)
            XCTAssertFalse(coordinator.canShowModeratorTools)

            coordinator.signIn()

            XCTAssertEqual(
                coordinator.model.authenticationState,
                .failed(message: "Marketplace accounts are unavailable in this build. Your local wallpapers remain available in Library."),
                "Disabled and incomplete configurations must not suggest retrying native Apple sign-in"
            )
        }
    }

    func testUnavailableCoordinatorBlocksStaleAccountAndCatalogActions() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
        let populated = MarketplaceCoordinator(gateway: gateway)
        populated.loadDetail(wallpaperID: Self.wallpaperID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while populated.model.detailState == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(populated.model.detailState, .ready)
        XCTAssertNotNil(populated.model.selectedDetail)
        populated.stop()
        let auth = ScriptedAuthStore()
        let coordinator = MarketplaceCoordinator(
            model: populated.model,
            isMarketplaceAvailable: false,
            gateway: gateway,
            reportGateway: gateway,
            authStore: auth
        )
        coordinator.model.accountState = .signedIn(userID: "stale-subject")
        coordinator.model.authenticationState = .working

        coordinator.signIn()
        XCTAssertEqual(coordinator.model.authenticationState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        coordinator.toggleFavorite()
        coordinator.toggleSaved()
        coordinator.installSelectedWallpaper()
        coordinator.retryCatalogInstall()
        coordinator.reportSelectedWallpaper(kind: .technicalIssue, detail: "A stale catalog detail must not submit a report.")
        coordinator.signOut()

        XCTAssertEqual(coordinator.model.actionState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        XCTAssertEqual(coordinator.model.reportState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        XCTAssertEqual(coordinator.model.authenticationState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        XCTAssertFalse(coordinator.canShowCreatorTools)
        XCTAssertFalse(coordinator.canShowModeratorTools)
        XCTAssertNil(coordinator.moderatorAccess)
        let mutations = await gateway.interactionCallCount
        let reports = await gateway.recordedReports()
        let signOutCalls = await auth.signOutCallCount
        XCTAssertEqual(mutations, 0)
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(signOutCalls, 0)
    }

    func testUnavailableCoordinatorRejectsDeferredSignedOutAuthentication() {
        let coordinator = MarketplaceCoordinator(isMarketplaceAvailable: false)

        coordinator.toggleFavorite()
        coordinator.toggleSaved()
        coordinator.installSelectedWallpaper()
        coordinator.reportSelectedWallpaper(kind: .technicalIssue, detail: "Unavailable report")

        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(coordinator.model.authenticationState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        XCTAssertEqual(coordinator.model.actionState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
        XCTAssertEqual(coordinator.model.reportState, .failed(message: MarketplaceCoordinator.unavailableAccountMessage))
    }

    func testConfiguredEmptyCatalogKeepsMarketplaceAvailable() async throws {
        let gateway = ScriptedCatalogGateway(homeSteps: [.value(CatalogHome(sections: []), delay: .zero)])
        let coordinator = MarketplaceCoordinator(gateway: gateway)
        coordinator.loadHome()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.homeState == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(coordinator.isMarketplaceAvailable)
        XCTAssertEqual(coordinator.model.homeState, .empty)
        XCTAssertFalse(coordinator.canShowCreatorTools)
        coordinator.model.accountState = .signedIn(userID: "configured-subject")
        XCTAssertTrue(coordinator.canShowCreatorTools)
        coordinator.stop()
    }

    func testHomeWithOnlyEmptySectionsShowsTheEmptyCatalog() async throws {
        let home = CatalogHome(sections: [
            section(id: "trending", title: "Trending"),
            section(id: "new", title: "New"),
        ])
        let coordinator = MarketplaceCoordinator(
            gateway: ScriptedCatalogGateway(homeSteps: [.value(home, delay: .zero)])
        )
        defer { coordinator.stop() }

        coordinator.loadHome()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while coordinator.model.homeState == .loading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.model.homeState, .empty)
        XCTAssertTrue(coordinator.model.homeSections.isEmpty)
    }

    func testInjectedCatalogWithoutGatewayRemainsEmpty() {
        let coordinator = MarketplaceCoordinator()

        coordinator.loadHome()

        XCTAssertEqual(coordinator.model.homeState, .empty)
        XCTAssertTrue(coordinator.model.homeSections.isEmpty)
    }

    func testNewerHomeRequestWinsWhenAnOlderRequestFinishesLater() async throws {
        let oldHome = CatalogHome(sections: [section(id: "old", title: "Old", items: [Self.summary(id: Self.wallpaperID, title: "Wallpaper")])])
        let newHome = CatalogHome(sections: [section(id: "new", title: "New", items: [Self.summary(id: Self.wallpaperID, title: "Wallpaper")])])
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
        XCTAssertEqual(coordinator.model.homeSections.map(\.id), [WALIDiscoverLayout.heroSectionID, "new"])
    }

    func testDiscoverHomeCarouselCollectsUniqueItemsFromEverySection() async throws {
        let rick = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", title: "Rick")
        let aurora = Self.summary(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2", title: "Aurora")
        let home = CatalogHome(sections: [
            section(id: "empty", title: "Empty"),
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
        XCTAssertTrue(coordinator.isMarketplaceAvailable)
        coordinator.start()

        func waitForSubject(_ expectedUserID: String?) async -> Bool {
            func matches() -> Bool {
                switch coordinator.model.accountState {
                case let .signedIn(userID): userID == expectedUserID
                case .signedOut: expectedUserID == nil
                }
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while !matches(), clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return matches()
        }

        let firstUserID = "11111111-1111-4111-8111-111111111111"
        let secondUserID = "22222222-2222-4222-8222-222222222222"
        await auth.emit(CatalogAuthState(
            userID: firstUserID,
            expiresAt: .now.addingTimeInterval(60)
        ))
        let receivedFirstSubject = await waitForSubject(firstUserID)
        guard receivedFirstSubject else {
            XCTFail("The initial auth event did not reach the account model")
            return
        }

        await auth.emit(CatalogAuthState(
            userID: secondUserID,
            expiresAt: .now.addingTimeInterval(60)
        ))
        let receivedSecondSubject = await waitForSubject(secondUserID)
        guard receivedSecondSubject else {
            XCTFail("The replacement auth event did not reach the account model")
            return
        }

        // Confirm the subject before shortening its session. Observing sign-in
        // must not depend on resuming within a 50 ms token lifetime.
        await auth.emit(CatalogAuthState(
            userID: secondUserID,
            expiresAt: .now.addingTimeInterval(0.05)
        ))
        let expiredWithoutAnotherAuthEvent = await waitForSubject(nil)
        XCTAssertTrue(
            expiredWithoutAnotherAuthEvent,
            "The account must expire without a sign-out event or app restart"
        )
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
        await assertEmailEventually { coordinator.model.accountState == .signedOut }
        XCTAssertEqual(coordinator.model.authenticationState, .succeeded(message:
            "Deletion requested. Your account is signed out; deletion is still pending."))
    }

    func testAcceptedDeletionSignsOutWithoutPollingRevokedSession() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth,
            mfaStore: ScriptedMFAStore(userID: userID))
        coordinator.start()
        defer { coordinator.stop() }
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountProfile?.userID == userID }

        coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
        await assertEmailEventually {
            coordinator.model.authenticationState == .succeeded(message:
                "Deletion requested. Your account is signed out; deletion is still pending.")
        }
        let signOutCalls = await auth.signOutCallCount
        XCTAssertEqual(signOutCalls, 1)

        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertNil(coordinator.model.accountProfile)
        XCTAssertEqual(coordinator.model.accountDeletionState, .idle)
        XCTAssertEqual(coordinator.model.authenticationState, .succeeded(message:
            "Deletion requested. Your account is signed out; deletion is still pending."))
        coordinator.refreshAccountDeletion()
        let statusCalls = await privacy.deletionStatusCount
        XCTAssertEqual(statusCalls, 0)
    }

    func testLateDeletionResponseCannotSignOutAnotherAccount() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let otherID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let auth = ScriptedAuthStore()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        await privacy.pauseDeletionResponse()
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth,
            mfaStore: ScriptedMFAStore(userID: userID))
        coordinator.start()
        defer { coordinator.stop() }
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountProfile?.userID == userID }
        coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
        await assertEmailEventually { await privacy.isDeletionResponseHeld }
        await privacy.setProfileSubject(otherID)
        await auth.emit(CatalogAuthState(userID: otherID, expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountProfile?.userID == otherID }
        await privacy.resumeDeletionResponse()
        await assertEmailEventually { await privacy.deletionResponseCount == 1 }
        let signOutCalls = await auth.signOutCallCount
        XCTAssertEqual(signOutCalls, 0)
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: otherID))
        XCTAssertEqual(coordinator.model.accountDeletionState, .idle)
    }

    func testLateDeletionSignOutCompletionCannotClearNewAccount() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let otherID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let auth = ScriptedAuthStore()
        await auth.pauseSignOutCompletion()
        let privacy = ScriptedAccountPrivacyGateway(userID: userID)
        let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth,
            mfaStore: ScriptedMFAStore(userID: userID))
        coordinator.start()
        defer { coordinator.stop() }
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountProfile?.userID == userID }
        coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
        await assertEmailEventually { await auth.isSignOutHeld }
        await assertEmailEventually { coordinator.model.accountState == .signedOut }
        await privacy.setProfileSubject(otherID)
        await auth.emit(CatalogAuthState(userID: otherID, expiresAt: .now.addingTimeInterval(60)))
        await assertEmailEventually { coordinator.model.accountProfile?.userID == otherID }
        await auth.resumeSignOutCompletion()
        await assertEmailEventually { await auth.signOutReturnCount == 1 }
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: otherID))
        XCTAssertEqual(coordinator.model.authenticationState, .idle)
        let current = await auth.currentState()
        XCTAssertEqual(current?.userID, otherID)
    }

    func testRevokedDeletionStatusAlwaysClearsSessionWithoutChangingOutcome() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let outcomes: [(AccountDeletionStatus, String)] = [
            (.failed, "Deletion did not complete. Your account is signed out."),
            (.cancelled, "Deletion was cancelled. Your account is signed out."),
            (.held, "Deletion is on hold. Your account is signed out."),
            (.completed, "Account deletion completed. Your account is signed out.")
        ]
        for (status, notice) in outcomes {
            let auth = ScriptedAuthStore()
            let privacy = ScriptedAccountPrivacyGateway(userID: userID)
            await privacy.setDeletionStatusScenario(status)
            let coordinator = MarketplaceCoordinator(accountGateway: privacy, authStore: auth,
                mfaStore: ScriptedMFAStore(userID: userID))
            coordinator.start()
            await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
            await assertEmailEventually { coordinator.model.accountProfile?.userID == userID }
            coordinator.requestAccountDeletion(confirmation: "DELETE MY WALI")
            await assertEmailEventually {
                if case .pending = coordinator.model.accountDeletionState { return true }
                return false
            }
            coordinator.refreshAccountDeletion()
            await assertEmailEventually { coordinator.model.authenticationState == .succeeded(message: notice) }
            XCTAssertEqual(coordinator.model.accountState, .signedOut)
            XCTAssertNil(coordinator.model.accountProfile)
            let statusCalls = await privacy.deletionStatusCount
            XCTAssertEqual(statusCalls, 1)
            coordinator.stop()
        }
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
        await assertEmailEventually { coordinator.model.accountState == .signedOut }
        let requestCount = await privacy.deletionRequestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinator.model.authenticationState, .succeeded(message:
            "Deletion requested. Your account is signed out; deletion is still pending."))
    }

    func testCreatorUnavailableRequestCanRetryWithoutRequestingSignInOrAcceptingTerms() async {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID, termsVersion: "", authorizationFailuresRemaining: 1
        )
        let coordinator = MarketplaceCoordinator(creatorAuthorizationGateway: creator, authStore: auth)
        defer { coordinator.stop() }
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .signedOut)

        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        let failed = await waitForCreatorState(.failed, in: coordinator)
        XCTAssertTrue(failed)
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: userID))
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .failed)

        coordinator.refreshAccountPrivacy()
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .loading)
        let ready = await waitForCreatorState(.ready, in: coordinator)
        XCTAssertTrue(ready)
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: userID))
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .notConfigured)
        XCTAssertNil(coordinator.creatorContext.metadata)
        let authorizationRequests = await creator.authorizationRequests
        let metadataRequests = await creator.metadataRequestCount()
        let acceptanceRequests = await creator.acceptanceRequestCount()
        XCTAssertEqual(authorizationRequests, 2)
        XCTAssertEqual(metadataRequests, 0)
        XCTAssertEqual(acceptanceRequests, 0)

        await auth.emit(nil)
        let cleared = await waitForCreatorState(.idle, in: coordinator)
        XCTAssertTrue(cleared)
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .signedOut)
    }

    func testUnavailableCreatorTermsPermitStaffMFAWithoutCreatorMetadataOrDeletion() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let mfa = ScriptedMFAStore(userID: userID, startsFresh: false)
        let account = ScriptedAccountPrivacyGateway(userID: userID)
        let creator = ScriptedCreatorAuthorizationGateway(
            userID: userID, termsVersion: "", moderatorGrantRevision: 7, mfaStore: mfa
        )
        let moderation = StaffModerationMetadataProbe()
        let coordinator = MarketplaceCoordinator(
            accountGateway: account, creatorAuthorizationGateway: creator,
            moderationGateway: moderation, authStore: auth, mfaStore: mfa
        )
        defer { coordinator.stop() }
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        let ready = await waitForCreatorState(.ready, in: coordinator)
        XCTAssertTrue(ready)
        await assertEmailEventually { coordinator.model.accountProfile != nil }
        let initial = try XCTUnwrap(coordinator.creatorContext.moderationModel?.authorization)
        XCTAssertEqual(initial.moderatorGrantRevision, 7)
        XCTAssertFalse(initial.canAccessCreatorStudio())
        XCTAssertFalse(initial.canAccessModeration())
        XCTAssertNil(coordinator.creatorContext.metadata)
        XCTAssertFalse(coordinator.canShowModeratorTools)
        let initialMetadataRequests = await creator.metadataRequestCount()
        let initialModerationRequests = await moderation.metadataRequests
        XCTAssertEqual(initialMetadataRequests, 0)
        XCTAssertEqual(initialModerationRequests, 0)

        coordinator.acceptCreatorTerms()
        let access = try XCTUnwrap(coordinator.moderatorAccess)
        access.begin(subjectID: userID)
        await assertEmailEventually {
            if case .setup = access.state { return true }
            return false
        }
        access.verify(code: "123456")
        await assertEmailEventually { coordinator.canShowModeratorTools }
        let verified = try XCTUnwrap(coordinator.creatorContext.moderationModel?.authorization)
        XCTAssertTrue(verified.canAccessModeration())
        XCTAssertFalse(verified.canAccessCreatorStudio())
        XCTAssertNil(coordinator.creatorContext.metadata)
        let metadataRequests = await creator.metadataRequestCount()
        let acceptanceRequests = await creator.acceptanceRequestCount()
        let moderationRequests = await moderation.metadataRequests
        let deletionRequests = await account.deletionRequestCount
        XCTAssertEqual(metadataRequests, 0)
        XCTAssertEqual(acceptanceRequests, 0)
        XCTAssertEqual(moderationRequests, 1)
        XCTAssertEqual(deletionRequests, 0)
    }

    func testUnavailableCreatorTermsDoNotGrantOrdinaryAccountReviewAccess() async {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(userID: userID, termsVersion: "")
        let moderation = StaffModerationMetadataProbe()
        let coordinator = MarketplaceCoordinator(
            creatorAuthorizationGateway: creator, moderationGateway: moderation, authStore: auth
        )
        defer { coordinator.stop() }
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        let ready = await waitForCreatorState(.ready, in: coordinator)
        XCTAssertTrue(ready)
        XCTAssertEqual(coordinator.creatorStudioUnavailableReason, .notConfigured)
        XCTAssertNil(coordinator.creatorContext.moderationModel?.authorization.moderatorGrantRevision)
        XCTAssertFalse(coordinator.canShowModeratorTools)
        XCTAssertFalse(coordinator.creatorContext.moderationModel?.authorization.canAccessCreatorStudio() ?? true)
        let creatorRequests = await creator.metadataRequestCount()
        let moderationRequests = await moderation.metadataRequests
        XCTAssertEqual(creatorRequests, 0)
        XCTAssertEqual(moderationRequests, 0)
    }

    func testAvailableCreatorTermsStillRequireMatchingMetadataVersion() async {
        let userID = "11111111-1111-4111-8111-111111111111"
        let auth = ScriptedAuthStore()
        let creator = ScriptedCreatorAuthorizationGateway(userID: userID, metadataVersion: "2026-08-01")
        let coordinator = MarketplaceCoordinator(creatorAuthorizationGateway: creator, authStore: auth)
        defer { coordinator.stop() }
        coordinator.start()
        await auth.emit(CatalogAuthState(userID: userID, expiresAt: .now.addingTimeInterval(60)))
        let failed = await waitForCreatorState(.failed, in: coordinator)
        XCTAssertTrue(failed)
        XCTAssertNil(coordinator.creatorContext.metadata)
        let metadataRequests = await creator.metadataRequestCount()
        XCTAssertEqual(metadataRequests, 1)
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
        XCTAssertEqual(acceptedVersion, "2026-09-12")
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

    private func section(
        id: String,
        title: String,
        items: [CatalogWallpaperSummary] = []
    ) -> CatalogHomeSection {
        CatalogHomeSection(id: id, title: title, kind: .editorial, cursor: nil, items: items)
    }

    func testEmailAuthenticationResumesFavoriteAndSavedOnlyAfterAdmission() async {
        for saved in [false, true] {
            let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
            let auth = EmailAuthProbe()
            let coordinator = MarketplaceCoordinator(
                authenticationMethod: .emailOTP, gateway: gateway, authStore: auth, emailAuth: auth
            )
            coordinator.loadDetail(wallpaperID: Self.wallpaperID)
            await assertEmailEventually { coordinator.model.detailState == .ready }
            if saved { coordinator.toggleSaved() } else { coordinator.toggleFavorite() }
            coordinator.emailSignIn.email = "person@example.test"
            coordinator.requestEmailCode()
            await assertEmailEventually { coordinator.emailSignIn.phase == .code }
            coordinator.emailSignIn.code = "123456"
            coordinator.verifyEmailCode()
            await assertEmailEventually { auth.hasPendingVerification }
            await auth.commitAdmission()
            let before = await gateway.interactionCallCount
            XCTAssertEqual(before, 0)
            auth.completeVerification()
            await assertEmailEventually { await gateway.interactionCallCount == 1 }
            XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: auth.accepted.userID))
            coordinator.stop()
        }
    }

    func testEmailAuthenticationResumesReportForItsOriginalRelease() async {
        let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
        let auth = EmailAuthProbe()
        let coordinator = MarketplaceCoordinator(
            authenticationMethod: .emailOTP, gateway: gateway, reportGateway: gateway,
            authStore: auth, emailAuth: auth
        )
        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        await assertEmailEventually { coordinator.model.detailState == .ready }
        coordinator.reportSelectedWallpaper(kind: .technicalIssue, detail: "Video playback needs review.")
        coordinator.emailSignIn.email = "person@example.test"
        coordinator.requestEmailCode()
        await assertEmailEventually { coordinator.emailSignIn.phase == .code }
        coordinator.emailSignIn.code = "123456"
        coordinator.verifyEmailCode()
        await assertEmailEventually { auth.hasPendingVerification }
        await auth.commitAdmission()
        let before = await gateway.recordedReports()
        XCTAssertTrue(before.isEmpty)
        auth.completeVerification()
        await assertEmailEventually { await gateway.recordedReports().count == 1 }
        let reports = await gateway.recordedReports()
        XCTAssertEqual(reports.first?.wallpaperID, Self.wallpaperID)
        XCTAssertEqual(reports.first?.releaseID, Self.detail().summary.currentReleaseID)
        coordinator.stop()
    }

    func testEmailAdmissionCannotResumeAfterDetailLeavesOrWindowCloses() async {
        for closesWindow in [false, true] {
            let gateway = ScriptedCatalogGateway(homeSteps: [], detailValue: Self.detail())
            let auth = EmailAuthProbe()
            let coordinator = MarketplaceCoordinator(
                authenticationMethod: .emailOTP, gateway: gateway, authStore: auth, emailAuth: auth
            )
            coordinator.loadDetail(wallpaperID: Self.wallpaperID)
            await assertEmailEventually { coordinator.model.detailState == .ready }
            coordinator.toggleFavorite()
            coordinator.emailSignIn.email = "person@example.test"
            coordinator.requestEmailCode()
            await assertEmailEventually { coordinator.emailSignIn.phase == .code }
            coordinator.emailSignIn.code = "123456"
            coordinator.verifyEmailCode()
            await assertEmailEventually { auth.hasPendingVerification }
            await auth.commitAdmission()
            if closesWindow { coordinator.stop() }
            else { coordinator.cancelDetail(wallpaperID: Self.wallpaperID) }
            auth.completeVerification()
            await assertEmailEventually { !coordinator.emailSignIn.isPresented && auth.completedVerifications == 1 }
            let calls = await gateway.interactionCallCount
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(coordinator.model.actionState, .idle, "No deferred mutation may even be queued")
            XCTAssertEqual(auth.signOutCalls, 0)
            coordinator.stop()
        }
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
            videoDefault: summary.preview!,
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
    private(set) var signOutCallCount = 0
    private var state: CatalogAuthState?
    private var holdSignOutCompletion = false
    private var signOutContinuation: CheckedContinuation<Void, Never>?
    private(set) var signOutReturnCount = 0
    var isSignOutHeld: Bool { signOutContinuation != nil }
    func pauseSignOutCompletion() { holdSignOutCompletion = true }
    func resumeSignOutCompletion() {
        signOutContinuation?.resume()
        signOutContinuation = nil
    }
    private let stream: AsyncStream<CatalogAuthState?>
    private let continuation: AsyncStream<CatalogAuthState?>.Continuation

    init() {
        let pair = AsyncStream<CatalogAuthState?>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func currentState() async -> CatalogAuthState? { state }

    func stateChanges() async -> AsyncStream<CatalogAuthState?> { stream }

    func signOut() async throws {
        signOutCallCount += 1
        state = nil
        continuation.yield(nil)
        if holdSignOutCompletion { await withCheckedContinuation { signOutContinuation = $0 } }
        signOutReturnCount += 1
    }

    func signOut(expectedSubjectID: String) async throws -> Bool {
        guard state == nil || state?.userID == expectedSubjectID else { return false }
        try await signOut()
        return true
    }

    func emit(_ state: CatalogAuthState?) {
        self.state = state
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
    private(set) var interactionCallCount = 0
    private(set) var searchRequests: [CatalogSearchRequest] = []
    private(set) var savedCursors: [String?] = []
    private(set) var recordedKeys: [String] = []
    private var savedPages: [CatalogPage]
    private let recordingSucceeds: Bool
    private let holdFirstRecord: Bool
    private var firstRecordContinuation: CheckedContinuation<Void, Never>?
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
        reportFailuresRemaining: Int = 0,
        savedPages: [CatalogPage] = [],
        recordingSucceeds: Bool = false,
        holdFirstRecord: Bool = false
    ) {
        self.homeSteps = homeSteps
        self.detailValue = detailValue
        self.reportFailuresRemaining = reportFailuresRemaining
        self.savedPages = savedPages
        self.recordingSucceeds = recordingSucceeds
        self.holdFirstRecord = holdFirstRecord
    }

    func savedWallpapers(cursor: String?) async throws -> CatalogPage {
        savedCursors.append(cursor)
        guard !savedPages.isEmpty else { throw CatalogRequestError.notConfigured }
        return savedPages.removeFirst()
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
        searchRequests.append(request)
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
        interactionCallCount += 1
        throw CatalogRequestError.notConfigured
    }

    func setSaved(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        interactionCallCount += 1
        throw CatalogRequestError.notConfigured
    }

    func requestInstall(
        wallpaperID: String,
        releaseID: String,
        mediaKind: CatalogMediaKind,
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
        recordedKeys.append(idempotencyKey)
        if holdFirstRecord && recordedKeys.count == 1 {
            await withCheckedContinuation { firstRecordContinuation = $0 }
        }
        if !recordingSucceeds { throw CatalogRequestError.notConfigured }
    }

    func releaseFirstRecord() {
        firstRecordContinuation?.resume()
        firstRecordContinuation = nil
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
    private var profileSubjectID: String
    private(set) var deletionRequestCount = 0
    private(set) var deletionStatusCount = 0
    private(set) var deletionResponseCount = 0
    private var holdDeletionResponse = false
    private var initialIdentityStatus: AccountIdentityDeletionStatus = .sessionsRevoked
    private var deletionStatusResult: AccountDeletionStatus = .processing
    func setDeletionStatusScenario(_ status: AccountDeletionStatus) {
        initialIdentityStatus = .sessionRevocationPending
        deletionStatusResult = status
    }
    private var deletionContinuation: CheckedContinuation<Void, Never>?
    var isDeletionResponseHeld: Bool { deletionContinuation != nil }
    func pauseDeletionResponse() { holdDeletionResponse = true }
    func resumeDeletionResponse() {
        deletionContinuation?.resume()
        deletionContinuation = nil
    }

    init(userID: String) {
        self.userID = userID
        profileSubjectID = userID
    }

    func setProfileSubject(_ subjectID: String) { profileSubjectID = subjectID }

    func accountProfile() async throws -> MarketplaceAccountProfile {
        try MarketplaceAccountProfile(
            id: profileSubjectID,
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
        deletionRequestCount += 1
        guard expectedProfileRevision == 4, confirmation == "DELETE MY WALI" else {
            throw CatalogRequestError.invalidRequest
        }
        if holdDeletionResponse { await withCheckedContinuation { deletionContinuation = $0 } }
        deletionResponseCount += 1
        return try AccountDeletionSnapshot(
            id: "33333333-3333-4333-8333-333333333333",
            subjectID: userID,
            status: .processing,
            identityStatus: initialIdentityStatus,
            revision: 1,
            requestedAt: .now,
            completedAt: nil,
            held: false
        )
    }

    func accountDeletionStatus(id: String, idempotencyKey: String) async throws -> AccountDeletionSnapshot {
        deletionStatusCount += 1
        return try AccountDeletionSnapshot(
            id: "33333333-3333-4333-8333-333333333333", subjectID: userID,
            status: deletionStatusResult,
            identityStatus: deletionStatusResult == .completed ? .completed : .sessionsRevoked,
            revision: 2, requestedAt: .now,
            completedAt: deletionStatusResult == .completed ? .now : nil,
            held: deletionStatusResult == .held
        )
    }
}

private actor ScriptedCreatorAuthorizationGateway: CreatorAuthorizationGateway {
    private(set) var authorizationRequests = 0
    private var authorizationFailuresRemaining: Int
    private var authenticatedSubjectID: String
    private let termsVersion: String
    private let metadataVersion: String
    private let moderatorGrantRevision: UInt64?
    private let mfaStore: ScriptedMFAStore?
    private var metadataRequests = 0
    private let acceptanceDelay: Duration
    private let ignoresAcceptanceCancellation: Bool
    private let confirmsAcceptance: Bool
    private var accepted: String?
    private var acceptanceRequests = 0
    private var expectedSubjects: [String] = []

    init(
        userID: String,
        termsVersion: String = "2026-09-12",
        metadataVersion: String? = nil,
        moderatorGrantRevision: UInt64? = nil,
        mfaStore: ScriptedMFAStore? = nil,
        authorizationFailuresRemaining: Int = 0,
        acceptanceDelay: Duration = .zero,
        ignoresAcceptanceCancellation: Bool = false,
        confirmsAcceptance: Bool = true
    ) {
        authenticatedSubjectID = userID
        self.authorizationFailuresRemaining = authorizationFailuresRemaining
        self.termsVersion = termsVersion
        self.metadataVersion = metadataVersion ?? termsVersion
        self.moderatorGrantRevision = moderatorGrantRevision
        self.mfaStore = mfaStore
        self.acceptanceDelay = acceptanceDelay
        self.ignoresAcceptanceCancellation = ignoresAcceptanceCancellation
        self.confirmsAcceptance = confirmsAcceptance
    }

    func authorizationSnapshot() async throws -> CreatorAuthorizationSnapshot {
        authorizationRequests += 1
        if authorizationFailuresRemaining > 0 {
            authorizationFailuresRemaining -= 1
            throw CatalogRemoteError(code: "temporarily_unavailable", safeMessage: nil, retryable: true)
        }
        let value = snapshot(subjectID: authenticatedSubjectID, acceptedVersion: accepted)
        if let mfaStore {
            let status = try await mfaStore.mfaStatus()
            return value.withAssuranceLevel(status.currentLevel == .aal2 ? .aal2 : .aal1)
        }
        return value
    }

    func creatorMetadata() async throws -> CreatorMetadata {
        metadataRequests += 1
        return try CreatorMetadata(
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
            currentCreatorTermsVersion: metadataVersion
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

    func metadataRequestCount() -> Int { metadataRequests }

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
            moderatorGrantRevision: moderatorGrantRevision,
            assuranceLevel: .aal1
        )
    }
}

private actor StaffModerationMetadataProbe: ModerationGateway {
    private(set) var metadataRequests = 0

    func moderationMetadata() async throws -> ModerationMetadata {
        metadataRequests += 1
        return try ModerationMetadata(checklistRevision: 1, creatorNoteRequired: true, reasonCodes: [
            try ModerationReasonOption(code: "policy_pass", label: "Meets policy", decisions: [.approved]),
        ])
    }

    func queue(_ request: ModerationQueueRequest) async throws -> ModerationQueuePage { throw CatalogRequestError.notConfigured }
    func moderate(_ request: ModerationDecisionRequest) async throws -> ModerationDecisionResult { throw CatalogRequestError.notConfigured }
    func reports(_ request: ModerationReportQueueRequest) async throws -> ModerationReportPage { throw CatalogRequestError.notConfigured }
}
