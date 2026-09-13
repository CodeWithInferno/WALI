import CryptoKit
import Foundation
import Supabase
import XCTest
@testable import WALICatalogRuntime

final class AccountDeletionReceiptTests: XCTestCase {
    func testReceiptPersistsBeforeSubmissionAndRestoresSameCommitmentAfterSignOut() async throws {
        let memory = CatalogMemoryAuthStorage()
        let store = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway())
        let subject = UUID().uuidString.lowercased(), key = UUID().uuidString.lowercased()
        let admission = try await store.prepare(subjectID: subject, expectedProfileRevision: 7, idempotencyKey: key)
        let restored = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway())
        let replay = try await restored.prepare(subjectID: subject, expectedProfileRevision: 99, idempotencyKey: UUID().uuidString.lowercased())
        XCTAssertEqual(admission, replay)
        XCTAssertEqual(admission.expectedProfileRevision, 7)
        XCTAssertEqual(admission.statusCapabilityHash.count, 64)
        let summaries = try await restored.summaries()
        XCTAssertEqual(summaries.count, 1)
    }
    func testCompletionPurgesCapabilityAndAccountMappingButKeepsMinimalConfirmation() async throws {
        let memory = CatalogMemoryAuthStorage()
        let store = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway(completed: true))
        let subject = UUID().uuidString.lowercased()
        let admission = try await store.prepare(subjectID: subject, expectedProfileRevision: 1, idempotencyKey: UUID().uuidString.lowercased())
        let summary = try await store.refresh(id: admission.requestID)
        XCTAssertNotNil(summary?.confirmation)
        XCTAssertFalse(summary?.needsRefresh ?? true)
        let data = try XCTUnwrap(memory.retrieve(key: AccountDeletionReceiptStore.storageItemName))
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains(subject))
        XCTAssertFalse(encoded.contains("capability"))
        XCTAssertFalse(encoded.contains("idempotencyKey"))
        let restored = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway())
        let confirmations = try await restored.summaries()
        XCTAssertEqual(confirmations.first?.confirmation, summary?.confirmation)
    }
    func testFailedAutomaticRequestKeepsRefreshingAfterRelaunchUntilCompletion() async throws {
        let memory = CatalogMemoryAuthStorage()
        let store = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway(statusOverride: .failed))
        let admission = try await store.prepare(subjectID: UUID().uuidString.lowercased(), expectedProfileRevision: 1, idempotencyKey: UUID().uuidString.lowercased())
        let failed = try await store.refresh(id: admission.requestID)
        XCTAssertTrue(failed?.needsRefresh ?? false)
        let restored = AccountDeletionReceiptStore(storage: memory, gateway: ReceiptGateway(completed: true))
        let restoredSummaries = try await restored.summaries()
        XCTAssertTrue(restoredSummaries.first?.needsRefresh ?? false)
        let completed = try await restored.refresh(id: admission.requestID)
        XCTAssertNotNil(completed?.confirmation)
        XCTAssertFalse(completed?.needsRefresh ?? true)
    }
    func testDifferentAccountsKeepSeparateReceiptsAndPendingHasNoExpiry() async throws {
        let store = AccountDeletionReceiptStore(storage: CatalogMemoryAuthStorage(), gateway: ReceiptGateway())
        let first = try await store.prepare(subjectID: UUID().uuidString.lowercased(), expectedProfileRevision: 1, idempotencyKey: UUID().uuidString.lowercased())
        let second = try await store.prepare(subjectID: UUID().uuidString.lowercased(), expectedProfileRevision: 1, idempotencyKey: UUID().uuidString.lowercased())
        XCTAssertNotEqual(first.statusCapabilityHash, second.statusCapabilityHash)
        let pending = try await store.refresh(id: first.requestID)
        XCTAssertNil(pending?.status?.statusExpiresAt)
        XCTAssertTrue(pending?.needsRefresh ?? false)
    }
}
private struct ReceiptGateway: AccountDeletionReceiptGateway {
    var completed = false
    var statusOverride: AccountDeletionReceiptStatus.Status?
    func status(requestID: String, capability: String) async throws -> AccountDeletionReceiptStatus {
        let requested = Date(timeIntervalSince1970: 1_000_000), done = Date(timeIntervalSince1970: 2_000_000)
        return .init(status: statusOverride ?? (completed ? .completed : .processing), stage: completed ? .completed : .cleanup,
            requestedAt: requested, completedAt: completed ? done : nil, statusExpiresAt: completed ? done.addingTimeInterval(30*86_400) : nil,
            retainedCategories: [], appleActionRequired: false)
    }
}
