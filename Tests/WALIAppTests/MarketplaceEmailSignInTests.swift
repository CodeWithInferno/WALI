import Foundation
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
func assertEmailEventually(
    _ predicate: @escaping @MainActor () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Expected email-flow transition did not arrive", file: file, line: line)
}

@MainActor
final class MarketplaceEmailSignInTests: XCTestCase {
    func testProviderSelectionAndDisabledBuildCannotFallBack() {
        let auth = EmailAuthProbe()
        let email = makeCoordinator(auth)
        email.signIn()
        XCTAssertTrue(email.emailSignIn.isPresented)
        XCTAssertEqual(email.emailSignIn.phase, .email)
        XCTAssertEqual(auth.beginCalls, 0, "Presenting a sheet must not send an email")
        email.stop()

        for method in [CatalogAuthenticationMethod.nativeApple, .disabled] {
            let other = MarketplaceCoordinator(authenticationMethod: method, authStore: auth, emailAuth: auth)
            other.signIn()
            XCTAssertFalse(other.emailSignIn.isPresented)
            XCTAssertEqual(auth.beginCalls, 0)
            if method == .disabled { XCTAssertFalse(other.isMarketplaceAvailable) }
            other.stop()
        }
    }

    func testRequestOnlyOpensCodeEntryAndDoesNotAuthenticate() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertNil(auth.state)
        XCTAssertEqual(auth.verifyCalls, 0)
        XCTAssertEqual(coordinator.emailSignIn.email, "person@example.test")
        coordinator.stop()
    }

    func testCancelledPendingRequestCannotReopenSheetWhenItReturnsLate() async {
        let auth = EmailAuthProbe()
        auth.holdBegin = true
        let coordinator = makeCoordinator(auth)
        coordinator.signIn()
        coordinator.emailSignIn.email = "person@example.test"
        coordinator.requestEmailCode()
        await assertEmailEventually { auth.hasPendingBegin }
        coordinator.cancelEmailSignIn()
        await assertEmailEventually { !coordinator.emailSignIn.isPresented }
        auth.completeBegin()
        await assertEmailEventually { auth.completedBegins == 1 }
        XCTAssertFalse(coordinator.emailSignIn.isPresented)
        XCTAssertEqual(coordinator.emailSignIn.email, "")
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(auth.detachedOwners.count, 1)
        coordinator.stop()
    }

    func testCompletingStateHasNoCancelAndAcceptedSessionFinishes() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        await auth.commitAdmission()
        XCTAssertEqual(coordinator.emailSignIn.phase, .completing)
        XCTAssertFalse(coordinator.emailSignIn.canCancel)
        coordinator.cancelEmailSignIn()
        XCTAssertEqual(auth.cancelCalls, 0)
        XCTAssertTrue(coordinator.emailSignIn.isPresented)
        auth.completeVerification()
        await assertEmailEventually { !coordinator.emailSignIn.isPresented }
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: auth.accepted.userID))
        XCTAssertEqual(coordinator.model.authenticationState, .idle)
        XCTAssertEqual(coordinator.emailSignIn.code, "")
        coordinator.stop()
    }

    func testServiceCommitWinsCancellationRaceWithoutClaimingCancellation() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        auth.committed = true // The service crossed its boundary before its UI callback ran.
        coordinator.cancelEmailSignIn()
        await assertEmailEventually { coordinator.emailSignIn.phase == .completing }
        XCTAssertTrue(coordinator.emailSignIn.isPresented)
        XCTAssertEqual(auth.cancelCalls, 1)
        auth.completeVerification()
        await assertEmailEventually { !coordinator.emailSignIn.isPresented }
        XCTAssertEqual(coordinator.model.accountState, .signedIn(userID: auth.accepted.userID))
        coordinator.stop()
    }

    func testAdmissionFailureArrivingDuringPendingCancelCannotLeaveCompletingForever() async {
        let auth = EmailAuthProbe()
        auth.holdCancel = true
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        auth.committed = true
        coordinator.cancelEmailSignIn()
        await assertEmailEventually { auth.hasPendingCancel }
        auth.failVerification(CatalogEmailAuthError.admissionFailed)
        let failureMessage = "Sign-in couldn’t be completed. Request a new code to try again."
        await assertEmailEventually { coordinator.emailSignIn.message == failureMessage }
        XCTAssertEqual(coordinator.emailSignIn.phase, .cancelling)
        auth.completeCancellation(false)
        await assertEmailEventually { coordinator.emailSignIn.phase == .email }
        XCTAssertEqual(coordinator.emailSignIn.message, failureMessage)
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(auth.signOutCalls, 0)
        coordinator.stop()
    }

    func testSharedSessionBroadcastSurvivesCommittedOwnerWindowTeardown() async {
        let auth = EmailAuthProbe()
        let owner = makeCoordinator(auth)
        let other = makeCoordinator(auth)
        owner.start()
        other.start()
        await assertEmailEventually { auth.observerCount == 2 }
        await requestCode(owner)
        await startVerification(owner, auth)
        await auth.commitAdmission()
        owner.stop()
        await assertEmailEventually { auth.observerCount == 1 && !auth.detachedOwners.isEmpty }
        auth.completeVerification()
        await assertEmailEventually { other.model.accountState == .signedIn(userID: auth.accepted.userID) }
        XCTAssertEqual(owner.model.accountState, .signedOut)
        XCTAssertFalse(owner.emailSignIn.isPresented)
        XCTAssertEqual(auth.signOutCalls, 0, "Teardown must never sign out the shared account")
        other.stop()
        await assertEmailEventually { auth.observerCount == 0 }
    }

    func testTeardownBeforeCommitIgnoresEvenAnIncorrectLateAdapterResult() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        coordinator.stop()
        await auth.commitAdmission() // Deliberately stronger than the real adapter's contract.
        auth.completeVerification()
        await assertEmailEventually { auth.completedVerifications == 1 }
        XCTAssertFalse(coordinator.emailSignIn.isPresented)
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(auth.signOutCalls, 0)
    }

    func testResendBoundsAndChangedEmailUseFreshOwner() async {
        let auth = EmailAuthProbe()
        var now = auth.now
        let coordinator = MarketplaceCoordinator(
            authenticationMethod: .emailOTP, authStore: auth, emailAuth: auth, emailNow: { now }
        )
        await requestCode(coordinator)
        let originalOwner = auth.owners.first
        coordinator.resendEmailCode()
        XCTAssertEqual(auth.resendCalls, 0)
        now = now.addingTimeInterval(61)
        coordinator.resendEmailCode()
        await assertEmailEventually { auth.resendCalls == 1 && coordinator.emailSignIn.phase == .code }
        coordinator.changeSignInEmail()
        XCTAssertEqual(coordinator.emailSignIn.phase, .email)
        XCTAssertEqual(coordinator.emailSignIn.code, "")
        coordinator.emailSignIn.email = "new@example.test"
        coordinator.requestEmailCode()
        await assertEmailEventually { auth.beginCalls == 2 && coordinator.emailSignIn.phase == .code }
        XCTAssertNotEqual(auth.owners.last, originalOwner)
        await assertEmailEventually { auth.detachedOwners.contains(originalOwner!) }
        coordinator.stop()
    }

    func testOversizedInputsNeverReachAuthAndFailuresUseFixedText() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        coordinator.signIn()
        coordinator.emailSignIn.email = String(repeating: "x", count: 255)
        coordinator.requestEmailCode()
        XCTAssertEqual(auth.beginCalls, 0)
        coordinator.emailSignIn.email = "person@example.test"
        coordinator.requestEmailCode()
        await assertEmailEventually { coordinator.emailSignIn.phase == .code }
        coordinator.emailSignIn.code = String(repeating: "1", count: 17)
        coordinator.verifyEmailCode()
        XCTAssertEqual(auth.verifyCalls, 0)
        XCTAssertEqual(coordinator.emailSignIn.message, "Enter the one-time code from your email.")
        XCTAssertEqual(
            MarketplaceCoordinator.emailMessage(for: CatalogRemoteError(
                code: "secret-bearing-code", safeMessage: "Never display this server content", retryable: false
            )),
            "Sign-in couldn’t be completed. Please try again."
        )
        coordinator.stop()
    }

    func testAcceptedResultForDifferentCurrentSubjectDoesNotResumeOrReplaceAccount() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        await auth.commitAdmission()
        auth.completeVerification(currentSubject: "another-subject")
        await assertEmailEventually { !coordinator.emailSignIn.isPresented }
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(coordinator.model.authenticationState, .failed(message: "Your sign-in session changed. Continue with the current account or try again."))
        coordinator.stop()
    }

    func testWrongCodeCanRetryButFailedAdmissionNeverClaimsSuccess() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        auth.failVerification(CatalogEmailAuthError.invalidOrExpiredCode)
        await assertEmailEventually { coordinator.emailSignIn.phase == .code }
        XCTAssertEqual(coordinator.emailSignIn.message, "That code is invalid or expired. Check it or request a new code.")
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        await startVerification(coordinator, auth)
        await auth.commitAdmission()
        auth.failVerification(CatalogEmailAuthError.admissionFailed)
        await assertEmailEventually { coordinator.emailSignIn.phase == .email }
        XCTAssertTrue(coordinator.emailSignIn.isPresented)
        XCTAssertEqual(coordinator.emailSignIn.message, "Sign-in couldn’t be completed. Request a new code to try again.")
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        XCTAssertEqual(auth.signOutCalls, 0)
        coordinator.stop()
    }

    func testSignOutDuringCompletingDetachesIntentAndReachesSharedService() async {
        let auth = EmailAuthProbe()
        let coordinator = makeCoordinator(auth)
        await requestCode(coordinator)
        await startVerification(coordinator, auth)
        await auth.commitAdmission()
        coordinator.signOut()
        await assertEmailEventually { auth.signOutCalls == 1 && !coordinator.emailSignIn.isPresented }
        // This fixture only proves dispatch and stale UI refusal; the real adapter tests ordering.
        auth.completeVerification()
        await assertEmailEventually { auth.completedVerifications == 1 }
        XCTAssertEqual(coordinator.model.accountState, .signedOut)
        coordinator.stop()
    }

    private func makeCoordinator(_ auth: EmailAuthProbe) -> MarketplaceCoordinator {
        MarketplaceCoordinator(authenticationMethod: .emailOTP, authStore: auth, emailAuth: auth)
    }

    private func requestCode(_ coordinator: MarketplaceCoordinator) async {
        coordinator.signIn()
        coordinator.emailSignIn.email = "person@example.test"
        coordinator.requestEmailCode()
        await assertEmailEventually { coordinator.emailSignIn.phase == .code }
    }

    private func startVerification(_ coordinator: MarketplaceCoordinator, _ auth: EmailAuthProbe) async {
        coordinator.emailSignIn.code = "123456"
        coordinator.verifyEmailCode()
        await assertEmailEventually { auth.hasPendingVerification }
        XCTAssertEqual(coordinator.emailSignIn.code, "")
    }
}

