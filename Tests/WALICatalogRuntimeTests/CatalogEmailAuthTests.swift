import Foundation
import XCTest
@testable import WALICatalogRuntime

final class CatalogEmailAuthTests: XCTestCase {
    func testRequestCreatesAccountOnlyAfterVerificationAndAdmission() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: " person@example.com ", ownerID: owner)
        let before = await fixture.shared.currentState()
        XCTAssertNil(before)
        let requested = await fixture.transport.requestedEmails
        XCTAssertEqual(requested, ["person@example.com"])
        let state = try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        XCTAssertEqual(state, fixture.candidate.state)
        let admissions = await fixture.shared.admissions
        XCTAssertEqual(admissions, 1)
    }

    func testBoundsRejectBeforeTransport() async throws {
        let fixture = AuthFixture()
        for email in ["", "@example.com", "x@", "x y@example.com", "a\n@example.com", String(repeating: "a", count: 255) + "@example.com"] {
            do {
                _ = try await fixture.authority.beginEmailSignIn(email: email, ownerID: UUID())
                XCTFail("Invalid email accepted")
            } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .invalidEmail) }
        }
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: UUID())
        do {
            _ = try await fixture.authority.verifyEmailCode(code: "１２３４５６", attemptID: attempt.id, ownerID: UUID()) {}
            XCTFail("Non-ASCII code accepted")
        } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .invalidCode) }
    }

    func testCancelledVerificationCannotAdmitAndNeverSignsOutSharedSession() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
        await fixture.transport.pauseVerification()
        let verification = Task {
            try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        }
        await fixture.transport.verificationStarted.wait()
        let cancelled = await fixture.authority.cancelEmailSignIn(attemptID: attempt.id, ownerID: owner)
        XCTAssertTrue(cancelled)
        await fixture.transport.resumeVerification()
        do { _ = try await verification.value; XCTFail("Cancelled attempt admitted") }
        catch { XCTAssertEqual(error as? CatalogEmailAuthError, .superseded) }
        let admissions = await fixture.shared.admissions
        let signOuts = await fixture.shared.signOuts
        XCTAssertEqual(admissions, 0)
        XCTAssertEqual(signOuts, 0)
    }

    func testCommittedAdmissionCannotCancelAndSignOutRunsAfterAdmission() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
        await fixture.shared.pauseAdmission()
        let committed = AuthSignal()
        let verification = Task {
            try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {
                await committed.signal()
            }
        }
        await committed.wait()
        await fixture.shared.admissionStarted.wait()
        let cancelled = await fixture.authority.cancelEmailSignIn(attemptID: attempt.id, ownerID: owner)
        XCTAssertFalse(cancelled)
        verification.cancel()
        let signOut = Task { try await fixture.authority.signOut() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.authority.queuedTransitionCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let queued = await fixture.authority.queuedTransitionCount
        XCTAssertGreaterThan(queued, 0)
        let before = await fixture.shared.signOuts
        XCTAssertEqual(before, 0)
        await fixture.shared.resumeAdmission()
        _ = try await verification.value
        try await signOut.value
        let events = await fixture.shared.operations
        XCTAssertEqual(events, ["admit", "signOut"])
        let state = await fixture.authority.currentState()
        XCTAssertNil(state)
    }

    func testScopedSignOutRechecksSubjectAfterQueuedAdmission() async throws {
        let fixture = AuthFixture()
        let previousID = "11111111-1111-4111-8111-111111111111"
        await fixture.shared.setState(CatalogAuthState(userID: previousID, expiresAt: .distantFuture))
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "second@example.com", ownerID: owner)
        await fixture.shared.pauseAdmission()
        let verification = Task {
            try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        }
        await fixture.shared.admissionStarted.wait()
        let signOut = Task { try await fixture.authority.signOut(expectedSubjectID: previousID) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.authority.queuedTransitionCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let queued = await fixture.authority.queuedTransitionCount
        XCTAssertGreaterThan(queued, 0)
        await fixture.shared.resumeAdmission()
        _ = try await verification.value
        let signedOut = try await signOut.value
        XCTAssertFalse(signedOut)
        let count = await fixture.shared.signOuts
        let current = await fixture.authority.currentState()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(current, fixture.candidate.state)
    }

    func testScopedSignOutClearsOnlyMatchingSubjectAndHandlesAlreadySignedOut() async throws {
        let fixture = AuthFixture()
        await fixture.shared.setState(fixture.candidate.state)
        let first = try await fixture.authority.signOut(expectedSubjectID: fixture.candidate.state.userID)
        let count = await fixture.shared.signOuts
        let repeated = try await fixture.authority.signOut(expectedSubjectID: fixture.candidate.state.userID)
        let current = await fixture.authority.currentState()
        XCTAssertTrue(first)
        XCTAssertTrue(repeated)
        XCTAssertEqual(count, 1)
        XCTAssertNil(current)
    }

    func testDetachedOwnerDiscardsLateRequestAndReplacementCanStart() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        await fixture.transport.pauseRequest()
        let request = Task { try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner) }
        await fixture.transport.requestStarted.wait()
        await fixture.authority.detachEmailSignIn(ownerID: owner)
        await fixture.transport.resumeRequest()
        do { _ = try await request.value; XCTFail("Detached request returned") }
        catch { XCTAssertEqual(error as? CatalogEmailAuthError, .superseded) }
        _ = try await fixture.authority.beginEmailSignIn(email: "second@example.com", ownerID: UUID())
        let state = await fixture.shared.currentState()
        XCTAssertNil(state)
    }

    func testResendCooldownAndSafeVerificationFailure() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
        do {
            _ = try await fixture.authority.resendEmailCode(attemptID: attempt.id, ownerID: owner)
            XCTFail("Cooldown ignored")
        } catch {
            guard case .resendTooSoon = error as? CatalogEmailAuthError else { return XCTFail("Wrong cooldown error") }
        }
        await fixture.transport.setFailure(.invalidOrExpiredCode)
        do {
            _ = try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
            XCTFail("Failed verification admitted")
        } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .invalidOrExpiredCode) }
        let admissions = await fixture.shared.admissions
        XCTAssertEqual(admissions, 0)
    }

    func testFailedAdmissionDoesNotPublishSuccess() async throws {
        let fixture = AuthFixture()
        await fixture.shared.failAdmission()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
        do {
            _ = try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
            XCTFail("Failed admission returned success")
        } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .admissionFailed) }
        let state = await fixture.authority.currentState()
        XCTAssertNil(state)
    }

    func testReplacementDiscardsOlderVerification() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "first@example.com", ownerID: owner)
        await fixture.transport.pauseVerification()
        let verification = Task {
            try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        }
        await fixture.transport.verificationStarted.wait()
        _ = try await fixture.authority.beginEmailSignIn(email: "second@example.com", ownerID: UUID())
        await fixture.transport.resumeVerification()
        do { _ = try await verification.value; XCTFail("Replaced verification admitted") }
        catch { XCTAssertEqual(error as? CatalogEmailAuthError, .superseded) }
        let admissions = await fixture.shared.admissions
        let signOuts = await fixture.shared.signOuts
        XCTAssertEqual(admissions, 0)
        XCTAssertEqual(signOuts, 0)
    }

    func testNewAttemptWaitsForCommittedAdmissionAndWindowCanDetach() async throws {
        let fixture = AuthFixture()
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "first@example.com", ownerID: owner)
        await fixture.shared.pauseAdmission()
        let verification = Task {
            try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        }
        await fixture.shared.admissionStarted.wait()
        await fixture.authority.detachEmailSignIn(ownerID: owner)
        let next = Task { try await fixture.authority.beginEmailSignIn(email: "second@example.com", ownerID: UUID()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.authority.queuedTransitionCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let requestsBefore = await fixture.transport.requestedEmails
        XCTAssertEqual(requestsBefore, ["first@example.com"])
        await fixture.shared.resumeAdmission()
        _ = try await verification.value
        _ = try await next.value
        let requestsAfter = await fixture.transport.requestedEmails
        XCTAssertEqual(requestsAfter, ["first@example.com", "second@example.com"])
    }

    func testObserversBroadcastAcceptedSessionAndDetachIndependently() async throws {
        let fixture = AuthFixture()
        let first = AuthStateRecorder()
        let second = AuthStateRecorder()
        let firstStream = await fixture.authority.stateChanges()
        let secondStream = await fixture.authority.stateChanges()
        let firstTask = Task { for await state in firstStream { await first.record(state) } }
        let secondTask = Task { for await state in secondStream { await second.record(state) } }
        await first.waitForCount(1)
        await second.waitForCount(1)
        let owner = UUID()
        let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
        _ = try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
        await first.waitForCount(2)
        await second.waitForCount(2)
        firstTask.cancel()
        await firstTask.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.authority.observerCount != 1, ContinuousClock.now < deadline { await Task.yield() }
        let remainingObservers = await fixture.authority.observerCount
        XCTAssertEqual(remainingObservers, 1)
        try await fixture.authority.signOut()
        await second.waitForCount(3)
        let states = await second.states
        XCTAssertEqual(states, [nil, fixture.candidate.state, nil])
        secondTask.cancel()
        await secondTask.value
    }

    func testSafeInvalidExpiredReusedRateLimitedAndTimeoutFailuresNeverAdmit() async throws {
        for failure in [CatalogEmailAuthError.invalidOrExpiredCode, .rateLimited, .timedOut, .networkUnavailable] {
            let fixture = AuthFixture()
            let owner = UUID()
            let attempt = try await fixture.authority.beginEmailSignIn(email: "person@example.com", ownerID: owner)
            await fixture.transport.setFailure(failure)
            do {
                _ = try await fixture.authority.verifyEmailCode(code: "123456", attemptID: attempt.id, ownerID: owner) {}
                XCTFail("Failure authenticated")
            } catch { XCTAssertEqual(error as? CatalogEmailAuthError, failure) }
            let state = await fixture.authority.currentState()
            let admissions = await fixture.shared.admissions
            XCTAssertNil(state)
            XCTAssertEqual(admissions, 0)
        }
    }
}

