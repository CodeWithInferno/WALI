import WALIEngine
import WALIWire
import XCTest
@testable import WALIAgentRuntime

#if WALI_APP_STORE
final class StoreRuntimePolicyTests: XCTestCase {
    func testRestoredCompatibilityPreferenceIsInert() async {
        let restored = EngineSnapshot(preferences: .init(lockScreenContinuityEnabled: true))
        let router = AgentCommandRouter(restoring: restored) { _, _ in .unchanged }
        let snapshot = await router.snapshot()
        XCTAssertFalse(snapshot.preferences.lockScreenContinuityEnabled)
        XCTAssertEqual(snapshot.revision, restored.revision)
    }

    func testEnableRejectedBeforeEffectsOrRevisionMutation() async {
        let router = AgentCommandRouter { _, _ in
            XCTFail("An unsupported preference must never reach effects")
            return .unchanged
        }
        let response = await router.handle(.init(command: .setPreferences(
            .init(launchAtLogin: true, lockScreenContinuityEnabled: true)
        )))
        guard case let .failure(failure) = response.result else {
            return XCTFail("Expected an unsupported preference failure")
        }
        XCTAssertEqual(failure.code, .invalidRequest)
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.revision.rawValue, 0)
        XCTAssertFalse(snapshot.preferences.launchAtLogin)
        XCTAssertFalse(snapshot.preferences.lockScreenContinuityEnabled)
    }
    func testInternalPreferenceMutationAlsoRejectsCompatibilityActivation() async {
        let router = AgentCommandRouter { _, _ in
            XCTFail("Unsupported internal preferences must not reach effects")
            return .unchanged
        }
        do {
            _ = try await router.performInternal(.setPreferences(.init(lockScreenContinuityEnabled: true)))
            XCTFail("Expected unsupported preference rejection")
        } catch {}
        let snapshot = await router.snapshot()
        XCTAssertFalse(snapshot.preferences.lockScreenContinuityEnabled)
        XCTAssertEqual(snapshot.revision.rawValue, 0)
    }

    func testPresentationDemandRejectsUnknownItemBeforeAdapter() async {
        let router = AgentCommandRouter(presentationHandler: { _, snapshot in
            XCTFail("An unknown item must not reach the presentation adapter")
            return snapshot
        }) { _, _ in .unchanged }
        let response = await router.handle(.init(command: .preparePresentation(itemIDs: [UUID()])))
        guard case let .failure(failure) = response.result else { return XCTFail("Expected invalid item rejection") }
        XCTAssertEqual(failure.code, .invalidRequest)
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.revision.rawValue, 0)
    }

    func testForegroundAcknowledgementTimeoutIsFailureAndCanRetry() async throws {
        do {
            try await StoreForegroundAcknowledgement.wait(timeout: .milliseconds(20)) { _ in }
            XCTFail("No reply must not count as successful shutdown")
        } catch {}
        try await StoreForegroundAcknowledgement.wait { reply in reply(.success(())) }
    }

    func testForegroundConnectionErrorIsFailure() async {
        do {
            try await StoreForegroundAcknowledgement.wait { reply in
                reply(.failure(CocoaError(.xpcConnectionInvalid)))
            }
            XCTFail("A connection error must not count as acknowledgement")
        } catch {}
    }

    func testFailedQuitRetriesCleanupInsteadOfRememberingSuccess() async {
        let shutdown = RetryingShutdownRecorder()
        let router = AgentCommandRouter(shutdownHandler: { try await shutdown.run() }) { _, _ in .unchanged }
        let first = await router.handle(.init(command: .quit))
        guard case .failure = first.result else { return XCTFail("Expected initial acknowledgement failure") }
        let second = await router.handle(.init(command: .quit))
        guard case .snapshot = second.result else { return XCTFail("Quit retry should complete") }
        let attempts = await shutdown.count
        XCTAssertEqual(attempts, 2)
    }

    func testQuitIsIdempotentAndRejectsSubsequentMutation() async {
        let shutdown = ShutdownRecorder()
        let router = AgentCommandRouter(shutdownHandler: { await shutdown.record() }) { _, _ in .unchanged }
        async let first = router.handle(AgentRequest(command: .quit))
        async let second = router.handle(AgentRequest(command: .quit))
        _ = await (first, second)
        let count = await shutdown.count
        XCTAssertEqual(count, 1)
        let rejected = await router.handle(.init(command: .setPlaybackPaused(true)))
        guard case .failure = rejected.result else { return XCTFail("Mutation accepted during shutdown") }
        let snapshot = await router.snapshot()
        XCTAssertFalse(snapshot.isPausedByUser)
        XCTAssertEqual(snapshot.revision.rawValue, 0)
    }

}
#endif

private actor ShutdownRecorder {
    var count = 0
    func record() { count += 1 }
}

private actor RetryingShutdownRecorder {
    var count = 0
    func run() throws {
        count += 1
        if count == 1 { throw CocoaError(.xpcConnectionInvalid) }
    }
}
