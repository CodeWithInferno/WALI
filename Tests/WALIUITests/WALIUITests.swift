import XCTest
@testable import WALIUI

final class WALIUITests: XCTestCase {
    func testStatusPanelIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: StatusPanel.self), "StatusPanel")
    }
}