private actor AuthStateRecorder {
    private(set) var states: [CatalogAuthState?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func record(_ state: CatalogAuthState?) {
        states.append(state)
        let ready = waiters.filter { states.count >= $0.0 }
        waiters.removeAll { states.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func waitForCount(_ count: Int) async {
        if states.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private struct AuthFixture: Sendable {
    let candidate = CatalogEmailSessionCandidate(accessToken: "fixture-access", refreshToken: "fixture-refresh", state: CatalogAuthState(userID: "ca53dd4a-f487-482a-99ed-3ac29ee1cd5f", expiresAt: Date(timeIntervalSince1970: 4_000_000_000)))
    let transport: FakeEmailTransport
    let shared = FakeSharedSession()
    let authority: CatalogAuthAuthority
    init() {
        let transport = FakeEmailTransport(candidate: candidate)
        self.transport = transport
        authority = CatalogAuthAuthority(shared: shared, attemptFactory: { transport })
    }
}

private actor AuthSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FakeEmailTransport: CatalogEmailAttemptTransport {
    let candidate: CatalogEmailSessionCandidate
    let verificationStarted = AuthSignal()
    let requestStarted = AuthSignal()
    private var verificationPause: AuthSignal?
    private var requestPause: AuthSignal?
    private var failure: CatalogEmailAuthError?
    private(set) var requestedEmails: [String] = []
    init(candidate: CatalogEmailSessionCandidate) { self.candidate = candidate }
    func pauseVerification() { verificationPause = AuthSignal() }
    func resumeVerification() async { await verificationPause?.signal(); verificationPause = nil }
    func pauseRequest() { requestPause = AuthSignal() }
    func resumeRequest() async { await requestPause?.signal(); requestPause = nil }
    func setFailure(_ failure: CatalogEmailAuthError) { self.failure = failure }
    func requestCode(email: String) async throws {
        requestedEmails.append(email)
        await requestStarted.signal()
        await requestPause?.wait()
        if let failure { throw failure }
    }
    func verifyCode(email: String, code: String) async throws -> CatalogEmailSessionCandidate {
        await verificationStarted.signal()
        await verificationPause?.wait()
        if let failure { throw failure }
        return candidate
    }
    func discard() async {}
}

private actor FakeSharedSession: CatalogSharedSessionAdapter {
    let admissionStarted = AuthSignal()
    private var admissionPause: AuthSignal?
    private var admissionFails = false
    private var state: CatalogAuthState?
    private(set) var admissions = 0
    private(set) var signOuts = 0
    private(set) var operations: [String] = []
    func currentState() async -> CatalogAuthState? { state }
    func currentSubjectID() async -> String? { state?.userID }
    func setState(_ state: CatalogAuthState?) { self.state = state }
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.yield(()) } }
    func pauseAdmission() { admissionPause = AuthSignal() }
    func resumeAdmission() async { await admissionPause?.signal(); admissionPause = nil }
    func failAdmission() { admissionFails = true }
    func admit(_ candidate: CatalogEmailSessionCandidate) async throws -> CatalogAuthState {
        await admissionStarted.signal()
        await admissionPause?.wait()
        if admissionFails { throw CatalogEmailAuthError.admissionFailed }
        admissions += 1
        operations.append("admit")
        state = candidate.state
        return candidate.state
    }
    func signOut() async throws {
        signOuts += 1
        operations.append("signOut")
        state = nil
    }
}
