import XCTest
@testable import WALIAgentRuntime

final class WALIAgentTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: WALIAgentRootView.self), "WALIAgentRootView")
    }
}

