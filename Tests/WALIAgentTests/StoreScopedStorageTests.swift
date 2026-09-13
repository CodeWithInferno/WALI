import Foundation
import WALIModel
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class StoreScopedStorageTests: XCTestCase {
    private func videoURLs(_ item: AgentLibraryItem) throws -> (master: URL, preview: URL) {
        guard case let .video(masterURL, previewURL, _) = item.mediaContent else {
            XCTFail("The known video fixture changed media family.")
            throw StorageError.unsupportedMedia
        }
        return (masterURL, previewURL)
    }

    func testShutdownPersistsInterruptionRejectsLateWorkAndPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("selected.mov")
        try Data([1, 2, 3]).write(to: source)
        let paths = try LibraryPaths(root: root.appendingPathComponent("private-library"))
        let store = RuntimeStore(paths: paths)
        try await store.open()
        let context = try await store.beginImport(sourceURL: source, sourceBookmark: Data([9]), idempotencyKey: IdempotencyKey(UUID().uuidString.lowercased()), expectedEngineRevision: .init(rawValue: 0))
        try await store.markImportDispatched(jobID: context.jobID, generation: context.generation)
        try await store.interruptActiveImportsForShutdown()
        try await store.interruptActiveImportsForShutdown()
        do {
            try await store.finishImportAttempt(jobID: context.jobID, generation: context.generation, outcome: .succeeded)
            XCTFail("Late worker success was accepted after shutdown")
        } catch { XCTAssertEqual(error as? StorageError, .jobNotInstallable) }
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.stagingDirectoryURL.path))
        let reopened = RuntimeStore(paths: paths)
        try await reopened.open()
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.importJobs.first?.job.attempts.last?.state, .terminal(.interrupted))
        XCTAssertEqual(snapshot.importJobs.first?.sourceBookmark, Data([9]))
        let retried = try await reopened.retryImport(jobID: context.jobID)
        XCTAssertEqual(retried.generation.rawValue, 2)
    }

    func testPresentationCacheIsBoundedReplaceableAndNeverCopiesMaster() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: paths.objects, withIntermediateDirectories: true)
        let group = root.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let master = paths.objects.appendingPathComponent("master.mov")
        let preview = paths.objects.appendingPathComponent("preview.mov")
        let poster = paths.objects.appendingPathComponent("poster.heic")
        try Data(repeating: 3, count: 128).write(to: master)
        try Data(repeating: 2, count: 8).write(to: preview)
        try Data(repeating: 1, count: 4).write(to: poster)
        let item = AgentLibraryItem(id: UUID(), name: "Fixture", createdAt: Date(), duration: 1, pixelWidth: 1, pixelHeight: 1,
                                    masterURL: master, previewURL: preview, posterURL: poster, contentDigest: String(repeating: "a", count: 64))
        let snapshot = AgentSnapshot(revision: .init(rawValue: 0), items: [item])
        let cache = try StorePresentationCache(paths: paths, groupRoot: group, budgetBytes: 12)
        let first = try cache.project(snapshot)
        let projected = try XCTUnwrap(first.items.first)
        XCTAssertEqual(try videoURLs(projected).master, try videoURLs(projected).preview)
        XCTAssertTrue(projected.posterURL.path.hasPrefix(group.path + "/"))
        XCTAssertEqual(first.resourceUsage.storageUsedBytes, 12)
        XCTAssertEqual(try Data(contentsOf: videoURLs(projected).preview), Data(repeating: 2, count: 8))
        try FileManager.default.removeItem(at: projected.posterURL)
        try FileManager.default.createSymbolicLink(at: projected.posterURL, withDestinationURL: master)
        _ = try cache.project(snapshot)
        XCTAssertEqual(try Data(contentsOf: master), Data(repeating: 3, count: 128))
        XCTAssertEqual(try Data(contentsOf: projected.posterURL), Data(repeating: 1, count: 4))
        let empty = try cache.project(AgentSnapshot(revision: .init(rawValue: 1)))
        XCTAssertEqual(empty.resourceUsage.storageUsedBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Presentation").path).isEmpty)
    }

    func testPresentationCacheReopensWithoutReplacingExistingDirectoryOrBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let group = root.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        _ = try StorePresentationCache(paths: paths, groupRoot: group)
        let directory = group.appendingPathComponent("Presentation")
        let retained = directory.appendingPathComponent("existing-preview.mov")
        let bytes = Data([1, 7, 9])
        try bytes.write(to: retained)
        let before = try FileManager.default.attributesOfItem(atPath: directory.path)

        let reopened = try StorePresentationCache(paths: paths, groupRoot: group)
        let after = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
        for key in [FileAttributeKey.systemFileNumber, .ownerAccountID, .posixPermissions] {
            XCTAssertEqual(before[key] as? NSNumber, after[key] as? NSNumber)
        }
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertTrue(try reopened.project(AgentSnapshot(revision: .init(rawValue: 0))).items.isEmpty)
    }

    func testCatalogQuarantineReopensWithoutReplacingAcceptedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try StoreSharedDirectories.quarantine(in: root)
        let source = first.appendingPathComponent("accepted-source.mp4")
        let bytes = Data([2, 4, 8])
        try bytes.write(to: source)
        let before = try FileManager.default.attributesOfItem(atPath: first.path)

        XCTAssertEqual(try StoreSharedDirectories.quarantine(in: root), first)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let after = try FileManager.default.attributesOfItem(atPath: first.path)
        for key in [FileAttributeKey.systemFileNumber, .ownerAccountID, .posixPermissions] {
            XCTAssertEqual(before[key] as? NSNumber, after[key] as? NSNumber)
        }
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, 0o700)
    }

    func testSharedDirectoryReopenRejectsAFileOrSymlinkWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let group = root.appendingPathComponent("Group")
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try Data([3, 6]).write(to: sentinel)
        for name in ["Presentation", "CatalogQuarantine"] {
            let child = group.appendingPathComponent(name)
            let prepare = {
                if name == "Presentation" { _ = try StorePresentationCache(paths: paths, groupRoot: group) }
                else { _ = try StoreSharedDirectories.quarantine(in: group) }
            }
            try Data([5]).write(to: child)
            XCTAssertThrowsError(try prepare())
            XCTAssertEqual(try Data(contentsOf: child), Data([5]))
            try FileManager.default.removeItem(at: child)
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
            XCTAssertThrowsError(try prepare())
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([3, 6]))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: child.path), outside.path)
            try FileManager.default.removeItem(at: child)
        }
    }

    func testPresentationDemandRebuildsOlderItemsAndRejectsStaleOrOversizedRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        try FileManager.default.createDirectory(at: paths.objects, withIntermediateDirectories: true)
        let group = root.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let items = try (0..<12).map { index -> AgentLibraryItem in
            let preview = paths.objects.appendingPathComponent("\(index).mov")
            let poster = paths.objects.appendingPathComponent("\(index).heic")
            try Data(repeating: UInt8(index), count: 4).write(to: preview)
            try Data(repeating: UInt8(index), count: 2).write(to: poster)
            return AgentLibraryItem(id: UUID(), name: "\(index)", createdAt: Date(timeIntervalSince1970: Double(index)), duration: 1,
                                    pixelWidth: 1, pixelHeight: 1, masterURL: preview, previewURL: preview, posterURL: poster,
                                    contentDigest: String(repeating: "a", count: 64))
        }
        let snapshot = AgentSnapshot(revision: .init(rawValue: 0), items: items)
        let cache = try StorePresentationCache(paths: paths, groupRoot: group, budgetBytes: 12)
        let initial = try cache.project(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try videoURLs(initial.items[0]).preview.path))
        let selected = try cache.prepare([items[0].id], snapshot: snapshot)
        XCTAssertEqual(try Data(contentsOf: videoURLs(selected.items[0]).preview), Data(repeating: 0, count: 4))
        XCTAssertLessThanOrEqual(selected.resourceUsage.storageUsedBytes, 12)
        XCTAssertThrowsError(try cache.prepare([UUID()], snapshot: snapshot))
        XCTAssertThrowsError(try cache.prepare(Array(repeating: items[0].id, count: 33), snapshot: snapshot))
        XCTAssertThrowsError(try cache.prepare([items[0].id], snapshot: AgentSnapshot(revision: .init(rawValue: 1))))
        XCTAssertTrue(try selected.items.allSatisfy { try videoURLs($0).master.path.hasPrefix(group.path + "/") })
    }

    #if WALI_APP_STORE
    func testInterruptedCatalogSourceSurvivesUntilFreshVerificationRecoveryRetiresIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let store = RuntimeStore(paths: paths)
        try await store.open()
        let sourceDirectory = paths.staging.appendingPathComponent("catalog-source-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("catalog-source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let context = try await store.beginImport(sourceURL: source, sourceBookmark: Data([9]), idempotencyKey: IdempotencyKey(UUID().uuidString.lowercased()), expectedEngineRevision: .init(rawValue: 0))
        try await store.markImportDispatched(jobID: context.jobID, generation: context.generation)
        try await store.interruptActiveImportsForShutdown()
        try await store.removeAdoptedCatalogSource(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let reopened = RuntimeStore(paths: paths)
        try await reopened.open()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let count = try await reopened.recoverCatalogImportsRequiringFreshVerification()
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.importJobs.first?.job.header.terminalOutcome, .failed)
        XCTAssertEqual(snapshot.importJobs.first?.job.attempts.last?.state, .terminal(.interrupted))
    }
    #endif

    func testGrantCodecRejectsAnUnversionedPersistentBookmarkBeforeAcceptance() {
        XCTAssertThrowsError(try AgentSourceAuthorization.acceptTransient(Data([1, 2, 3])))
        XCTAssertThrowsError(try AgentSourceAuthorization.openPersistent(Data()))
    }
}
