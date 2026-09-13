#if WALI_APP_STORE
import Foundation
@testable import WALICatalogRuntime
import XCTest

final class StoreCatalogQuarantineTests: XCTestCase {
    func testQuarantineReopensWithoutReplacingDirectoryOrChangingRetainedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let directory = try CatalogInstallPreparer.storeQuarantineDirectory(in: root)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        let retained = directory.appendingPathComponent("retained.wali-quarantine.mp4")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: retained)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: directory.path)
        let before = try FileManager.default.attributesOfItem(atPath: directory.path)

        XCTAssertEqual(try CatalogInstallPreparer.storeQuarantineDirectory(in: root), directory)

        let after = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
        for key in [FileAttributeKey.systemFileNumber, .ownerAccountID, .posixPermissions] {
            XCTAssertEqual(before[key] as? NSNumber, after[key] as? NSNumber)
        }
    }

    func testQuarantineRejectsExistingFileAndSymlinkWithoutChangingTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let directory = root.appendingPathComponent("CatalogQuarantine")
        let bytes = Data([2, 4, 6])
        try bytes.write(to: directory)
        XCTAssertThrowsError(try CatalogInstallPreparer.storeQuarantineDirectory(in: root))
        XCTAssertEqual(try Data(contentsOf: directory), bytes)
        try FileManager.default.removeItem(at: directory)
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep")
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)

        XCTAssertThrowsError(try CatalogInstallPreparer.storeQuarantineDirectory(in: root))

        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directory.path), outside.path)
    }

    func testQuarantineRejectsMissingOrSymlinkedParentWithoutCreatingIntermediateDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let missing = root.appendingPathComponent("Missing")
        XCTAssertThrowsError(try CatalogInstallPreparer.storeQuarantineDirectory(in: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let real = root.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        XCTAssertThrowsError(try CatalogInstallPreparer.storeQuarantineDirectory(in: alias))

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), real.path)
    }
}
#endif
