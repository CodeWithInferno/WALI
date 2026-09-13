import Foundation
import XCTest
import WALICatalog
@testable import WALICatalogRuntime

@MainActor
final class CreatorBlockingTests: XCTestCase {
    let viewer = "00000000-0000-0000-0000-000000000003"
    let creator = "00000000-0000-0000-0000-000000000002"
    let other = "00000000-0000-0000-0000-000000000006"

    func testAnonymousChoicesSurviveSignInWithoutBeingUploaded() async throws {
        let store = MemoryAnonymousBlocks()
        let gateway = ScriptedBlockGateway(subject: viewer)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: store)
        try await model.setBlocked(creatorID: creator, desired: true)
        XCTAssertEqual(model.blockedCreatorIDs, [creator])
        model.updateSubject(viewer)
        _ = try await model.refresh()
        XCTAssertTrue(model.blockedCreatorIDs.isEmpty)
        let writes = await gateway.writes
        XCTAssertTrue(writes.isEmpty)
        model.updateSubject(nil)
        _ = try await model.refresh()
        XCTAssertEqual(model.blockedCreatorIDs, [creator])
    }

    func testOldAccountResponseCannotRestorePrivatePreferences() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer, hold: true)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        let task = Task { try await model.refresh() }
        await gateway.waitForRead()
        model.updateSubject(other)
        await gateway.release()
        do { _ = try await task.value; XCTFail("Old account result applied") }
        catch is CancellationError {}
        XCTAssertTrue(model.blockedCreatorIDs.isEmpty)
        XCTAssertFalse(model.isReady)
    }

    func testFailedRequiredRefreshFailsClosed() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        let old = try await model.refresh()
        await gateway.fail()
        do { _ = try await model.refresh(); XCTFail("Expected failed refresh") } catch {}
        XCTAssertFalse(model.isReady)
        XCTAssertThrowsError(try model.validate(old))
    }

    func testSameGenerationRefreshKeepsSnapshotButChangeInvalidatesIt() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        let old = try await model.refresh()
        _ = try await model.refresh()
        XCTAssertNoThrow(try model.validate(old))
        await gateway.setRows([try row(creator, revision: 1)], generation: 1)
        _ = try await model.refresh()
        XCTAssertThrowsError(try model.validate(old))
        XCTAssertEqual(model.blockedCreatorIDs, [creator])
    }

    func testReblockUsesInactiveRevisionAndSamePendingKeyOnRetry() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer)
        await gateway.setLookup(try row(creator, revision: 2, active: false))
        await gateway.failNextWrite()
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        do { try await model.setBlocked(creatorID: creator, desired: true); XCTFail("Expected transport failure") } catch {}
        XCTAssertFalse(model.isReady, "An uncertain mutation cannot reuse old catalog preferences")
        try await model.setBlocked(creatorID: creator, desired: true)
        let writes = await gateway.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].revision, 2)
        XCTAssertEqual(writes[0].key, writes[1].key)
        XCTAssertEqual(model.blockedCreatorIDs, [creator])
    }

    func testConcurrentRefreshCallersShareOneSuccessfulResult() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer, hold: true)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        let first = Task { try await model.refresh() }
        await gateway.waitForRead()
        var secondEntered = false
        let second = Task { secondEntered = true; return try await model.refresh() }
        while !secondEntered { await Task.yield() }
        await gateway.release()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, b)
        XCTAssertTrue(model.isReady)
    }

    func testAnonymousCapDoesNotEvictAndAllowsUnblock() async throws {
        let ids = Set((1...10_000).map { String(format: "10000000-0000-0000-0000-%012d", $0) })
        let store = MemoryAnonymousBlocks(ids)
        let model = CreatorBlockingModel(gateway: nil, anonymousStore: store)
        _ = try await model.refresh()
        do { try await model.setBlocked(creatorID: creator, desired: true); XCTFail("Cap was bypassed") }
        catch { XCTAssertEqual(error as? CreatorBlockingError, .limitReached) }
        XCTAssertEqual(model.blockedCreatorIDs, ids)
        try await model.setBlocked(creatorID: ids.sorted()[0], desired: false)
        XCTAssertEqual(model.blockedCreatorIDs.count, 9_999)
    }

    func testMalformedStoredAnonymousIDsFailClosedWithoutErasingThem() async throws {
        let suite = "wali.creator-block-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["not-an-id"], forKey: "creator-blocks.anonymous.v1")
        let model = CreatorBlockingModel(gateway: nil, anonymousStore: UserDefaultsAnonymousCreatorBlocks(defaults: defaults))
        do { _ = try await model.refresh(); XCTFail("Corrupt preferences silently cleared") } catch {}
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(defaults.stringArray(forKey: "creator-blocks.anonymous.v1"), ["not-an-id"])
    }

    func testDecodingRejectsDuplicateAndUnboundedServerRows() throws {
        let valid = "{\"subject_id\":\"\(viewer)\",\"generation\":1,\"items\":[{\"creator_id\":\"\(creator)\",\"active\":true,\"revision\":1,\"display_name\":null,\"handle\":null}],\"next_cursor\":null}"
        XCTAssertNoThrow(try JSONDecoder().decode(CreatorBlockPage.self, from: Data(valid.utf8)))
        let duplicate = valid.replacingOccurrences(of: "],\"next_cursor\"", with: "," + valid.components(separatedBy: "[" )[1].components(separatedBy: "]")[0] + "],\"next_cursor\"")
        XCTAssertThrowsError(try JSONDecoder().decode(CreatorBlockPage.self, from: Data(duplicate.utf8)))
        let invalid = valid.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":9007199254740992")
        XCTAssertThrowsError(try JSONDecoder().decode(CreatorBlockPage.self, from: Data(invalid.utf8)))
    }

    func testHiddenRemovalClearsBusyStateAfterConcurrentBlockRefresh() async throws {
        let gateway = ScriptedBlockGateway(subject: viewer)
        let model = CreatorBlockingModel(gateway: gateway, anonymousStore: MemoryAnonymousBlocks())
        model.updateSubject(viewer)
        let item = try CreatorHiddenInteraction(targetID: creator, kind: .saved, active: true, revision: 1)
        await gateway.holdRemoval(of: item)
        try await model.loadHiddenInteractions()
        let removal = Task { try await model.removeHiddenInteraction(item) }
        await gateway.waitForRemoval()
        await gateway.setRows([try row(other, revision: 1)], generation: 1)
        _ = try await model.refresh()
        await gateway.releaseRemoval()
        do { try await removal.value; XCTFail("Stale completion admitted") } catch is CancellationError {}
        XCTAssertFalse(model.isWorking, "A changed block generation must not leave cleanup permanently busy")
    }

    func testAnonymousWindowsPreserveEachOthersStoredChoices() async throws {
        let store = MemoryAnonymousBlocks()
        let first = CreatorBlockingModel(gateway: nil, anonymousStore: store)
        let second = CreatorBlockingModel(gateway: nil, anonymousStore: store)
        _ = try await first.refresh(); _ = try await second.refresh()
        try await first.setBlocked(creatorID: creator, desired: true)
        try await second.setBlocked(creatorID: other, desired: true)
        XCTAssertEqual(store.ids, [creator, other])
    }

    private func row(_ id: String, revision: UInt64, active: Bool = true) throws -> CreatorBlockRow {
        try CreatorBlockRow(creatorID: id, active: active, revision: revision, displayName: nil, handle: nil)
    }
}

