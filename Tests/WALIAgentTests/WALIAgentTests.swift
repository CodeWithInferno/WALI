import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import WALIEngine
import WALIWire
import WALILockScreenWire
import XCTest
@testable import WALIAgentRuntime

final class WALIAgentTests: XCTestCase {
    private let displayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondDisplayID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let spaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let originalAsset = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    private let assetA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let assetB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    func testGlobalActivationUsesOneAssetAndPreservesUnmanagedRootValues() throws {
        let fixture = try makeGlobalStoreFixture()
        let before = try plistRoot(at: fixture.index)
        let timestamp = Date(timeIntervalSince1970: 9_000)
        let editor = WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal,
            now: { timestamp }
        )

        let result = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.patchedNodeCount, 4)
        XCTAssertEqual(try globalSelectedAsset(in: fixture.index, key: "AllSpacesAndDisplays"), assetA)
        XCTAssertEqual(try globalSelectedAsset(in: fixture.index, key: "SystemDefault"), assetA)
        let after = try plistRoot(at: fixture.index)
        XCTAssertTrue((after["Displays"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue((after["Spaces"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(try encodedPlistValue(after["UnmanagedRoot"] as Any),
                       try encodedPlistValue(before["UnmanagedRoot"] as Any))
        XCTAssertTrue(NSDictionary(dictionary: try globalPreservedValues(
            in: after,
            key: "AllSpacesAndDisplays"
        )).isEqual(to: try globalPreservedValues(in: before, key: "AllSpacesAndDisplays")))
        XCTAssertTrue(NSDictionary(dictionary: try globalPreservedValues(
            in: after,
            key: "SystemDefault"
        )).isEqual(to: try globalPreservedValues(in: before, key: "SystemDefault")))
        XCTAssertEqual(try globalDates(in: after, key: "AllSpacesAndDisplays"), [timestamp, timestamp])
        XCTAssertEqual(try globalDates(in: after, key: "SystemDefault"), [timestamp, timestamp])

        _ = try editor.reconcile(assignments: [.init(displayUUID: displayID, assetID: assetA)])
        let idempotent = try plistRoot(at: fixture.index)
        XCTAssertEqual(try globalDates(in: idempotent, key: "AllSpacesAndDisplays"),
                       [timestamp, timestamp])
    }

    func testGlobalDisableRestoresExactFourManagedRootValues() throws {
        let fixture = try makeGlobalStoreFixture()
        let original = try plistRoot(at: fixture.index)
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])

        let result = try editor.reconcile(assignments: [], knownOwnedAssetIDs: [assetA])

        XCTAssertTrue(result.changed)
        XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(to: original))
        let journal = try JSONDecoder().decode(
            GlobalChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertEqual(journal.phase, "committed")
        XCTAssertTrue(journal.originalValues.isEmpty)
    }

    func testPreparedGlobalTransitionRecoversBeforeAndAfterIndexReplacement() throws {
        let original = try globalStoreData()
        let activeA = try globalTargetStoreData(from: original, assetID: assetA)
        let activeB = try globalTargetStoreData(from: original, assetID: assetB)
        for indexAlreadyReplaced in [false, true] {
            let fixture = try makeGlobalStoreFixture(data: indexAlreadyReplaced ? activeB : activeA)
            try writeGlobalChoiceJournal(
                phase: "prepared",
                originalData: original,
                managedAssetIDs: [assetA, assetB],
                sourceAssetID: assetA,
                targetAssetID: assetB,
                expectedData: activeA,
                targetData: activeB,
                to: fixture.journal
            )

            let result = try WallpaperStoreEditor(
                indexURL: fixture.index,
                journalURL: fixture.journal
            ).reconcile(assignments: [.init(displayUUID: displayID, assetID: assetB)])

            XCTAssertTrue(result.changed)
            XCTAssertEqual(try globalSelectedAsset(in: fixture.index, key: "AllSpacesAndDisplays"), assetB)
            _ = try WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
                .reconcile(assignments: [], knownOwnedAssetIDs: [assetA, assetB])
            XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(
                to: try plistRoot(from: original)
            ))
        }
    }

    func testPreparedGlobalDisableRecoversBeforeAndAfterIndexReplacement() throws {
        let original = try globalStoreData()
        let activeA = try globalTargetStoreData(from: original, assetID: assetA)
        for indexAlreadyRestored in [false, true] {
            let fixture = try makeGlobalStoreFixture(data: indexAlreadyRestored ? original : activeA)
            try writeGlobalChoiceJournal(
                phase: "prepared",
                originalData: original,
                managedAssetIDs: [assetA],
                sourceAssetID: assetA,
                targetAssetID: nil,
                expectedData: activeA,
                targetData: original,
                to: fixture.journal
            )

            let result = try WallpaperStoreEditor(
                indexURL: fixture.index,
                journalURL: fixture.journal
            ).reconcile(assignments: [], knownOwnedAssetIDs: [assetA])

            XCTAssertTrue(result.changed)
            XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(
                to: try plistRoot(from: original)
            ))
            let journal = try JSONDecoder().decode(
                GlobalChoiceJournalProbe.self,
                from: Data(contentsOf: fixture.journal)
            )
            XCTAssertTrue(journal.originalValues.isEmpty)
        }
    }

    func testManagedRootExternalChangeFailsClosedWithoutMutation() throws {
        let fixture = try makeGlobalStoreFixture()
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])
        var changed = try plistRoot(at: fixture.index)
        changed["Displays"] = ["External": ["Value": Data("preserve".utf8)]]
        try plistData(changed).write(to: fixture.index)
        let indexBefore = try Data(contentsOf: fixture.index)
        let journalBefore = try Data(contentsOf: fixture.journal)

        XCTAssertThrowsError(try editor.reconcile(
            assignments: [],
            knownOwnedAssetIDs: [assetA]
        )) { error in
            guard case LockScreenCompatibilityError.ownershipConflict = error else {
                return XCTFail("Expected an ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.journal), journalBefore)
    }

    func testDaemonTimestampDriftIsAcceptedButOtherManagedStructureStillMatches() throws {
        let fixture = try makeGlobalStoreFixture()
        let original = try plistRoot(at: fixture.index)
        let editor = WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal,
            now: { Date(timeIntervalSince1970: 9_000) }
        )
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])
        var drifted = try plistRoot(at: fixture.index)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            var node = try XCTUnwrap(drifted[key] as? [String: Any])
            var linked = try XCTUnwrap(node["Linked"] as? [String: Any])
            linked["LastSet"] = Date(timeIntervalSince1970: 10_000)
            linked["LastUse"] = Date(timeIntervalSince1970: 11_000)
            node["Linked"] = linked
            drifted[key] = node
        }
        try plistData(drifted).write(to: fixture.index)

        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetB),
        ], knownOwnedAssetIDs: [assetA, assetB])
        _ = try editor.reconcile(assignments: [], knownOwnedAssetIDs: [assetA, assetB])

        XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(to: original))
    }

    func testDaemonTimestampAllowanceDoesNotPermitOtherGlobalFieldDrift() throws {
        let fixture = try makeGlobalStoreFixture()
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])
        var drifted = try plistRoot(at: fixture.index)
        var node = try XCTUnwrap(drifted["SystemDefault"] as? [String: Any])
        var linked = try XCTUnwrap(node["Linked"] as? [String: Any])
        var content = try XCTUnwrap(linked["Content"] as? [String: Any])
        content["EncodedOptionValues"] = Data("external-change".utf8)
        linked["Content"] = content
        node["Linked"] = linked
        drifted["SystemDefault"] = node
        try plistData(drifted).write(to: fixture.index)
        let indexBefore = try Data(contentsOf: fixture.index)
        let journalBefore = try Data(contentsOf: fixture.journal)

        XCTAssertThrowsError(try editor.reconcile(
            assignments: [],
            knownOwnedAssetIDs: [assetA]
        )) { error in
            guard case LockScreenCompatibilityError.ownershipConflict = error else {
                return XCTFail("Expected an ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.journal), journalBefore)
    }

    func testOversizedRollbackJournalFailsDuringPreflightWithoutMutation() throws {
        let fixture = try makeGlobalStoreFixture()
        var root = try plistRoot(at: fixture.index)
        root["Displays"] = [
            displayID.uuidString: ["Opaque": Data(repeating: 0xAB, count: 3_500_000)],
        ]
        try plistData(root).write(to: fixture.index)
        let indexBefore = try Data(contentsOf: fixture.index)

        XCTAssertThrowsError(try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).preflight(assignments: [.init(displayUUID: displayID, assetID: assetA)]))

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testUnmanagedTopLevelChangeIsPreservedAcrossGlobalTransitionAndRollback() throws {
        let fixture = try makeGlobalStoreFixture()
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])
        var changed = try plistRoot(at: fixture.index)
        let external = ["External": Data("keep me".utf8)]
        changed["UnmanagedRoot"] = external
        try plistData(changed).write(to: fixture.index)

        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetB),
        ], knownOwnedAssetIDs: [assetA, assetB])
        _ = try editor.reconcile(assignments: [], knownOwnedAssetIDs: [assetA, assetB])

        let final = try plistRoot(at: fixture.index)
        XCTAssertEqual(try encodedPlistValue(final["UnmanagedRoot"] as Any),
                       try encodedPlistValue(external))
    }

    func testMalformedGlobalLinkedNodeFailsBeforeJournalOrIndexMutation() throws {
        let fixture = try makeGlobalStoreFixture()
        var malformed = try plistRoot(at: fixture.index)
        var global = try XCTUnwrap(malformed["AllSpacesAndDisplays"] as? [String: Any])
        global["Type"] = "individual"
        malformed["AllSpacesAndDisplays"] = global
        try plistData(malformed).write(to: fixture.index)
        let indexBefore = try Data(contentsOf: fixture.index)

        XCTAssertThrowsError(try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [.init(displayUUID: displayID, assetID: assetA)]))

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testAtomicCompareAndSwapRejectsStaleBaselineWithoutMutation() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Index.plist")
        let current = Data("external update".utf8)
        try current.write(to: file)

        XCTAssertThrowsError(try LockScreenFileIO.atomicCompareAndSwap(
            expected: Data("stale baseline".utf8),
            replacement: Data("WALI replacement".utf8),
            at: file,
            validate: { _ in }
        ))
        XCTAssertEqual(try Data(contentsOf: file), current)
    }

    func testAssetCreateUsesNoReplaceEvenWhenRacingBytesMatchTarget() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("asset.mov")
        let target = Data("same bytes from another writer".utf8)
        try target.write(to: destination)

        XCTAssertThrowsError(try LockScreenFileIO.atomicInstallData(
            target,
            to: destination,
            expectedDigest: nil,
            targetDigest: Data(SHA256.hash(data: target)),
            maximumBytes: 1_024,
            ownershipMarker: Data("create".utf8),
            recoveryURL: root.appendingPathComponent(".wali-create-recovery"),
            validate: { _ in }
        ))
        XCTAssertEqual(try Data(contentsOf: destination), target)
    }

    func testAssetStageCollisionPreservesUnmarkedRecoverySibling() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("asset.mov")
        let recovery = root.appendingPathComponent(".wali-collision-recovery")
        let external = Data("external recovery occupant".utf8)
        let target = Data("WALI target".utf8)
        try external.write(to: recovery)

        XCTAssertThrowsError(try LockScreenFileIO.atomicInstallData(
            target,
            to: destination,
            expectedDigest: nil,
            targetDigest: Data(SHA256.hash(data: target)),
            maximumBytes: 1_024,
            ownershipMarker: Data("transaction".utf8),
            recoveryURL: recovery,
            validate: { _ in }
        ))
        XCTAssertEqual(try Data(contentsOf: recovery), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAssetStagePersistsOwnershipBeforeWritingBytes() throws {
        enum SimulatedCrash: Error { case beforeFirstByte }

        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("asset.mov")
        let recovery = root.appendingPathComponent(".wali-durable-marker-recovery")
        let target = Data("WALI target".utf8)
        let marker = Data("durable-transaction".utf8)
        var observedDurableMarkerBeforeBytes = false

        XCTAssertThrowsError(try LockScreenFileIO.atomicInstallData(
            target,
            to: destination,
            expectedDigest: nil,
            targetDigest: Data(SHA256.hash(data: target)),
            maximumBytes: 1_024,
            ownershipMarker: marker,
            recoveryURL: recovery,
            ownershipDidBecomeDurable: { staged in
                observedDurableMarkerBeforeBytes = try LockScreenFileIO.hasOwnershipMarker(
                    at: staged,
                    expected: marker
                ) && Data(contentsOf: staged).isEmpty
                throw SimulatedCrash.beforeFirstByte
            },
            validate: { _ in }
        ))

        XCTAssertTrue(observedDurableMarkerBeforeBytes)
        XCTAssertTrue(try LockScreenFileIO.hasOwnershipMarker(at: recovery, expected: marker))
        XCTAssertEqual(try Data(contentsOf: recovery), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAssetReplaceCASPreservesRacingExternalBytes() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("asset.mov")
        let expected = Data("journaled bytes".utf8)
        let external = Data("external replacement".utf8)
        let target = Data("WALI replacement".utf8)
        try external.write(to: destination)

        XCTAssertThrowsError(try LockScreenFileIO.atomicInstallData(
            target,
            to: destination,
            expectedDigest: Data(SHA256.hash(data: expected)),
            targetDigest: Data(SHA256.hash(data: target)),
            maximumBytes: 1_024,
            ownershipMarker: Data("replace".utf8),
            recoveryURL: root.appendingPathComponent(".wali-replace-recovery"),
            validate: { _ in }
        ))
        XCTAssertEqual(try Data(contentsOf: destination), external)
    }

    func testAssetRemoveCASRestoresRacingExternalBytes() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("asset.mov")
        let expected = Data("journaled bytes".utf8)
        let external = Data("external replacement".utf8)
        let recovery = root.appendingPathComponent(".wali-remove-recovery")
        try external.write(to: destination)

        XCTAssertThrowsError(try LockScreenFileIO.atomicRemove(
            destination,
            expectedDigest: Data(SHA256.hash(data: expected)),
            maximumBytes: 1_024,
            recoveryURL: recovery
        ))
        XCTAssertEqual(try Data(contentsOf: destination), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testMalformedIndexPreflightLeavesAllStoresUntouched() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Displays": "malformed",
                "Spaces": [String: Any](),
            ],
            format: .binary,
            options: 0
        ).write(to: fixture.paths.indexURL)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        )

        do {
            _ = try await coordinator.reconcile(
                enabled: true,
                assignments: [.init(
                    displayID: "uuid:\(displayID.uuidString)",
                    isMain: true,
                    itemID: assetA,
                    name: "Synthetic",
                    masterBitDepth: 10,
                    masterArtifactSHA256: fixture.masterSHA256,
                    posterArtifactSHA256: fixture.posterSHA256,
                    masterURL: fixture.master,
                    posterURL: fixture.poster
                )]
            )
            XCTFail("A malformed Index.plist must fail closed")
        } catch is LockScreenCompatibilityError {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.videosDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testMacOS25G83PassesVerifiedLockScreenPreflight() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25G83"
        )

        try await coordinator.validate(
            enabled: true,
            assignments: [.init(
                displayID: "uuid:\(displayID.uuidString)",
                isMain: true,
                itemID: assetA,
                name: "Synthetic",
                masterBitDepth: 10,
                masterArtifactSHA256: fixture.masterSHA256,
                posterArtifactSHA256: fixture.posterSHA256,
                masterURL: fixture.master,
                posterURL: fixture.poster
            )]
        )
    }

    func testCorruptPosterFailsBeforeAnyJournalOrAssetCopy() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        try Data("not an image".utf8).write(to: fixture.poster)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        )

        do {
            _ = try await coordinator.reconcile(
                enabled: true,
                assignments: [.init(
                    displayID: "uuid:\(displayID.uuidString)",
                    isMain: true,
                    itemID: assetA,
                    name: "Synthetic",
                    masterBitDepth: 10,
                    masterArtifactSHA256: fixture.masterSHA256,
                    posterArtifactSHA256: fixture.posterSHA256,
                    masterURL: fixture.master,
                    posterURL: fixture.poster
                )]
            )
            XCTFail("A corrupt poster must fail during read-only preflight")
        } catch is LockScreenCompatibilityError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.videosDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testLegacyEightBitMasterFailsLockPreflightWithoutMutation() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        )

        var caughtError: Error?
        do {
            try await coordinator.validate(
                enabled: true,
                assignments: [.init(
                    displayID: "uuid:\(displayID.uuidString)",
                    isMain: true,
                    itemID: assetA,
                    name: "Legacy",
                    masterBitDepth: 8,
                    masterArtifactSHA256: fixture.masterSHA256,
                    posterArtifactSHA256: fixture.posterSHA256,
                    masterURL: fixture.master,
                    posterURL: fixture.poster
                )]
            )
        } catch {
            caughtError = error
        }

        XCTAssertTrue(caughtError?.localizedDescription.contains("Re-import") == true)
        XCTAssertTrue(caughtError?.localizedDescription.contains("10-bit") == true)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.videosDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testTamperedPersistedSourcesFailBeforeLockTransactionMutation() async throws {
        for tamperedRole in ["master", "poster"] {
            let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
            let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
            let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
            if tamperedRole == "master" {
                try Data("tampered master".utf8).write(to: fixture.master)
            } else {
                try Data("tampered poster".utf8).write(to: fixture.poster)
            }
            let coordinator = LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80"
            )

            do {
                try await coordinator.validate(
                    enabled: true,
                    assignments: [.init(
                        displayID: "uuid:\(displayID.uuidString)",
                        isMain: true,
                        itemID: assetA,
                        name: "Tampered",
                        masterBitDepth: 10,
                        masterArtifactSHA256: fixture.masterSHA256,
                        posterArtifactSHA256: fixture.posterSHA256,
                        masterURL: fixture.master,
                        posterURL: fixture.poster
                    )]
                )
                XCTFail("A tampered persisted \(tamperedRole) must fail closed")
            } catch let error as LockScreenCompatibilityError {
                XCTAssertTrue(error.localizedDescription.contains("Re-import"))
            }

            XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        }
    }

    func testLegacyAssetJournalSchemaFailsClosedWithoutMutation() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let legacyJournal = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "phase": "committed",
            "records": [["id": assetA.uuidString, "mayRemove": true]],
        ], options: [.sortedKeys])
        try legacyJournal.write(to: fixture.paths.assetJournalURL)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)

        do {
            _ = try await LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80"
            ).reconcile(enabled: false, assignments: [])
            XCTFail("A schema-1 ownership journal must be rejected")
        } catch let error as LockScreenCompatibilityError {
            guard case .unsupportedSchema = error else {
                return XCTFail("Expected unsupported schema, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.assetJournalURL), legacyJournal)
    }

    func testPermissionPreflightChecksEveryAppleWriteDirectoryWithoutResidue() async throws {
        let destination: [(LockScreenStorePaths) -> URL] = [
            { $0.videosDirectory },
            { $0.thumbnailsDirectory },
            { $0.manifestURL.deletingLastPathComponent() },
            { $0.indexURL.deletingLastPathComponent() },
        ]

        for deniedIndex in destination.indices {
            let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
            let appleDirectories = [
                fixture.paths.videosDirectory,
                fixture.paths.thumbnailsDirectory,
                fixture.paths.manifestURL.deletingLastPathComponent(),
                fixture.paths.indexURL.deletingLastPathComponent(),
            ]
            let contentsBefore = try appleDirectories.map {
                try Set(FileManager.default.contentsOfDirectory(atPath: $0.path))
            }
            let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
            let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
            let coordinator = LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80",
                permissionPreflight: { directories in
                    XCTAssertEqual(directories, appleDirectories)
                    for (index, directory) in directories.enumerated() {
                        if index == deniedIndex { throw POSIXError(.EACCES) }
                        try LockScreenFileIO.requireTransactionalWriteAccess(to: directory)
                    }
                }
            )

            var caughtError: Error?
            do {
                try await coordinator.validate(
                    enabled: true,
                    assignments: [.init(
                        displayID: "uuid:\(displayID.uuidString)",
                        isMain: true,
                        itemID: assetA,
                        name: "Synthetic",
                        masterBitDepth: 10,
                        masterArtifactSHA256: fixture.masterSHA256,
                        posterArtifactSHA256: fixture.posterSHA256,
                        masterURL: fixture.master,
                        posterURL: fixture.poster
                    )]
                )
            } catch {
                caughtError = error
            }
            guard let caughtError else {
                XCTFail("A denied Apple-store destination must reject opt-in preflight")
                continue
            }
            XCTAssertTrue(caughtError.localizedDescription.contains("Full Disk Access"))
            XCTAssertTrue(caughtError.localizedDescription.contains("WALI Lock Screen Helper"))
            XCTAssertTrue(caughtError.localizedDescription.contains(
                "System Settings > Privacy & Security > Full Disk Access"
            ))
            XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
            for (directory, expectedContents) in zip(appleDirectories, contentsBefore) {
                XCTAssertEqual(
                    try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
                    expectedContents
                )
            }
        }
    }

    func testPermissionErrorsMapToFullDiskAccessGuidance() {
        let direct = LockScreenFileIO.actionableTransactionalWriteError(POSIXError(.EACCES))
        XCTAssertTrue(direct.localizedDescription.contains("Full Disk Access"))
        XCTAssertTrue(direct.localizedDescription.contains("WALI Lock Screen Helper"))

        let nested = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)]
        )
        let mappedNested = LockScreenFileIO.actionableTransactionalWriteError(nested)
        XCTAssertTrue(mappedNested.localizedDescription.contains("Full Disk Access"))
        XCTAssertTrue(mappedNested.localizedDescription.contains("WALI Lock Screen Helper"))

        let unrelated = LockScreenCompatibilityError.malformedStore("Synthetic schema failure")
        XCTAssertEqual(
            LockScreenFileIO.actionableTransactionalWriteError(unrelated).localizedDescription,
            unrelated.localizedDescription
        )
    }

    func testPermissionDenialPreservesPreparedRecoveryJournalAndAppleStores() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let preparedJournal = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "transactionID": UUID().uuidString,
            "phase": "prepared",
            "records": [[
                "id": assetA.uuidString,
                "video": [
                    "targetDigest": Data(repeating: 0xAA, count: 32).base64EncodedString(),
                ],
                "thumbnail": [
                    "targetDigest": Data(repeating: 0xBB, count: 32).base64EncodedString(),
                ],
            ]],
            "refreshPending": true,
        ], options: [.sortedKeys])
        try preparedJournal.write(to: fixture.paths.assetJournalURL)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            permissionPreflight: { _ in throw POSIXError(.EPERM) }
        )

        var caughtError: Error?
        do {
            _ = try await coordinator.reconcile(enabled: false, assignments: [])
        } catch {
            caughtError = error
        }
        XCTAssertNotNil(caughtError)
        XCTAssertTrue(caughtError?.localizedDescription.contains("Full Disk Access") == true)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.assetJournalURL), preparedJournal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.videosDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.thumbnailsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testRefreshPendingSurvivesCommitUntilRefreshRequest() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "phase": "committed",
            "records": [],
            "refreshPending": true,
        ]).write(to: fixture.paths.assetJournalURL)
        let refreshes = LockedCounter()
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            refreshHandler: { refreshes.increment() }
        )

        let result = try await coordinator.reconcile(enabled: false, assignments: [])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
    }

    func testSessionLockRestartRefreshesActivePlaybackWithoutRewritingStores() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let refreshes = LockedCounter()
        let quiesces = LockedCounter()
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            refreshHandler: { refreshes.increment() },
            quiesceHandler: { quiesces.increment() }
        )
        let main = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Main",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        _ = try await coordinator.reconcile(enabled: true, assignments: [main])
        let manifestAfterActivation = try Data(contentsOf: fixture.paths.manifestURL)
        let indexAfterActivation = try Data(contentsOf: fixture.paths.indexURL)
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(quiesces.value, 1)

        let result = try await coordinator.reconcile(
            enabled: true,
            assignments: [main],
            restartPlayback: true
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(refreshes.value, 2)
        XCTAssertEqual(quiesces.value, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestAfterActivation)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexAfterActivation)
    }

    func testCoordinatorUsesMainDisplayAndQuiescesOnlyBeforeRequiredMutation() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let quiesces = LockedCounter()
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            quiesceHandler: {
                guard try Data(contentsOf: fixture.paths.manifestURL) == manifestBefore,
                      try Data(contentsOf: fixture.paths.indexURL) == indexBefore,
                      !FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path),
                      try FileManager.default.contentsOfDirectory(
                          atPath: fixture.paths.videosDirectory.path
                      ).isEmpty,
                      try FileManager.default.contentsOfDirectory(
                          atPath: fixture.paths.thumbnailsDirectory.path
                      ).isEmpty else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "The quiesce hook ran after transaction mutation."
                    )
                }
                quiesces.increment()
            }
        )
        let main = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Main",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        let secondary = LockScreenWallpaperAssignment(
            displayID: "uuid:\(secondDisplayID.uuidString)",
            isMain: false,
            itemID: assetB,
            name: "Secondary",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        let result = try await coordinator.reconcile(
            enabled: true,
            assignments: [secondary, main]
        )

        XCTAssertEqual(result.registeredAssets, 1)
        XCTAssertEqual(result.patchedNodes, 4)
        XCTAssertEqual(quiesces.value, 1)
        XCTAssertEqual(try globalSelectedAsset(
            in: fixture.paths.indexURL,
            key: "AllSpacesAndDisplays"
        ), assetA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.videosDirectory
            .appendingPathComponent("\(assetA.uuidString).mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.videosDirectory
            .appendingPathComponent("\(assetB.uuidString).mov").path))
        let journal = try JSONDecoder().decode(
            AssetJournalProbe.self,
            from: Data(contentsOf: fixture.paths.assetJournalURL)
        )
        let record = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(journal.schemaVersion, 2)
        XCTAssertEqual(
            record.video.targetDigest,
            Data(SHA256.hash(data: try Data(contentsOf: fixture.paths.videosDirectory
                .appendingPathComponent("\(assetA.uuidString).mov"))))
        )
        XCTAssertEqual(
            record.thumbnail.targetDigest,
            Data(SHA256.hash(data: try Data(contentsOf: fixture.paths.thumbnailsDirectory
                .appendingPathComponent("\(assetA.uuidString).png"))))
        )

        _ = try await coordinator.reconcile(enabled: true, assignments: [secondary, main])
        XCTAssertEqual(quiesces.value, 1)
    }

    func testDestinationCreatedDuringQuiesceIsPreservedWithoutPublishingOwnership() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let destination = fixture.paths.videosDirectory.appendingPathComponent(
            "\(assetA.uuidString).mov"
        )
        let racingBytes = try Data(contentsOf: fixture.master)
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            quiesceHandler: { try racingBytes.write(to: destination) }
        )

        do {
            _ = try await coordinator.reconcile(
                enabled: true,
                assignments: [.init(
                    displayID: "uuid:\(displayID.uuidString)",
                    isMain: true,
                    itemID: assetA,
                    name: "Synthetic",
                    masterBitDepth: 10,
                    masterArtifactSHA256: fixture.masterSHA256,
                    posterArtifactSHA256: fixture.posterSHA256,
                    masterURL: fixture.master,
                    posterURL: fixture.poster
                )]
            )
            XCTFail("A destination race must fail closed")
        } catch let error as LockScreenCompatibilityError {
            guard case .ownershipConflict = error else {
                return XCTFail("Expected ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: destination), racingBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
    }

    func testManifestIdentityWithoutDigestJournalCannotAuthorizeAssetDeletion() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let assignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [assignment])
        try FileManager.default.removeItem(at: fixture.paths.assetJournalURL)
        let video = fixture.paths.videosDirectory.appendingPathComponent("\(assetA.uuidString).mov")
        let thumbnail = fixture.paths.thumbnailsDirectory.appendingPathComponent(
            "\(assetA.uuidString).png"
        )
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)
        let videoBefore = try Data(contentsOf: video)
        let thumbnailBefore = try Data(contentsOf: thumbnail)

        do {
            _ = try await LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80"
            ).reconcile(enabled: false, assignments: [])
            XCTFail("Manifest identity alone must not authorize file removal")
        } catch let error as LockScreenCompatibilityError {
            guard case .ownershipConflict = error else {
                return XCTFail("Expected ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertEqual(try Data(contentsOf: video), videoBefore)
        XCTAssertEqual(try Data(contentsOf: thumbnail), thumbnailBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
    }

    func testPreparedReplacementRecoveryDeletesOnlyJournaledSibling() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let originalAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [originalAssignment])

        let video = fixture.paths.videosDirectory.appendingPathComponent("\(assetA.uuidString).mov")
        let thumbnail = fixture.paths.thumbnailsDirectory.appendingPathComponent(
            "\(assetA.uuidString).png"
        )
        let originalVideo = try Data(contentsOf: video)
        let replacementVideo = Data("replacement verified video".utf8)
        let thumbnailDigest = Data(SHA256.hash(data: try Data(contentsOf: thumbnail)))
        let transactionID = UUID()
        let recovery = assetRecoveryURL(
            directory: fixture.paths.videosDirectory,
            transactionID: transactionID,
            itemID: assetA,
            role: "video"
        )
        try originalVideo.write(to: recovery)
        try replacementVideo.write(to: video)
        try setAssetOwnershipMarker(
            Data(transactionID.uuidString.lowercased().utf8),
            at: video
        )
        try replacementVideo.write(to: fixture.master)
        try writeAssetJournal(
            transactionID: transactionID,
            phase: "prepared",
            records: [[
                "id": assetA.uuidString,
                "video": [
                    "expectedDigest": Data(SHA256.hash(data: originalVideo)).base64EncodedString(),
                    "targetDigest": Data(SHA256.hash(data: replacementVideo)).base64EncodedString(),
                ],
                "thumbnail": [
                    "expectedDigest": thumbnailDigest.base64EncodedString(),
                    "targetDigest": thumbnailDigest.base64EncodedString(),
                ],
            ]],
            to: fixture.paths.assetJournalURL
        )
        let replacementAssignment = LockScreenWallpaperAssignment(
            displayID: originalAssignment.displayID,
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: sha256Hex(replacementVideo),
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [replacementAssignment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try Data(contentsOf: video), replacementVideo)
        let journal = try JSONDecoder().decode(
            AssetJournalProbe.self,
            from: Data(contentsOf: fixture.paths.assetJournalURL)
        )
        XCTAssertEqual(journal.phase, "committed")
        XCTAssertEqual(
            journal.records.first?.video.targetDigest,
            Data(SHA256.hash(data: replacementVideo))
        )
    }

    func testPreparedCreateDoesNotAdoptUnmarkedExactTarget() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let assignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [assignment])

        let video = fixture.paths.videosDirectory.appendingPathComponent("\(assetA.uuidString).mov")
        let thumbnail = fixture.paths.thumbnailsDirectory.appendingPathComponent(
            "\(assetA.uuidString).png"
        )
        let targetVideo = try Data(contentsOf: video)
        let videoDigest = Data(SHA256.hash(data: targetVideo))
        let thumbnailDigest = Data(SHA256.hash(data: try Data(contentsOf: thumbnail)))
        try FileManager.default.removeItem(at: video)
        try targetVideo.write(to: video)
        let transactionID = UUID()
        try writeAssetJournal(
            transactionID: transactionID,
            phase: "prepared",
            records: [[
                "id": assetA.uuidString,
                "video": [
                    "targetDigest": videoDigest.base64EncodedString(),
                ],
                "thumbnail": [
                    "expectedDigest": thumbnailDigest.base64EncodedString(),
                    "targetDigest": thumbnailDigest.base64EncodedString(),
                ],
            ]],
            to: fixture.paths.assetJournalURL
        )
        let journalBefore = try Data(contentsOf: fixture.paths.assetJournalURL)
        let manifestBefore = try Data(contentsOf: fixture.paths.manifestURL)
        let indexBefore = try Data(contentsOf: fixture.paths.indexURL)

        do {
            _ = try await LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80"
            ).reconcile(enabled: true, assignments: [assignment])
            XCTFail("An unmarked exact-target collision must not be adopted")
        } catch let error as LockScreenCompatibilityError {
            guard case .ownershipConflict = error else {
                return XCTFail("Expected ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: video), targetVideo)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.assetJournalURL), journalBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.indexURL), indexBefore)
        XCTAssertFalse(try LockScreenFileIO.hasOwnershipMarker(
            at: video,
            expected: Data(transactionID.uuidString.lowercased().utf8)
        ))
    }

    func testPreparedPartialStageRecoveryRequiresMarkerThenRestages() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let originalAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [originalAssignment])

        let video = fixture.paths.videosDirectory.appendingPathComponent("\(assetA.uuidString).mov")
        let thumbnail = fixture.paths.thumbnailsDirectory.appendingPathComponent(
            "\(assetA.uuidString).png"
        )
        let originalVideo = try Data(contentsOf: video)
        let replacementVideo = Data("replacement after partial stage".utf8)
        let thumbnailDigest = Data(SHA256.hash(data: try Data(contentsOf: thumbnail)))
        let transactionID = UUID()
        let recovery = assetRecoveryURL(
            directory: fixture.paths.videosDirectory,
            transactionID: transactionID,
            itemID: assetA,
            role: "video"
        )
        try Data("partial".utf8).write(to: recovery)
        try replacementVideo.write(to: fixture.master)
        try writeAssetJournal(
            transactionID: transactionID,
            phase: "prepared",
            records: [[
                "id": assetA.uuidString,
                "video": [
                    "expectedDigest": Data(SHA256.hash(data: originalVideo)).base64EncodedString(),
                    "targetDigest": Data(SHA256.hash(data: replacementVideo)).base64EncodedString(),
                ],
                "thumbnail": [
                    "expectedDigest": thumbnailDigest.base64EncodedString(),
                    "targetDigest": thumbnailDigest.base64EncodedString(),
                ],
            ]],
            to: fixture.paths.assetJournalURL
        )
        let replacementAssignment = LockScreenWallpaperAssignment(
            displayID: originalAssignment.displayID,
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: sha256Hex(replacementVideo),
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        do {
            _ = try await LockScreenContinuityCoordinator(
                paths: fixture.paths,
                ownedLibraryRoot: fixture.ownedRoot,
                systemBuild: "25F80"
            ).reconcile(enabled: true, assignments: [replacementAssignment])
            XCTFail("An unmarked partial sibling must be preserved and rejected")
        } catch let error as LockScreenCompatibilityError {
            guard case .ownershipConflict = error else {
                return XCTFail("Expected ownership conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: recovery), Data("partial".utf8))
        XCTAssertEqual(try Data(contentsOf: video), originalVideo)
        try setAssetOwnershipMarker(
            Data(transactionID.uuidString.lowercased().utf8),
            at: recovery
        )

        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [replacementAssignment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try Data(contentsOf: video), replacementVideo)
        let journal = try JSONDecoder().decode(
            AssetJournalProbe.self,
            from: Data(contentsOf: fixture.paths.assetJournalURL)
        )
        XCTAssertEqual(journal.phase, "committed")
    }

    func testPreparedRemovalRecoveryDeletesJournaledSiblingsAndRestoresStore() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: false)
        let assignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        let originalIndex = try Data(contentsOf: fixture.paths.indexURL)
        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: true, assignments: [assignment])

        let video = fixture.paths.videosDirectory.appendingPathComponent("\(assetA.uuidString).mov")
        let thumbnail = fixture.paths.thumbnailsDirectory.appendingPathComponent(
            "\(assetA.uuidString).png"
        )
        let videoData = try Data(contentsOf: video)
        let thumbnailData = try Data(contentsOf: thumbnail)
        let transactionID = UUID()
        let videoRecovery = assetRecoveryURL(
            directory: fixture.paths.videosDirectory,
            transactionID: transactionID,
            itemID: assetA,
            role: "video"
        )
        let thumbnailRecovery = assetRecoveryURL(
            directory: fixture.paths.thumbnailsDirectory,
            transactionID: transactionID,
            itemID: assetA,
            role: "thumbnail"
        )
        try FileManager.default.moveItem(at: video, to: videoRecovery)
        try FileManager.default.moveItem(at: thumbnail, to: thumbnailRecovery)
        try writeAssetJournal(
            transactionID: transactionID,
            phase: "prepared",
            records: [[
                "id": assetA.uuidString,
                "video": [
                    "expectedDigest": Data(SHA256.hash(data: videoData)).base64EncodedString(),
                ],
                "thumbnail": [
                    "expectedDigest": Data(SHA256.hash(data: thumbnailData)).base64EncodedString(),
                ],
            ]],
            to: fixture.paths.assetJournalURL
        )

        _ = try await LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80"
        ).reconcile(enabled: false, assignments: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: videoRecovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailRecovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertTrue(NSDictionary(
            dictionary: try plistRoot(at: fixture.paths.indexURL)
        ).isEqual(to: try plistRoot(from: originalIndex)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.assetJournalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalURL.path))
    }

    func testSuspendedQuiesceKeepsCrossFileReconciliationsSingleFlight() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let quiesces = SuspendedRefreshGate()
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            quiesceHandler: { await quiesces.suspend() }
        )
        let firstAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic A",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        let secondAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetB,
            name: "Synthetic B",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        let first = Task {
            try await coordinator.reconcile(enabled: true, assignments: [firstAssignment])
        }
        await quiesces.waitUntilSuspended(count: 1)
        let second = Task {
            try await coordinator.reconcile(enabled: true, assignments: [secondAssignment])
        }

        await quiesces.releaseFirst()
        _ = try await first.value
        await quiesces.waitUntilSuspended(count: 1)
        await quiesces.releaseFirst()
        _ = try await second.value

        XCTAssertEqual(try globalSelectedAsset(
            in: fixture.paths.indexURL,
            key: "AllSpacesAndDisplays"
        ), assetB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.videosDirectory
            .appendingPathComponent("\(assetB.uuidString).mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.videosDirectory
            .appendingPathComponent("\(assetA.uuidString).mov").path))
    }

    func testOlderRefreshCannotFinalizeNewerAssetJournalGeneration() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let refreshes = SuspendedRefreshGate()
        let coordinator = LockScreenContinuityCoordinator(
            paths: fixture.paths,
            ownedLibraryRoot: fixture.ownedRoot,
            systemBuild: "25F80",
            refreshHandler: { await refreshes.suspend() }
        )
        let firstAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetA,
            name: "Synthetic A",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        let secondAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            isMain: true,
            itemID: assetB,
            name: "Synthetic B",
            masterBitDepth: 10,
            masterArtifactSHA256: fixture.masterSHA256,
            posterArtifactSHA256: fixture.posterSHA256,
            masterURL: fixture.master,
            posterURL: fixture.poster
        )

        let first = Task {
            try await coordinator.reconcile(enabled: true, assignments: [firstAssignment])
        }
        await refreshes.waitUntilSuspended(count: 1)
        let second = Task {
            try await coordinator.reconcile(enabled: true, assignments: [secondAssignment])
        }
        await refreshes.waitUntilSuspended(count: 2)

        await refreshes.releaseFirst()
        _ = try await first.value
        let whileSecondIsSuspended = try JSONDecoder().decode(
            AssetJournalProbe.self,
            from: Data(contentsOf: fixture.paths.assetJournalURL)
        )
        XCTAssertEqual(whileSecondIsSuspended.records.map(\.id), [assetB])
        XCTAssertTrue(whileSecondIsSuspended.refreshPending)

        await refreshes.releaseFirst()
        _ = try await second.value
        let final = try JSONDecoder().decode(
            AssetJournalProbe.self,
            from: Data(contentsOf: fixture.paths.assetJournalURL)
        )
        XCTAssertEqual(final.records.map(\.id), [assetB])
        XCTAssertFalse(final.refreshPending)
        XCTAssertEqual(try globalSelectedAsset(
            in: fixture.paths.indexURL,
            key: "AllSpacesAndDisplays"
        ), assetB)
    }

    func testPreferencePreflightFailureLeavesEngineStateUnchanged() async {
        let router = AgentCommandRouter { step, _ in
            if case .preflight(.setPreferences) = step {
                throw LockScreenCompatibilityError.permissionDenied
            }
            return .unchanged
        }
        let response = await router.handle(AgentRequest(command: .setPreferences(.init(
            lockScreenContinuityEnabled: true
        ))))

        guard case let .failure(failure) = response.result else {
            return XCTFail("A rejected opt-in preflight must fail before persistence")
        }
        XCTAssertTrue(failure.localizedDescription.contains("Full Disk Access"))
        XCTAssertTrue(failure.localizedDescription.contains("WALI Lock Screen Helper"))
        let snapshot = await router.snapshot()
        XCTAssertFalse(snapshot.preferences.lockScreenContinuityEnabled)
        XCTAssertEqual(snapshot.revision.rawValue, 0)
    }

    func testRuntimeNoticeKeepsCommittedDesktopCommandSuccessful() async {
        let notice = AgentRuntimeNotice(
            kind: .warning,
            title: "Desktop Wallpaper Applied",
            message: "Synthetic Lock Screen failure"
        )
        let router = AgentCommandRouter { step, _ in
            if case .effect(.reconcileRendering) = step {
                return .replaceRuntimeNotice(notice)
            }
            return .unchanged
        }
        let response = await router.handle(AgentRequest(command: .setPreferences(.init(
            lockScreenContinuityEnabled: true
        ))))

        guard case let .snapshot(snapshot) = response.result else {
            return XCTFail("A private-adapter warning must not fail committed desktop state")
        }
        XCTAssertTrue(snapshot.preferences.lockScreenContinuityEnabled)
        XCTAssertEqual(snapshot.notice, notice)
        XCTAssertEqual(snapshot.revision.rawValue, 1)
    }

    private func makeGlobalStoreFixture(data: Data? = nil) throws -> StoreFixture {
        let root = try temporaryDirectory()
        let index = root.appendingPathComponent("Index.plist")
        let journal = root.appendingPathComponent("choice-journal.json")
        try (data ?? globalStoreData()).write(to: index)
        return .init(index: index, journal: journal)
    }

    private func globalStoreData(includeOverrides: Bool = true) throws -> Data {
        let displays: [String: Any] = includeOverrides ? [
            displayID.uuidString: [
                "Linked": ["Content": ["Choices": try choices(originalAsset)]],
            ],
        ] : [:]
        let spaces: [String: Any] = includeOverrides ? [
            spaceID.uuidString: ["OpaqueSpace": Data([0x05])],
        ] : [:]
        return try plistData([
            "AllSpacesAndDisplays": globalLinkedNode(
                choices: [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Configuration": Data("global-image-choice".utf8),
                    "Files": [Any](),
                ]],
                optionValues: Data([0x01, 0x02]),
                date: Date(timeIntervalSince1970: 1_000)
            ),
            "SystemDefault": globalLinkedNode(
                choices: [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Configuration": Data("system-image-choice".utf8),
                    "Files": [Any](),
                ]],
                optionValues: Data([0x03, 0x04]),
                date: Date(timeIntervalSince1970: 2_000)
            ),
            "Displays": displays,
            "Spaces": spaces,
            "UnmanagedRoot": ["Opaque": Data([0x06, 0x07])],
        ])
    }

    private func globalTargetStoreData(from original: Data, assetID: UUID) throws -> Data {
        var root = try plistRoot(from: original)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            var node = try XCTUnwrap(root[key] as? [String: Any])
            var linked = try XCTUnwrap(node["Linked"] as? [String: Any])
            var content = try XCTUnwrap(linked["Content"] as? [String: Any])
            content["Choices"] = try choices(assetID)
            linked["Content"] = content
            node["Linked"] = linked
            root[key] = node
        }
        root["Displays"] = [String: Any]()
        root["Spaces"] = [String: Any]()
        return try plistData(root)
    }

    private func globalLinkedNode(
        choices: [Any],
        optionValues: Data,
        date: Date
    ) -> [String: Any] {
        [
            "Type": "linked",
            "Linked": [
                "Content": [
                    "Choices": choices,
                    "EncodedOptionValues": optionValues,
                    "Shuffle": "$null",
                ],
                "LastSet": date,
                "LastUse": date,
            ],
        ]
    }

    private func globalPreservedValues(
        in root: [String: Any],
        key: String
    ) throws -> [String: Any] {
        var node = try XCTUnwrap(root[key] as? [String: Any])
        var linked = try XCTUnwrap(node["Linked"] as? [String: Any])
        var content = try XCTUnwrap(linked["Content"] as? [String: Any])
        content.removeValue(forKey: "Choices")
        linked["Content"] = content
        linked.removeValue(forKey: "LastSet")
        linked.removeValue(forKey: "LastUse")
        node["Linked"] = linked
        return node
    }

    private func globalDates(in root: [String: Any], key: String) throws -> [Date] {
        let node = try XCTUnwrap(root[key] as? [String: Any])
        let linked = try XCTUnwrap(node["Linked"] as? [String: Any])
        return [
            try XCTUnwrap(linked["LastSet"] as? Date),
            try XCTUnwrap(linked["LastUse"] as? Date),
        ]
    }

    private func globalSelectedAsset(in index: URL, key: String) throws -> UUID? {
        let root = try plistRoot(at: index)
        let node = root[key] as? [String: Any]
        let linked = node?["Linked"] as? [String: Any]
        let content = linked?["Content"] as? [String: Any]
        let choices = content?["Choices"] as? [[String: Any]]
        guard let configuration = choices?.first?["Configuration"] as? Data,
              let decoded = try PropertyListSerialization.propertyList(
                from: configuration,
                options: [],
                format: nil
              ) as? [String: Any],
              let rawID = decoded["assetID"] as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    private func plistData(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func writeGlobalChoiceJournal(
        phase: String,
        originalData: Data,
        managedAssetIDs: [UUID],
        sourceAssetID: UUID?,
        targetAssetID: UUID?,
        expectedData: Data? = nil,
        targetData: Data? = nil,
        to url: URL
    ) throws {
        func values(from data: Data) throws -> [[String: Any]] {
            let root = try plistRoot(from: data)
            return try [
                "AllSpacesAndDisplays", "SystemDefault", "Displays", "Spaces",
            ].map { key -> [String: Any] in
                [
                    "key": key,
                    "value": try encodedPlistValue(root[key] as Any).base64EncodedString(),
                ]
            }
        }
        let originalValues = try values(from: originalData)
        let sourceValues = try values(from: expectedData ?? originalData)
        let targetValues = try values(from: targetData ?? originalData)
        var journal: [String: Any] = [
            "schemaVersion": 3,
            "phase": phase,
            "originalValues": originalValues,
            "sourceValues": sourceValues,
            "targetValues": targetValues,
            "managedAssetIDs": managedAssetIDs.map(\.uuidString),
        ]
        if let sourceAssetID { journal["sourceAssetID"] = sourceAssetID.uuidString }
        if let targetAssetID { journal["targetAssetID"] = targetAssetID.uuidString }
        if let expectedData { journal["expectedIndexDigest"] = digest(expectedData) }
        if let targetData { journal["targetIndexDigest"] = digest(targetData) }
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: url)
    }

    private func makeCoordinatorFixture(indexHasDisplay: Bool) throws -> CoordinatorFixture {
        let root = try temporaryDirectory()
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let metadata = owned.appendingPathComponent("Metadata", isDirectory: true)
        let apple = root.appendingPathComponent("apple", isDirectory: true)
        let manifestDirectory = apple.appendingPathComponent("manifest", isDirectory: true)
        let videos = apple.appendingPathComponent("videos", isDirectory: true)
        let thumbnails = apple.appendingPathComponent("thumbnails", isDirectory: true)
        let store = apple.appendingPathComponent("Store", isDirectory: true)
        for directory in [owned, metadata, manifestDirectory, videos, thumbnails, store] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let manifest = manifestDirectory.appendingPathComponent("entries.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "categories": [],
            "assets": [],
        ], options: [.sortedKeys]).write(to: manifest)
        let index = store.appendingPathComponent("Index.plist")
        let indexData = try globalStoreData(includeOverrides: indexHasDisplay)
        try indexData.write(to: index)
        let master = owned.appendingPathComponent("master.mov")
        let poster = owned.appendingPathComponent("poster.bin")
        let masterData = Data("synthetic video".utf8)
        let posterData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try masterData.write(to: master)
        try posterData.write(to: poster)
        return .init(
            ownedRoot: owned,
            master: master,
            poster: poster,
            masterSHA256: sha256Hex(masterData),
            posterSHA256: sha256Hex(posterData),
            paths: .init(
                manifestURL: manifest,
                videosDirectory: videos,
                thumbnailsDirectory: thumbnails,
                indexURL: index,
                journalURL: metadata.appendingPathComponent("choice-journal.json"),
                assetJournalURL: metadata.appendingPathComponent("asset-journal.json")
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wali-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func choices(_ assetID: UUID) throws -> [Any] {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID.uuidString],
            format: .binary,
            options: 0
        )
        return [[
            "Configuration": configuration,
            "Files": [Any](),
            "Provider": WallpaperStoreEditor.provider,
        ]]
    }

    private func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assetRecoveryURL(
        directory: URL,
        transactionID: UUID,
        itemID: UUID,
        role: String
    ) -> URL {
        directory.appendingPathComponent(
            ".wali-\(transactionID.uuidString.lowercased())-"
                + "\(itemID.uuidString.lowercased()).\(role)-recovery"
        )
    }

    private func writeAssetJournal(
        transactionID: UUID,
        phase: String,
        records: [[String: Any]],
        to url: URL
    ) throws {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "transactionID": transactionID.uuidString,
            "phase": phase,
            "records": records,
            "refreshPending": true,
        ], options: [.sortedKeys]).write(to: url)
    }

    private func setAssetOwnershipMarker(_ marker: Data, at url: URL) throws {
        let result = url.path.withCString { path in
            "com.wali.lock-screen-transaction".withCString { name in
                marker.withUnsafeBytes { buffer in
                    Darwin.setxattr(
                        path,
                        name,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func plistRoot(at url: URL) throws -> [String: Any] {
        try plistRoot(from: Data(contentsOf: url))
    }

    private func plistRoot(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any])
    }

    private func encodedPlistValue(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

}

final class LockScreenHelperConnectionTests: XCTestCase {
    func testDisconnectedHelperIsScopedUnavailableError() async throws {
        let connection = LockScreenHelperConnection(transport: FailingHelperTransport(), preparedThumbnailRoot: try temporaryDirectory())
        do { _ = try await connection.status(); XCTFail("A disconnected helper must fail closed") }
        catch { XCTAssertEqual(error as? LockScreenHelperConnectionError, .unavailable) }
    }
    func testPermissionStatusNamesHelperAndNotAgent() async throws {
        let connection = LockScreenHelperConnection(transport: StatusHelperTransport(permission: .permissionRequired), preparedThumbnailRoot: try temporaryDirectory())
        do { _ = try await connection.status(); XCTFail("Permission denial must fail closed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("WALI Lock Screen Helper")); XCTAssertTrue(error.localizedDescription.contains("WALI Agent does not need")) }
    }
    func testMismatchedResponseRequestIDIsRejected() async throws {
        let connection = LockScreenHelperConnection(transport: MismatchedResponseHelperTransport(), preparedThumbnailRoot: try temporaryDirectory())
        do { _ = try await connection.status(); XCTFail("A response for another request must be rejected") }
        catch { XCTAssertEqual(error as? LockScreenHelperConnectionError, .invalidResponse) }
    }
    func testActivatePreparesThumbnailDirectoryBeforeInitialStatusProbe() async throws {
        let root = try temporaryDirectory()
        let prepared = root.appendingPathComponent("prepared", isDirectory: true)
        let poster = root.appendingPathComponent("poster.png")
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!.write(to: poster)
        let connection = LockScreenHelperConnection(
            transport: PreparedDirectoryHelperTransport(requiredDirectory: prepared),
            preparedThumbnailRoot: prepared
        )

        try await connection.activate(
            .init(
                releaseID: UUID(),
                assetID: UUID(),
                title: "Synthetic",
                masterSHA256: String(repeating: "a", count: 64),
                posterURL: poster
            ),
            restartPlayback: false
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wali-agent-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
}
private struct FailingHelperTransport: LockScreenHelperTransport { func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data { throw LockScreenHelperConnectionError.unavailable } }
private struct StatusHelperTransport: LockScreenHelperTransport {
    let permission: LockScreenHelperPermission
    func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data {
        let value = try JSONDecoder().decode(LockScreenHelperStatusRequest.self, from: request)
        return try JSONEncoder().encode(LockScreenHelperResponse(requestID: value.header.requestID, revision: 0, changed: false, status: .init(revision: 0, permission: permission, activeReleaseID: nil)))
    }
}
private struct MismatchedResponseHelperTransport: LockScreenHelperTransport {
    func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data { try JSONEncoder().encode(LockScreenHelperResponse(requestID: UUID(), revision: 0, changed: false, status: .init(revision: 0, permission: .available, activeReleaseID: nil))) }
}
private struct PreparedDirectoryHelperTransport: LockScreenHelperTransport {
    let requiredDirectory: URL

    func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: requiredDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LockScreenHelperConnectionError.unavailable
        }
        let requestID: UUID
        let revision: UInt64
        switch operation {
        case .status:
            requestID = try JSONDecoder().decode(
                LockScreenHelperStatusRequest.self,
                from: request
            ).header.requestID
            revision = 0
        case .activateVerifiedRelease:
            requestID = try JSONDecoder().decode(
                LockScreenHelperActivationRequest.self,
                from: request
            ).header.requestID
            revision = 1
        case .deactivate, .restore:
            requestID = try JSONDecoder().decode(
                LockScreenHelperMutationRequest.self,
                from: request
            ).header.requestID
            revision = 1
        }
        return try JSONEncoder().encode(LockScreenHelperResponse(
            requestID: requestID,
            revision: revision,
            changed: operation != .status,
            status: .init(
                revision: revision,
                permission: .available,
                activeReleaseID: nil
            )
        ))
    }
}

private struct StoreFixture {
    let index: URL
    let journal: URL
}

private struct CoordinatorFixture {
    let ownedRoot: URL
    let master: URL
    let poster: URL
    let masterSHA256: String
    let posterSHA256: String
    let paths: LockScreenStorePaths
}

private struct GlobalChoiceJournalProbe: Decodable {
    struct OriginalValue: Decodable {
        let key: String
        let value: Data
    }

    let phase: String
    let originalValues: [OriginalValue]
    let managedAssetIDs: [UUID]
    let targetAssetID: UUID?
}

private struct AssetJournalProbe: Decodable {
    struct Transition: Decodable {
        let expectedDigest: Data?
        let targetDigest: Data?
    }

    struct Record: Decodable {
        let id: UUID
        let video: Transition
        let thumbnail: Transition
    }

    let schemaVersion: Int
    let transactionID: UUID?
    let phase: String
    let records: [Record]
    let refreshPending: Bool
}

private actor SuspendedRefreshGate {
    private var refreshContinuations: [CheckedContinuation<Void, Never>] = []
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            refreshContinuations.append(continuation)
            resumeSatisfiedObservers()
        }
    }

    func waitUntilSuspended(count: Int) async {
        guard refreshContinuations.count < count else { return }
        await withCheckedContinuation { continuation in
            observers.append((count, continuation))
        }
    }

    func releaseFirst() {
        refreshContinuations.removeFirst().resume()
    }

    private func resumeSatisfiedObservers() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in observers {
            if refreshContinuations.count >= observer.count {
                observer.continuation.resume()
            } else {
                remaining.append(observer)
            }
        }
        observers = remaining
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
