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
