#if WALI_APP_STORE
import Foundation
import WALIWire
import XCTest
@testable import WALIAppRuntime

@MainActor
final class ForegroundImportBookmarksTests: XCTestCase {
    func testDeniedScopeNeverCreatesBookmark() {
        var didCreate = false
        var didClose = false
        XCTAssertThrowsError(try ForegroundImportBookmarks.make(
            for: [URL(fileURLWithPath: "/tmp/selected.mov")],
            access: .init(begin: { _ in false }, end: { _ in didClose = true }, bookmark: { _ in
                didCreate = true
                return Data([1])
            })
        ))
        XCTAssertFalse(didCreate)
        XCTAssertFalse(didClose)
    }

    func testScopeClosesWhenBookmarkCreationFails() {
        var opened = 0
        var closed = 0
        XCTAssertThrowsError(try ForegroundImportBookmarks.make(
            for: [URL(fileURLWithPath: "/tmp/selected.mov")],
            access: .init(begin: { _ in opened += 1; return true }, end: { _ in closed += 1 }, bookmark: { _ in
                throw CocoaError(.fileReadNoPermission)
            })
        ))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(closed, 1)
    }

    func testOversizedGrantClosesScopeAndIsRejected() {
        var closed = false
        XCTAssertThrowsError(try ForegroundImportBookmarks.make(
            for: [URL(fileURLWithPath: "/tmp/selected.mov")],
            access: .init(begin: { _ in true }, end: { _ in closed = true }, bookmark: { _ in
                Data(repeating: 1, count: StoreImportGrant.maximumBookmarkBytes + 1)
            })
        ))
        XCTAssertTrue(closed)
    }
}
#endif
