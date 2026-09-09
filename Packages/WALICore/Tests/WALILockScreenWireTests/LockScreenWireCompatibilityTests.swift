import Foundation
import ObjectiveC
import XCTest
import WALILockScreenWire

final class LockScreenWireCompatibilityTests: XCTestCase {
    func testDirectHelperSelectorsRemainStable() {
        XCTAssertEqual(NSStringFromSelector(#selector(WALILockScreenHelperXPCProtocol.status(_:withReply:))), "status:withReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(WALILockScreenHelperXPCProtocol.activateVerifiedRelease(_:withReply:))), "activateVerifiedRelease:withReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(WALILockScreenHelperXPCProtocol.deactivate(_:withReply:))), "deactivate:withReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(WALILockScreenHelperXPCProtocol.restore(_:withReply:))), "restore:withReply:")
    }

    func testOnlyTheFourOriginalObjectiveCMethodEncodingsAreExported() throws {
        var count: UInt32 = 0
        let descriptions = try XCTUnwrap(protocol_copyMethodDescriptionList(
            WALILockScreenHelperXPCProtocol.self, true, true, &count
        ))
        defer { free(descriptions) }
        let methods = UnsafeBufferPointer(start: descriptions, count: Int(count))
        let actual = try Dictionary(uniqueKeysWithValues: methods.map { method in
            (NSStringFromSelector(try XCTUnwrap(method.name)), String(cString: try XCTUnwrap(method.types)))
        })
        XCTAssertEqual(actual, [
            "status:withReply:": "v32@0:8@16@?24",
            "activateVerifiedRelease:withReply:": "v32@0:8@16@?24",
            "deactivate:withReply:": "v32@0:8@16@?24",
            "restore:withReply:": "v32@0:8@16@?24",
        ])
    }

    func testDirectActivationKeepsItsVersionOneEncoding() throws {
        let release = LockScreenVerifiedRelease(
            releaseID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Fixture", masterSHA256: String(repeating: "a", count: 64),
            thumbnailSHA256: String(repeating: "b", count: 64), compatibilityRevision: 1
        )
        let request = LockScreenHelperActivationRequest(
            header: LockScreenHelperRequestHeader(
                requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                idempotencyKey: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                expectedRevision: 7, payloadLength: try LockScreenHelperWire.canonicalPayloadLength(release)
            ), release: release, restartPlayback: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(request)
        let expected = #"{"header":{"expectedRevision":7,"idempotencyKey":"00000000-0000-0000-0000-000000000004","messageVersion":1,"payloadLength":312,"protocolVersion":1,"requestID":"00000000-0000-0000-0000-000000000003"},"release":{"assetID":"00000000-0000-0000-0000-000000000002","compatibilityRevision":1,"masterSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","releaseID":"00000000-0000-0000-0000-000000000001","thumbnailSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"Fixture"},"restartPlayback":false}"#
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        XCTAssertEqual(try JSONDecoder().decode(LockScreenHelperActivationRequest.self, from: encoded), request)
    }
}
