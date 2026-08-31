import XCTest
@testable import WALITranscoderRuntime

final class WALITranscoderTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnXPCServiceHost() {
        XCTAssertEqual(
            String(describing: WALITranscoderServiceRunner.self),
            "WALITranscoderServiceRunner"
        )
    }
}

