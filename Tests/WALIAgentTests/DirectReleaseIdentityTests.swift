#if !WALI_APP_STORE
import Foundation
import XCTest
@testable import WALIAgentRuntime

final class DirectReleaseIdentityTests: XCTestCase {
    func testForegroundActivationAndAuthenticationUseExactDirectPeers() {
        let peers = [
            "io.github.codewithinferno.wali.WALIAgent": "io.github.codewithinferno.wali.WALI",
            "com.wali.debug.WALIAgent": "com.wali.debug.WALI",
            "com.wali.development.WALIAgent": "com.wali.development.WALI",
        ]
        for (agent, app) in peers {
            XCTAssertEqual(DirectAgentIdentity.foregroundIdentifier(for: agent), app)
        }
        XCTAssertEqual(DirectAgentIdentity.foregroundIdentifier(for: nil), "io.github.codewithinferno.wali.WALI")
        for identifier in [
            "com.wali.WALIAgent", "com.wali.store.WALIAgent", "com.wali.store.development.WALIAgent",
            "io.github.codewithinferno.wali.WALIAgent.spoof", "unknown.development.WALIAgent", "",
        ] {
            XCTAssertNil(DirectAgentIdentity.foregroundIdentifier(for: identifier), identifier)
        }
    }

    func testReleaseServiceAndPrivateWorkerLookupStayInTheSameNamespace() {
        XCTAssertEqual(AgentServiceName.current, "io.github.codewithinferno.wali.WALIAgent.control")
        XCTAssertEqual(TranscoderServiceName.identifier(for: nil), "io.github.codewithinferno.wali.WALITranscoder")
        for prefix in [
            "io.github.codewithinferno.wali", "com.wali.debug", "com.wali.development",
            "com.wali.store", "com.wali.store.development",
        ] {
            XCTAssertEqual(TranscoderServiceName.identifier(for: prefix + ".WALIAgent"), prefix + ".WALITranscoder")
        }
    }

    func testReleaseLibraryAndSharedQuarantineUseNewNamespacesWithoutChangingOtherEditions() throws {
        let base = URL(fileURLWithPath: "/private/tmp/WALI-Identity-Paths", isDirectory: true)
        let fileManager = IdentityPathsFileManager(base: base)
        for prefix in [
            "io.github.codewithinferno.wali", "com.wali.debug", "com.wali.development",
            "com.wali.store", "com.wali.store.development",
        ] {
            let paths = try LibraryPaths.applicationSupport(fileManager: fileManager, bundleIdentifier: prefix + ".WALIAgent")
            XCTAssertEqual(paths.root, base.appendingPathComponent(prefix + ".WALIAgent/Library", isDirectory: true))
            XCTAssertEqual(paths.stateFile, paths.root.appendingPathComponent("Metadata/runtime-state.json"))
            let quarantine = try CatalogInstallCoordinator.defaultQuarantineRoot(
                bundleIdentifier: prefix + ".WALIAgent", fileManager: fileManager
            )
            XCTAssertEqual(quarantine, base.appendingPathComponent(prefix + "/CatalogQuarantine", isDirectory: true))
        }
    }
}

private final class IdentityPathsFileManager: FileManager, @unchecked Sendable {
    let base: URL
    init(base: URL) { self.base = base; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        XCTAssertEqual(directory, .applicationSupportDirectory)
        return base
    }
}
#endif
