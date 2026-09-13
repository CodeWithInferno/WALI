#if !WALI_APP_STORE
import AppKit
import WALIWire
import XCTest
@testable import WALIAppRuntime

@MainActor
final class DirectForegroundQuitTests: XCTestCase {
    func testUIQuitUsesApplicationLifetimeAndWindowCloseDoesNot() throws {
        let suite = "WALI.DirectQuitTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = DirectTerminationRecorder()
        let coordinator = WALIAppCoordinator(
            lifecycle: AgentLifecycleController(
                registrations: [], defaults: defaults, requiresExplicitConsent: false
            ),
            requestApplicationTermination: { recorder.requests += 1 }
        )
        coordinator.windowDidDisappear(UUID())
        XCTAssertEqual(recorder.requests, 0)
        coordinator.send(.quit)
        XCTAssertEqual(recorder.requests, 1)
    }

    func testQuitWaitsForAcknowledgmentAndCoalescesRepeatedRequests() async {
        let started = expectation(description: "Quit requested")
        let completed = expectation(description: "Termination acknowledged")
        var continuation: CheckedContinuation<Void, Error>?
        var requests = 0
        var replies: [Bool] = []
        let delegate = WALIDirectApplicationDelegate(quitAgent: {
            requests += 1
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                started.fulfill()
            }
        }, reply: { permit in
            replies.append(permit)
            completed.fulfill()
        }, reportFailure: { error in XCTFail("Unexpected failure: \(error)") })

        XCTAssertEqual(requests, 0, "Constructing the app lifetime owner must not start services")
        XCTAssertEqual(delegate.requestQuit(), .terminateLater)
        XCTAssertEqual(delegate.requestQuit(), .terminateLater)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(replies.isEmpty)
        continuation?.resume()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(delegate.requestQuit(), .terminateNow)
        XCTAssertEqual(requests, 1)
    }

    func testFailedTransportAndInvalidRepliesDoNotPermitExitAndCanRetry() async {
        let errors: [Error] = [
            AgentConnectionError.timedOut,
            AgentConnectionError.requestMismatch,
            AgentConnectionError.emptyResponse,
            WireCodecError.invalidEnvelope,
            CocoaError(.xpcConnectionInterrupted),
            AgentFailure(code: .internalFailure, message: "Quit failed"),
        ]
        for error in errors {
            let denied = expectation(description: "Failed Quit remains open")
            let retried = expectation(description: "Retry acknowledged")
            var attempts = 0
            var failures = 0
            var replies: [Bool] = []
            let delegate = WALIDirectApplicationDelegate(quitAgent: {
                attempts += 1
                if attempts == 1 { throw error }
            }, reply: { permit in
                replies.append(permit)
                if permit { retried.fulfill() } else { denied.fulfill() }
            }, reportFailure: { _ in failures += 1 })

            XCTAssertEqual(delegate.requestQuit(), .terminateLater)
            await fulfillment(of: [denied], timeout: 1)
            XCTAssertEqual(replies, [false])
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(delegate.requestQuit(), .terminateLater)
            await fulfillment(of: [retried], timeout: 1)
            XCTAssertEqual(replies, [false, true])
            XCTAssertEqual(attempts, 2)
        }
    }
}
@MainActor
private final class DirectTerminationRecorder {
    var requests = 0
}
#endif
