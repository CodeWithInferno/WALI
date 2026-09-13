import XCTest
@testable import WALIUI

final class WALIUITests: XCTestCase {
    func testAutomaticPauseReasonRequiresTheMatchingPolicy() {
        XCTAssertEqual(WALIRendererState.automaticPauseReason(isLowPowerModeEnabled: true,
            pausesForLowPowerMode: true, thermalState: "nominal"), "Low Power Mode")
        XCTAssertEqual(WALIRendererState.automaticPauseReason(isLowPowerModeEnabled: true,
            pausesForLowPowerMode: false, thermalState: "nominal"), "System activity")
        for thermal in ["serious", "critical"] {
            XCTAssertEqual(WALIRendererState.automaticPauseReason(isLowPowerModeEnabled: true,
                pausesForLowPowerMode: true, thermalState: thermal), "Thermal pressure")
        }
        XCTAssertEqual(WALIRendererState.automaticPauseReason(isLowPowerModeEnabled: false,
            pausesForLowPowerMode: true, thermalState: "fair"), "System activity")
    }

    func testStatusPanelIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: StatusPanel.self), "StatusPanel")
    }
}