/// Explicit suspension points deliberately ignore task cancellation to exercise UI late-result guards.
/// Shared storage/admission safety is tested through the real catalog adapter separately.
@MainActor
final class EmailAuthProbe: CatalogEmailAuthenticating, CatalogAuthSessionProviding {
    let now = Date()
    var accepted: CatalogAuthState { CatalogAuthState(userID: "email-subject", expiresAt: now.addingTimeInterval(3_600)) }
    var state: CatalogAuthState?
    var holdBegin = false
    var holdCancel = false
    var committed = false
    private(set) var beginCalls = 0
    private(set) var completedBegins = 0
    private(set) var verifyCalls = 0
    private(set) var completedVerifications = 0
    private(set) var resendCalls = 0
    private(set) var cancelCalls = 0
    private(set) var signOutCalls = 0
    private(set) var owners: [UUID] = []
    private(set) var detachedOwners: Set<UUID> = []
    private var beginContinuation: CheckedContinuation<Void, Never>?
    private var verifyContinuation: CheckedContinuation<CatalogAuthState, Error>?
    private var cancelContinuation: CheckedContinuation<Bool, Never>?
    private var commitCallback: (@Sendable () async -> Void)?
    private var observers: [UUID: AsyncStream<CatalogAuthState?>.Continuation] = [:]
    var hasPendingBegin: Bool { beginContinuation != nil }
    var hasPendingVerification: Bool { verifyContinuation != nil }
    var hasPendingCancel: Bool { cancelContinuation != nil }
    var observerCount: Int { observers.count }

