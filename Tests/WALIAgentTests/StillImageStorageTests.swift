import Foundation
import WALIEngine
import WALIModel
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class StillImageStorageTests: XCTestCase {
    func testStillRecordCarriesImageVariantAndNoVideoTiming() throws {
        let record = try makeRecord(still: true)
        XCTAssertEqual(record.mediaKind, .still)
        XCTAssertEqual(Set(record.artifacts.map(\.role)), [.masterImage, .posterImage])
        XCTAssertNil(record.masterURL)
        XCTAssertNil(record.previewURL)
        XCTAssertNil(record.durationSeconds)
        XCTAssertEqual(record.release.variants.first?.rendererRequirement.rendererID, .waliImage)
        let item = try LibraryRecordFactory.makeEngineItem(from: record)
        guard case let .still(url) = item.mediaContent else { return XCTFail("Image became video") }
        XCTAssertEqual(url, record.imageURL)
        XCTAssertEqual(try JSONDecoder().decode(CommittedLibraryRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testStillRecordRejectsAnIndependentlyVerifiedFourKPoster() throws {
        let master = try artifact(role: "master_image", kind: "png_image", digest: "a")
        let poster = try artifact(role: "poster_image", kind: "heic_image", digest: "c", width: 3_840, height: 2_160)
        XCTAssertThrowsError(try LibraryRecordFactory.makeRecord(itemID: UUID(), displayName: "Still",
            sourceFileName: "still.png", sourceDigest: master.digest, artifacts: [master, poster]))
    }

    func testImageCannotBeCommittedAsVideoOrWithHybridArtifacts() throws {
        let record = try makeRecord(still: true)
        XCTAssertThrowsError(try CommittedLibraryRecord(item: record.item, release: record.release,
            sourceDigest: record.sourceDigest, sourceFileName: record.sourceFileName,
            mediaKind: .video, artifacts: record.artifacts))
        let mixed = try record.artifacts + [artifact(role: "preview_video", kind: "hevc_video", digest: "d", duration: 1)]
        XCTAssertThrowsError(try LibraryRecordFactory.makeRecord(itemID: UUID(), displayName: "Mixed",
            sourceFileName: "mixed.png", sourceDigest: record.sourceDigest, artifacts: mixed))
    }

    func testRevisionTwoRequiresKindAndLegacyMigrationInfersOnlyExactVideoSet() throws {
        for still in [false, true] {
            let original = try makeRecord(still: still)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RuntimeSnapshot(library: [original]))) as? [String: Any])
            var records = try XCTUnwrap(root["library"] as? [[String: Any]])
            records[0].removeValue(forKey: "media_kind")
            root["library"] = records
            XCTAssertThrowsError(try JSONDecoder().decode(RuntimeSnapshot.self, from: JSONSerialization.data(withJSONObject: root)))
            root["schemaRevision"] = 1
            if still {
                XCTAssertThrowsError(try JSONDecoder().decode(RuntimeSnapshot.self, from: JSONSerialization.data(withJSONObject: root)))
            } else {
                let migrated = try JSONDecoder().decode(RuntimeSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
                XCTAssertEqual(migrated.library, [original])
                XCTAssertEqual(migrated.library.first?.mediaKind, .video)
            }
        }
    }

    func testUnknownNewerSnapshotCannotMutateOrReplaceUserState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let initial = RuntimeStore(paths: paths)
        try await initial.open()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.stateFile)) as? [String: Any])
        object["schemaRevision"] = 999
        let futureBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try futureBytes.write(to: paths.stateFile, options: [.atomic])
        let future = RuntimeStore(paths: paths)
        do { try await future.open(); XCTFail("Opened a future snapshot") }
        catch { XCTAssertEqual(error as? StorageError, .unsupportedSchema(epoch: 1, revision: 999)) }
        do { try await future.updatePreferences(.init()); XCTFail("Mutated a rejected snapshot") }
        catch { XCTAssertEqual(error as? StorageError, .stateNotOpened) }
        XCTAssertEqual(try Data(contentsOf: paths.stateFile), futureBytes)
    }

    #if !WALI_APP_STORE
    func testImageNeverEntersVideoLockScreenHelper() throws {
        let record = try makeRecord(still: true)
        let item = try LibraryRecordFactory.makeEngineItem(from: record)
        let snapshot = EngineSnapshot(items: [item], displays: [.init(id: "fixture-display", name: "Main",
            pixelWidth: 1920, pixelHeight: 1080, isMain: true, assignedItemID: item.id)])
        XCTAssertTrue(WALIAgentController.lockScreenAssignments(from: snapshot, durable: RuntimeSnapshot(library: [record])).isEmpty)
    }
    #endif

    func testStoreStillPresentationCopiesOnlyBoundedPoster() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let group = root.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at: paths.objects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let master = paths.objects.appendingPathComponent("image.png")
        let poster = paths.objects.appendingPathComponent("poster.heic")
        try Data(repeating: 9, count: 128).write(to: master)
        try Data(repeating: 4, count: 4).write(to: poster)
        let item = AgentLibraryItem(id: UUID(), name: "Image", createdAt: Date(), mediaContent: .still(imageURL: master),
            pixelWidth: 1920, pixelHeight: 1080, posterURL: poster, contentDigest: String(repeating: "a", count: 64))
        let snapshot = AgentSnapshot(revision: .init(rawValue: 0), items: [item])
        let projected = try StorePresentationCache(paths: paths, groupRoot: group, budgetBytes: 8).prepare([item.id], snapshot: snapshot)
        let copy = try XCTUnwrap(projected.items.first)
        guard case let .still(url) = copy.mediaContent else { return XCTFail("Lost still kind") }
        XCTAssertEqual(url, copy.posterURL)
        XCTAssertTrue(url.path.hasPrefix(group.path + "/"))
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 4, count: 4))
        XCTAssertEqual(projected.resourceUsage.storageUsedBytes, 4)
        XCTAssertEqual(try Data(contentsOf: master), Data(repeating: 9, count: 128))
    }

    private func makeRecord(still: Bool) throws -> CommittedLibraryRecord {
        let files: [StoredArtifact]
        if still {
            files = try [artifact(role: "master_image", kind: "png_image", digest: "a"),
                         artifact(role: "poster_image", kind: "heic_image", digest: "c")]
        } else {
            files = try [artifact(role: "master_video", kind: "hevc_video", digest: "a", duration: 2),
                         artifact(role: "preview_video", kind: "hevc_video", digest: "b", duration: 2),
                         artifact(role: "poster_image", kind: "heic_image", digest: "c")]
        }
        return try LibraryRecordFactory.makeRecord(itemID: UUID(), displayName: "Existing Wallpaper",
            sourceFileName: still ? "image.png" : "video.mp4", sourceDigest: files[0].digest, artifacts: files)
    }

    private func artifact(role: String, kind: String, digest: String, duration: Double? = nil, width: Int = 1_920, height: Int = 1_080) throws -> StoredArtifact {
        var object: [String: Any] = ["role": role, "mediaKind": kind,
            "digest": ["algorithm": "sha256", "value": String(repeating: digest, count: 64)],
            "byteCount": 4, "objectURL": URL(fileURLWithPath: "/tmp/" + digest).absoluteString,
            "pixelSize": ["width": width, "height": height]]
        if let duration { object["durationSeconds"] = duration }
        return try JSONDecoder().decode(StoredArtifact.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
