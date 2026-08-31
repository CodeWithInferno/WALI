import XCTest
@testable import WALIAppRuntime

final class WALIAppTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: WALIAppRootView.self), "WALIAppRootView")
    }
}