@MainActor
private final class MemoryAnonymousBlocks: AnonymousCreatorBlockStoring {
    var ids: Set<String>
    init(_ ids: Set<String> = []) { self.ids = ids }
    func load() throws -> Set<String> { ids }
    func save(_ ids: Set<String>) throws { self.ids = ids }
}

private actor ScriptedBlockGateway: CreatorBlockingGateway {
    struct Write: Sendable { let revision: UInt64; let key: String }
    let subject: String
    var rows: [CreatorBlockRow] = []
    var generation: UInt64 = 0
    var lookup: CreatorBlockRow?
    var writes: [Write] = []
    var hold: Bool
    var waiting: CheckedContinuation<Void, Never>?
    var readStarted = false
    var failed = false
    var writeFails = false
    var hidden: [CreatorHiddenInteraction] = []
    var removalStarted = false
    var removalContinuation: CheckedContinuation<Void, Never>?
    init(subject: String, hold: Bool = false) { self.subject = subject; self.hold = hold }
    func waitForRead() async { while !readStarted { await Task.yield() } }
    func release() { hold = false; waiting?.resume(); waiting = nil }
    func fail() { failed = true }
    func failNextWrite() { writeFails = true }
    func setRows(_ rows: [CreatorBlockRow], generation: UInt64) { self.rows = rows; self.generation = generation }
    func setLookup(_ row: CreatorBlockRow) { lookup = row }
    func creatorBlocks(cursor: String?, selectedCreatorID: String?) async throws -> CreatorBlockPage {
        readStarted = true
        if hold { await withCheckedContinuation { waiting = $0 } }
        if failed { throw CreatorBlockingError.unavailable }
        return try CreatorBlockPage(subjectID: subject, generation: generation,
            items: selectedCreatorID == nil ? rows : lookup.map { [$0] } ?? [], nextCursor: nil)
    }
    func setCreatorBlock(creatorID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CreatorBlockResult {
        writes.append(Write(revision: expectedRevision, key: idempotencyKey))
        if writeFails { writeFails = false; throw CreatorBlockingError.unavailable }
        generation += 1
        rows = desired ? [try CreatorBlockRow(creatorID: creatorID, active: true, revision: expectedRevision + 1, displayName: nil, handle: nil)] : []
        return try CreatorBlockResult(subjectID: subject, creatorID: creatorID, desired: desired,
            revision: expectedRevision + 1, generation: generation)
    }
    func holdRemoval(of item: CreatorHiddenInteraction) { hidden = [item] }
    func waitForRemoval() async { while !removalStarted { await Task.yield() } }
    func releaseRemoval() { removalContinuation?.resume(); removalContinuation = nil }
    func hiddenCreatorInteractions(cursor: String?) async throws -> CreatorHiddenInteractionPage {
        try CreatorHiddenInteractionPage(subjectID: subject, generation: generation, items: hidden, nextCursor: nil)
    }
    func removeHiddenCreatorInteraction(_ value: CreatorHiddenInteraction, idempotencyKey: String) async throws {
        removalStarted = true
        await withCheckedContinuation { removalContinuation = $0 }
    }
}
