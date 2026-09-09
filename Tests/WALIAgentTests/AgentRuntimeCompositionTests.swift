import XCTest
@testable import WALIAgentRuntime

final class AgentRuntimeCompositionTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: WALIAgentRootView.self), "WALIAgentRootView")
    }

    @MainActor
    func testRendererForwardsEachDistinctSessionLockOnce() {
        let systemEvents = SystemEventSource()
        let renderer = WallpaperRenderer(systemEvents: systemEvents)
        var lockCallbacks = 0
        renderer.onSessionLock = { lockCallbacks += 1 }
        renderer.start()
        defer { renderer.shutdown() }

        systemEvents.set(.sessionLocked, active: true)
        systemEvents.set(.sessionLocked, active: true)
        XCTAssertEqual(lockCallbacks, 1)

        systemEvents.set(.sessionLocked, active: false)
        systemEvents.set(.sessionLocked, active: true)
        XCTAssertEqual(lockCallbacks, 2)
    }

}
