import Foundation
import WALICatalogRuntime
import XCTest

@MainActor
final class CatalogInstallAcknowledgementStoreTests: XCTestCase {
    private let subject = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private func entry() throws -> CatalogInstallAcknowledgement {
        try CatalogInstallAcknowledgement(subjectID: subject, wallpaperID: "33333333-3333-4333-8333-333333333333",
            releaseID: "44444444-4444-4444-8444-444444444444", receipt: "55555555-5555-4555-8555-555555555555",
            manifestDigest: String(repeating: "a", count: 64), idempotencyKey: "test_0000000000000001", expiresAt: .now.addingTimeInterval(300))
    }

    func testDuplicateAcknowledgementSurvivesRelaunchWithoutChangingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("acknowledgements.json")
        let value = try entry()
        let first = CatalogInstallAcknowledgementStore(fileURL: url)
        try await first.enqueue(value)
        try await first.enqueue(value)
        let reopened = CatalogInstallAcknowledgementStore(fileURL: url)
        let restored = try await reopened.pending(subjectID: subject)
        XCTAssertEqual(restored, [value])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let foreign = try await reopened.pending(subjectID: other)
        XCTAssertTrue(foreign.isEmpty)
        try await reopened.remove(value)
        let afterSuccess = try await CatalogInstallAcknowledgementStore(fileURL: url).pending(subjectID: subject)
        XCTAssertTrue(afterSuccess.isEmpty)
    }

    func testUnknownVersionCannotOverwriteRecoveryBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("acknowledgements.json")
        let original = Data(#"{"schemaVersion":2,"entries":[]}"#.utf8)
        try original.write(to: url)
        let store = CatalogInstallAcknowledgementStore(fileURL: url)
        do { try await store.enqueue(entry()); XCTFail("Unknown recovery format must be rejected") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExpiredReceiptRetainsExactReplayForLostSuccessThenAgesOut() async throws {
        let value = try entry()
        let store = CatalogInstallAcknowledgementStore()
        try await store.enqueue(value)
        let afterExpiry = try await store.pending(subjectID: subject, now: value.expiresAt.addingTimeInterval(60))
        XCTAssertEqual(afterExpiry, [value], "A completed replay may still be accepted after original receipt expiry")
        let afterRetention = try await store.pending(subjectID: subject, now: value.expiresAt.addingTimeInterval(8 * 86_400))
        XCTAssertTrue(afterRetention.isEmpty)
    }

    func testSameReceiptCannotAcquireAnotherCommandIdentity() async throws {
        let value = try entry()
        let store = CatalogInstallAcknowledgementStore()
        try await store.enqueue(value)
        let changed = try CatalogInstallAcknowledgement(subjectID: value.subjectID, wallpaperID: value.wallpaperID,
            releaseID: value.releaseID, receipt: value.receipt, manifestDigest: value.manifestDigest,
            idempotencyKey: "test_0000000000000002", expiresAt: value.expiresAt)
        do { try await store.enqueue(changed); XCTFail("Receipt identity cannot change on retry") }
        catch CatalogAcknowledgementError.conflictingRecord {}
        let remaining = try await store.pending(subjectID: subject)
        XCTAssertEqual(remaining, [value])
    }

    func testVersionedFixtureLoadsAndFutureFixtureFailsClosed() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let current = CatalogInstallAcknowledgementStore(fileURL: root.appendingPathComponent("Fixtures/Catalog/acknowledgements-v1.json"))
        let values = try await current.pending(subjectID: subject, now: Date(timeIntervalSinceReferenceDate: 809999900))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.idempotencyKey, "fixture_0000000000000001")
        let future = CatalogInstallAcknowledgementStore(fileURL: root.appendingPathComponent("Fixtures/Catalog/invalid/acknowledgements-future-version.json"))
        do { _ = try await future.pending(subjectID: subject); XCTFail("Future schema must fail before write") }
        catch CatalogAcknowledgementError.invalidStorage {}
    }

    func testProductionProjectAndEditionHaveSeparateRecoveryLocations() throws {
        let a = try CatalogInstallAcknowledgementStore.defaultURL(bundleIdentifier: "com.wali.debug.WALI", projectURL: URL(string: "https://first.supabase.co")!)
        let b = try CatalogInstallAcknowledgementStore.defaultURL(bundleIdentifier: "com.wali.debug.WALI", projectURL: URL(string: "https://second.supabase.co")!)
        let c = try CatalogInstallAcknowledgementStore.defaultURL(bundleIdentifier: "io.github.codewithinferno.wali.WALI", projectURL: URL(string: "https://first.supabase.co")!)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
