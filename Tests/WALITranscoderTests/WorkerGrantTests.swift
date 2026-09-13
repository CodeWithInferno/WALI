import Darwin
import Foundation
import WALIWire
import XCTest
@testable import WALITranscoderRuntime

private final class ScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func start() { lock.lock(); starts += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts, stops) }
}

final class WorkerGrantTests: XCTestCase {
    func testDeniedGrantDoesNotFallBackToAReadablePath() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { _ in (fixture.source, false) }, start: { _ in probe.start(); return false }, stop: { _ in probe.stop() })
        XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations))
        XCTAssertEqual(probe.counts.0, 1)
        XCTAssertEqual(probe.counts.1, 0)
    }

    func testWritableSourceGrantIsRejectedAndItsScopeIsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { _ in (fixture.source, false) }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() })
        XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations)) { error in
            guard case WorkerGrantError.sourceWritable = error else { return XCTFail("Unexpected grant error: \(error)") }
        }
        XCTAssertEqual(probe.counts.1, 1)
    }

    func testFixtureScopeLifetimeIsBalancedAndCloseIsIdempotent() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // This fake-scope fixture tests ownership only. POSIX mode is not proof
        // of App Sandbox grant attenuation; signed tests must use mode 0600.
        XCTAssertEqual(chmod(fixture.source.path, mode_t(0o400)), 0)
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { data in
            (data == Data([1]) ? fixture.source : fixture.staging, false)
        }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() })
        let lease = try WorkerScopedMediaAccess.open(fixture.request, operations: operations)
        lease.close()
        lease.close()
        XCTAssertEqual(probe.counts.0, 2)
        XCTAssertEqual(probe.counts.1, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    func testStaleGrantNeverStartsScopedAccess() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { _ in (fixture.source, true) }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() })
        XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations))
        XCTAssertEqual(probe.counts.0, 0)
        XCTAssertEqual(probe.counts.1, 0)
    }

    func testImplicitResolutionAccessIsBalancedWithExplicitAttemptAccess() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // POSIX read-only mode isolates lifetime accounting in this hostless fixture.
        // Signed native acceptance must prove sandbox attenuation on writable input.
        XCTAssertEqual(chmod(fixture.source.path, mode_t(0o400)), 0)
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { data in
            probe.start()
            return (data == Data([1]) ? fixture.source : fixture.staging, false)
        }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() },
            resolutionStartsAccess: true)
        let lease = try WorkerScopedMediaAccess.open(fixture.request, operations: operations)
        XCTAssertEqual(probe.counts.0, 4)
        XCTAssertEqual(probe.counts.1, 2, "Each resolver-owned access ends after explicit attempt access is acquired")
        lease.close()
        lease.close()
        XCTAssertEqual(probe.counts.0, probe.counts.1)
    }

    func testImplicitResolutionAccessClosesWhenGrantIsStaleOrMismatched() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for stale in [true, false] {
            let probe = ScopeProbe()
            let operations = WorkerBookmarkOperations(resolve: { _ in
                probe.start()
                return (stale ? fixture.source : fixture.staging, stale)
            }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() },
                resolutionStartsAccess: true)
            XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations)) { error in
                if stale {
                    guard case WorkerGrantError.staleGrant = error else { return XCTFail("Unexpected grant error: \(error)") }
                } else {
                    guard case WorkerGrantError.identityMismatch = error else { return XCTFail("Unexpected grant error: \(error)") }
                }
            }
            XCTAssertEqual(probe.counts.0, 1)
            XCTAssertEqual(probe.counts.1, 1)
        }
    }

    func testImplicitResolutionDoesNotBypassExplicitScopeDenialOrWritableSource() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for granted in [false, true] {
            let probe = ScopeProbe()
            let operations = WorkerBookmarkOperations(resolve: { _ in
                probe.start()
                return (fixture.source, false)
            }, start: { _ in
                if granted { probe.start() }
                return granted
            }, stop: { _ in probe.stop() }, resolutionStartsAccess: true)
            XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations)) { error in
                if granted {
                    guard case WorkerGrantError.sourceWritable = error else { return XCTFail("Unexpected grant error: \(error)") }
                } else {
                    guard case WorkerGrantError.scopeDenied = error else { return XCTFail("Unexpected grant error: \(error)") }
                }
            }
            XCTAssertEqual(probe.counts.0, probe.counts.1)
        }
    }

    func testStaleStagingWithRecordedIdentityRenewsBeforeMediaAccess() throws {
        try assertRecordedIdentityRenews(staleSource: false)
    }

    func testStaleSourceWithRecordedIdentityRenewsBeforeMediaAccess() throws {
        try assertRecordedIdentityRenews(staleSource: true)
    }

    func testRenewalRejectsMissingRecordedFileOrVolumeIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renew = try XCTUnwrap(WorkerBookmarkOperations.system.renew)
        for keys: Set<URLResourceKey> in [[], [.fileResourceIdentifierKey], [.volumeIdentifierKey]] {
            let data = try fixture.source.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
            XCTAssertThrowsError(try renew(data, fixture.source, false)) { error in
                guard case WorkerGrantError.identityMismatch = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testRenewalRejectsReplacedFileAndDirectoryAtTheSamePath() throws {
        let renew = try XCTUnwrap(WorkerBookmarkOperations.system.renew)
        for isDirectory in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var target = isDirectory ? fixture.staging : fixture.source
            let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
            let data = try target.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
            let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: isDirectory)
            if isDirectory { try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false) }
            else { try Data([9, 8, 7]).write(to: replacement) }
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: replacement, to: target)
            // Resolved bookmarks may carry old resource metadata. Explicitly
            // seed that cache while the path now names a different object.
            let recorded = try XCTUnwrap(URL.resourceValues(forKeys: keys, fromBookmarkData: data))
            target.setTemporaryResourceValue(try XCTUnwrap(recorded.fileResourceIdentifier as? Data), forKey: .fileResourceIdentifierKey)
            target.setTemporaryResourceValue(try XCTUnwrap(recorded.volumeIdentifier as? Data), forKey: .volumeIdentifierKey)
            XCTAssertThrowsError(try renew(data, target, isDirectory)) { error in
                guard case WorkerGrantError.identityMismatch = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testRenewalRejectsWrongTypeAndSymlink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renew = try XCTUnwrap(WorkerBookmarkOperations.system.renew)
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        let data = try fixture.source.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
        XCTAssertThrowsError(try renew(data, fixture.source, true)) { error in
            guard case WorkerGrantError.invalidFile = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let link = fixture.root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try renew(data, link, false)) { error in
            guard case WorkerGrantError.identityMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testStaleGrantDeniedScopeNeverRenewsAndReleasesImplicitAccess() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { _ in
            probe.start()
            return (fixture.source, true)
        }, start: { _ in false }, stop: { _ in probe.stop() }, resolutionStartsAccess: true,
            renew: { _, _, _ in XCTFail("Denied authority must never renew"); throw WorkerGrantError.staleGrant })
        XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations))
        XCTAssertEqual(probe.counts.0, 1)
        XCTAssertEqual(probe.counts.0, probe.counts.1)
    }

    func testFailedRenewalClosesOriginalAndRenewedScopes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Throw, repeat stale, change URL, or deny the final retained scope.
        for mode in 0..<4 {
            let probe = ScopeProbe()
            let startCalls = ScopeProbe()
            let operations = WorkerBookmarkOperations(resolve: { _ in
                probe.start()
                return (fixture.source, true)
            }, start: { _ in
                startCalls.start()
                if mode == 3 && startCalls.counts.0 == 2 { return false }
                probe.start()
                return true
            }, stop: { _ in probe.stop() }, resolutionStartsAccess: true,
                renew: { _, _, _ in
                    if mode == 0 { throw WorkerGrantError.identityMismatch }
                    probe.start()
                    return (mode == 2 ? fixture.staging : fixture.source, mode == 1)
                })
            XCTAssertThrowsError(try WorkerScopedMediaAccess.open(fixture.request, operations: operations))
            XCTAssertEqual(probe.counts.0, probe.counts.1, "Renewal failure mode \(mode)")
        }
    }

    private func assertRecordedIdentityRenews(staleSource: Bool) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // This hostless fixture checks real Foundation identity metadata and
        // scope ownership; signed native testing proves sandbox attenuation.
        XCTAssertEqual(chmod(fixture.source.path, mode_t(0o400)), 0)
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        let sourceData = try fixture.source.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
        let stagingData = try fixture.staging.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
        let request = StoreTranscoderRequest(request: TranscoderRequest(
            jobID: fixture.request.request.jobID, attemptGeneration: 1,
            sourceBookmark: sourceData, sourceURL: fixture.source,
            stagingDirectoryURL: fixture.staging
        ), stagingBookmark: stagingData)
        let probe = ScopeProbe()
        let operations = WorkerBookmarkOperations(resolve: { data in
            probe.start()
            let source = data == sourceData
            return (source ? fixture.source : fixture.staging, source == staleSource)
        }, start: { _ in probe.start(); return true }, stop: { _ in probe.stop() },
            resolutionStartsAccess: true, renew: { data, url, isDirectory in
                guard let renew = WorkerBookmarkOperations.system.renew else { throw WorkerGrantError.staleGrant }
                let result = try renew(data, url, isDirectory)
                probe.start() // The real renewal returns one implicit acquisition.
                return result
            })
        let access = try WorkerScopedMediaAccess.open(request, operations: operations)
        access.close()
        access.close()
        XCTAssertEqual(probe.counts.0, probe.counts.1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
    }

    private func fixture() throws -> (root: URL, source: URL, staging: URL, request: StoreTranscoderRequest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: source)
        let id = UUID()
        let staging = root.appendingPathComponent(id.uuidString.lowercased() + "-1", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let request = TranscoderRequest(jobID: id, attemptGeneration: 1, sourceBookmark: Data([1]), sourceURL: source, stagingDirectoryURL: staging)
        return (root, source, staging, StoreTranscoderRequest(request: request, stagingBookmark: Data([2])))
    }
}