    func beginEmailSignIn(email: String, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        beginCalls += 1
        owners.append(ownerID)
        if holdBegin { await withCheckedContinuation { beginContinuation = $0 } }
        completedBegins += 1
        return CatalogEmailAuthAttempt(id: UUID(), email: email, resendAvailableAt: now.addingTimeInterval(60))
    }

    func completeBegin() {
        let pending = beginContinuation
        beginContinuation = nil
        pending?.resume()
    }

    func resendEmailCode(attemptID: UUID, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        resendCalls += 1
        return CatalogEmailAuthAttempt(id: attemptID, email: "person@example.test", resendAvailableAt: now.addingTimeInterval(120))
    }

    func verifyEmailCode(
        code: String, attemptID: UUID, ownerID: UUID,
        onAdmissionCommitted: @escaping @Sendable () async -> Void
    ) async throws -> CatalogAuthState {
        verifyCalls += 1
        commitCallback = onAdmissionCommitted
        let result = try await withCheckedThrowingContinuation { verifyContinuation = $0 }
        completedVerifications += 1
        return result
    }

    func commitAdmission() async {
        committed = true
        await commitCallback?()
    }

    func completeVerification(currentSubject: String? = nil) {
        state = currentSubject.map { CatalogAuthState(userID: $0, expiresAt: accepted.expiresAt) } ?? accepted
        for observer in observers.values { observer.yield(state) }
        let pending = verifyContinuation
        verifyContinuation = nil
        pending?.resume(returning: accepted)
    }

    func failVerification(_ error: Error) {
        let pending = verifyContinuation
        verifyContinuation = nil
        pending?.resume(throwing: error)
    }

    func cancelEmailSignIn(attemptID: UUID, ownerID: UUID) async -> Bool {
        cancelCalls += 1
        if holdCancel { return await withCheckedContinuation { cancelContinuation = $0 } }
        if committed { return false }
        detachedOwners.insert(ownerID)
        let pending = verifyContinuation
        verifyContinuation = nil
        pending?.resume(throwing: CatalogEmailAuthError.cancelled)
        return true
    }

    func completeCancellation(_ cancelled: Bool) {
        let pending = cancelContinuation
        cancelContinuation = nil
        pending?.resume(returning: cancelled)
    }

    func detachEmailSignIn(ownerID: UUID) async { detachedOwners.insert(ownerID) }
    func currentState() async -> CatalogAuthState? { state }

    func stateChanges() async -> AsyncStream<CatalogAuthState?> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    func signOut() async throws {
        signOutCalls += 1
        state = nil
        for observer in observers.values { observer.yield(nil) }
    }
}
