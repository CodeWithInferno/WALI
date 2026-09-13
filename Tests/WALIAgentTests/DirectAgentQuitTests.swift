#if !WALI_APP_STORE
import WALIEngine
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class DirectAgentQuitTests: XCTestCase {
    func testQuitReturnsForHostCompletionAndRejectsLaterMutations() async {
        let restored = EngineSnapshot(preferences: .init(launchAtLogin: true, lockScreenContinuityEnabled: true))
        let router = AgentCommandRouter(restoring: restored) { _, _ in
            XCTFail("Quit must not change wallpaper preferences or dispatch effects")
            return .unchanged
        }
        let request = AgentRequest(command: .quit)
        let response = await router.handle(request)
        XCTAssertEqual(response.requestID, request.requestID)
        guard case .snapshot = response.result else { return XCTFail("Expected Quit response before host termination") }
        let retry = await router.handle(.init(command: .quit))
        guard case .snapshot = retry.result else { return XCTFail("Repeated Quit should remain idempotent") }
        let mutation = await router.handle(.init(command: .setPreferences(.init())))
        guard case .failure = mutation.result else { return XCTFail("New mutation accepted after Quit") }
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.preferences, restored.preferences)
        XCTAssertEqual(snapshot.revision, restored.revision)
    }
}

@MainActor
final class DirectAgentQuitRoutingTests: XCTestCase {
    func testNoForegroundLeavesQuitWithAgent() throws {
        XCTAssertFalse(try DirectAgentQuit.forwardIfPresent([]))
    }

    func testForegroundTerminationIsForwardedWithoutAgentCompletion() throws {
        var requests = 0
        XCTAssertTrue(try DirectAgentQuit.forwardIfPresent([
            { requests += 1; return true },
        ]))
        XCTAssertEqual(requests, 1)
    }

    func testRefusedForegroundTerminationIsFailure() {
        var requests = 0
        XCTAssertThrowsError(try DirectAgentQuit.forwardIfPresent([
            { requests += 1; return false },
            { requests += 1; return true },
        ])) { error in
            XCTAssertEqual((error as? AgentFailure)?.code, .internalFailure)
        }
        XCTAssertEqual(requests, 2)
    }
}
#endif
