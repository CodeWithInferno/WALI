import Foundation
import XCTest
@testable import WALILockScreenHelperRuntime
import WALILockScreenWire

final class LockScreenHelperTests: XCTestCase {
    func testActivationRejectsCallerControlledFilesystemAndCommandFields() throws {
        let request = validActivationObject()
        for forbidden in ["path", "url", "data", "command", "script"] {
            var hostile = request
            hostile[forbidden] = "/tmp/attacker"
            let bytes = try JSONSerialization.data(withJSONObject: hostile)
            XCTAssertThrowsError(try StrictLockScreenCodec.decodeActivation(bytes))
        }
    }

    func testProtocolVersionIsRejectedBeforeActivationPayloadDecode() throws {
        var request = validActivationObject()
        var header = try XCTUnwrap(request["header"] as? [String: Any])
        header["protocolVersion"] = 99
        request["header"] = header
        request["release"] = ["path": "/private/var/db"]

        XCTAssertThrowsError(
            try StrictLockScreenCodec.decodeActivation(
                JSONSerialization.data(withJSONObject: request)
            )
        ) { error in
            XCTAssertEqual(error as? LockScreenHelperError, .protocolMismatch)
        }
    }

    func testActivationRejectsLyingPayloadLength() throws {
        var request = validActivationObject()
        var header = try XCTUnwrap(request["header"] as? [String: Any])
        header["payloadLength"] = 1
        request["header"] = header
        XCTAssertThrowsError(try StrictLockScreenCodec.decodeActivation(
            JSONSerialization.data(withJSONObject: request)
        )) { error in
            XCTAssertEqual(error as? LockScreenHelperError, .invalidPayload)
        }
    }

    func testUnknownOperationHasNoRouterEntry() {
        XCTAssertNil(LockScreenOperation(rawValue: "erase"))
        XCTAssertEqual(Set(LockScreenOperation.allCases.map(\.rawValue)), [
            "status", "activateVerifiedRelease", "deactivate", "restore",
        ])
    }

    func testFixedRootsResolveOnlyCanonicalDigestLocations() throws {
        let root = try temporaryDirectory()
        let roots = FixedWallpaperStore.Roots.testing(under: root)
        let digest = String(repeating: "a", count: 64)
        let store = FixedWallpaperStore(testingRoots: roots, systemBuild: "25G83")

        XCTAssertEqual(
            try store.masterSourceURL(forSHA256: digest),
            roots.objectRoot
                .appendingPathComponent("aa", isDirectory: true)
                .appendingPathComponent("\(digest).mov")
        )
        XCTAssertEqual(
            try store.thumbnailSourceURL(forSHA256: digest),
            roots.preparedThumbnailRoot.appendingPathComponent("\(digest).png")
        )
        for hostile in ["../etc/passwd", String(repeating: "A", count: 64), "https://example.com/x"] {
            XCTAssertThrowsError(try store.masterSourceURL(forSHA256: hostile))
        }
    }

    func testPeerRequirementIsExactAndRejectsMetacharacters() throws {
        XCTAssertEqual(
            try AuthenticatedPeer.requirementExpression(
                identifier: "com.wali.development.WALIAgent",
                team: "ABCDE12345"
            ),
            "anchor apple generic and identifier \"com.wali.development.WALIAgent\" "
                + "and certificate leaf[subject.OU] = \"ABCDE12345\""
        )
        XCTAssertThrowsError(try AuthenticatedPeer.requirementExpression(
            identifier: "com.wali.WALIAgent or true",
            team: "ABCDE12345"
        ))
        XCTAssertThrowsError(try AuthenticatedPeer.requirementExpression(
            identifier: "com.wali.WALIAgent",
            team: "ABCDE\"12345"
        ))
    }

    func testAdHocAndSpoofedPeerIdentitiesAreRejected() {
        XCTAssertFalse(AuthenticatedPeer.matchesDesignatedIdentity(
            clientIdentifier: "com.wali.debug.WALIAgent",
            expectedIdentifier: "com.wali.debug.WALIAgent",
            clientTeam: nil,
            ownTeam: nil
        ))
        XCTAssertFalse(AuthenticatedPeer.matchesDesignatedIdentity(
            clientIdentifier: "com.wali.debug.WALIAgent",
            expectedIdentifier: "com.wali.debug.WALIAgent",
            clientTeam: "ATTACKER01",
            ownTeam: "OWNER00001"
        ))
        XCTAssertFalse(AuthenticatedPeer.matchesDesignatedIdentity(
            clientIdentifier: "com.wali.debug.WALIAgent.spoof",
            expectedIdentifier: "com.wali.debug.WALIAgent",
            clientTeam: "OWNER00001",
            ownTeam: "OWNER00001"
        ))
        XCTAssertTrue(AuthenticatedPeer.matchesDesignatedIdentity(
            clientIdentifier: "com.wali.development.WALIAgent",
            expectedIdentifier: "com.wali.development.WALIAgent",
            clientTeam: "OWNER00001",
            ownTeam: "OWNER00001"
        ))
    }

    func testTemporaryRootsNeverResolveToLiveWallpaperStore() throws {
        let root = try temporaryDirectory()
        let roots = FixedWallpaperStore.Roots.testing(under: root)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for url in roots.allURLs {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(home + "/Library/Application Support/com.apple.wallpaper"))
        }
    }

    private func validActivationObject() -> [String: Any] {
        let release: [String: Any] = [
            "releaseID": "00112233-4455-6677-8899-AABBCCDDEEFF",
            "assetID": "11112222-3333-4444-5555-666677778888",
            "title": "Fixture",
            "masterSHA256": String(repeating: "a", count: 64),
            "thumbnailSHA256": String(repeating: "b", count: 64),
            "compatibilityRevision": 1,
        ]
        let encodedRelease = try! JSONDecoder().decode(
            LockScreenVerifiedRelease.self,
            from: JSONSerialization.data(withJSONObject: release)
        )
        return [
            "header": [
                "protocolVersion": 1,
                "messageVersion": 1,
                "requestID": "10203040-5060-7080-90A0-B0C0D0E0F000",
                "idempotencyKey": "11223344-5566-7788-99AA-BBCCDDEEFF00",
                "expectedRevision": 0,
                "payloadLength": try! LockScreenHelperWire.canonicalPayloadLength(encodedRelease),
            ],
            "release": release,
            "restartPlayback": false,
        ]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wali-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
