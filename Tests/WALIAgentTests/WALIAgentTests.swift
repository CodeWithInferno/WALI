import CryptoKit
import WALIEngine
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class WALIAgentTests: XCTestCase {
    private let displayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let secondDisplayID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let thirdDisplayID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let spaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let originalAsset = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    private let assetA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let assetB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    func testRuntimeModuleIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: WALIAgentRootView.self), "WALIAgentRootView")
    }

    func testPreparedAssetReplacementRecoversAndPreservesOriginal() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetA)
        let originalChoices = try choices(originalAsset)
        let before = try storeData(selectedAsset: assetA)
        let target = try storeData(selectedAsset: assetB)
        try writeChoiceJournal(
            phase: "prepared",
            path: displayChoicePath,
            originalChoices: originalChoices,
            managedAssetIDs: [assetA, assetB],
            targetAssetID: assetB,
            expectedData: before,
            targetData: target,
            to: fixture.journal
        )

        _ = try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [.init(displayUUID: displayID, assetID: assetB)])

        XCTAssertEqual(try selectedAsset(in: fixture.index), assetB)
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertEqual(journal.phase, "committed")
        XCTAssertEqual(journal.records.count, 1)
        XCTAssertEqual(journal.records[0].managedAssetIDs, [assetB])
        XCTAssertEqual(journal.records[0].targetAssetID, assetB)
        let recordedOriginal = try XCTUnwrap(journal.records[0].originalChoices)
        XCTAssertTrue(try propertyListsEqual(
            decodeChoices(recordedOriginal),
            originalChoices
        ))
    }

    func testPreparedDisableRecoversOriginalChoice() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetA)
        let originalChoices = try choices(originalAsset)
        let before = try storeData(selectedAsset: assetA)
        let target = try storeData(selectedAsset: originalAsset)
        try writeChoiceJournal(
            phase: "prepared",
            path: displayChoicePath,
            originalChoices: originalChoices,
            managedAssetIDs: [assetA],
            targetAssetID: nil,
            expectedData: before,
            targetData: target,
            to: fixture.journal
        )

        let result = try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(try selectedAsset(in: fixture.index), originalAsset)
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertEqual(journal.phase, "committed")
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testRemovedSpacePathRetiresWithoutBlockingCleanup() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetA)
        let originalData = try Data(contentsOf: fixture.index)
        let stalePath = "Spaces/\(spaceID.uuidString)/Displays/\(displayID.uuidString)/Linked/Content/Choices"
        try writeChoiceJournal(
            phase: "committed",
            path: stalePath,
            originalChoices: try choices(originalAsset),
            managedAssetIDs: [assetA],
            targetAssetID: assetA,
            to: fixture.journal
        )

        _ = try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [])

        XCTAssertEqual(try Data(contentsOf: fixture.index), originalData)
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testDifferentWALIAssetChosenExternallyIsPreservedDuringCleanup() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetB)
        try writeChoiceJournal(
            phase: "committed",
            path: displayChoicePath,
            originalChoices: try choices(originalAsset),
            managedAssetIDs: [assetA],
            targetAssetID: assetA,
            to: fixture.journal
        )

        _ = try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [])

        XCTAssertEqual(try selectedAsset(in: fixture.index), assetB)
    }

    func testPreparedReplacementDoesNotOverwriteExternalReturnToOriginal() throws {
        let fixture = try makeStoreFixture(selectedAsset: originalAsset)
        let expected = try storeData(selectedAsset: assetA)
        let target = try storeData(selectedAsset: assetB)
        try writeChoiceJournal(
            phase: "prepared",
            path: displayChoicePath,
            originalChoices: try choices(originalAsset),
            managedAssetIDs: [assetA, assetB],
            targetAssetID: assetB,
            expectedData: expected,
            targetData: target,
            to: fixture.journal
        )

        XCTAssertThrowsError(try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(assignments: [.init(displayUUID: displayID, assetID: assetB)]))
        XCTAssertEqual(try selectedAsset(in: fixture.index), originalAsset)
    }

    func testNewSpaceInheritingWALIChoiceRestoresDisplayOriginalOnDisable() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetA)
        try storeData(selectedAsset: assetA, spaceSelectedAsset: assetA).write(to: fixture.index)
        try writeChoiceJournal(
            phase: "committed",
            path: displayChoicePath,
            originalChoices: try choices(originalAsset),
            managedAssetIDs: [assetA],
            targetAssetID: assetA,
            to: fixture.journal
        )
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)

        _ = try editor.reconcile(
            assignments: [.init(displayUUID: displayID, assetID: assetA)],
            knownOwnedAssetIDs: [assetA]
        )
        _ = try editor.reconcile(assignments: [], knownOwnedAssetIDs: [assetA])

        XCTAssertEqual(try selectedAsset(in: fixture.index), originalAsset)
        XCTAssertEqual(try selectedAsset(in: fixture.index, spaceID: spaceID), originalAsset)
    }

    func testNewSpaceWithDifferentWALIChoiceFailsWithoutMutation() throws {
        let fixture = try makeStoreFixture(selectedAsset: assetA)
        try storeData(selectedAsset: assetA, spaceSelectedAsset: assetB).write(to: fixture.index)
        try writeChoiceJournal(
            phase: "committed",
            path: displayChoicePath,
            originalChoices: try choices(originalAsset),
            managedAssetIDs: [assetA],
            targetAssetID: assetA,
            to: fixture.journal
        )
        let indexBefore = try Data(contentsOf: fixture.index)
        let journalBefore = try Data(contentsOf: fixture.journal)

        XCTAssertThrowsError(try WallpaperStoreEditor(
            indexURL: fixture.index,
            journalURL: fixture.journal
        ).reconcile(
            assignments: [.init(displayUUID: displayID, assetID: assetA)],
            knownOwnedAssetIDs: [assetA, assetB]
        ))

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.journal), journalBefore)
        XCTAssertEqual(try selectedAsset(in: fixture.index, spaceID: spaceID), assetB)
    }

    func testMissingTopLevelDisplaysAreCreatedWithoutChangingGlobalOrSystemDefaults() throws {
        let displayAssets = [displayID, secondDisplayID, thirdDisplayID]
        let fixture = try makeEmptyDisplayStoreFixture()
        let before = try plistRoot(at: fixture.index)
        let globalBefore = try encodedPlistValue(before["AllSpacesAndDisplays"] as Any)
        let systemBefore = try encodedPlistValue(before["SystemDefault"] as Any)
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)

        let result = try editor.reconcile(assignments: displayAssets.map {
            .init(displayUUID: $0, assetID: assetA)
        })

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.patchedNodeCount, 3)
        for id in displayAssets {
            XCTAssertEqual(try selectedAsset(in: fixture.index, displayID: id), assetA)
        }
        let after = try plistRoot(at: fixture.index)
        XCTAssertEqual(try encodedPlistValue(after["AllSpacesAndDisplays"] as Any), globalBefore)
        XCTAssertEqual(try encodedPlistValue(after["SystemDefault"] as Any), systemBefore)
        XCTAssertTrue((after["Spaces"] as? [String: Any])?.isEmpty == true)
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertEqual(journal.records.count, 3)
        XCTAssertTrue(journal.records.allSatisfy { $0.createdDisplayNode == true })
        XCTAssertTrue(journal.records.allSatisfy { $0.originalChoices == nil })
    }

    func testDisablingRemovesOnlySynthesizedDisplayNodesAndRestoresOriginalRoot() throws {
        let fixture = try makeEmptyDisplayStoreFixture()
        let original = try plistRoot(at: fixture.index)
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
            .init(displayUUID: secondDisplayID, assetID: assetA),
            .init(displayUUID: thirdDisplayID, assetID: assetA),
        ])

        let result = try editor.reconcile(assignments: [])

        XCTAssertTrue(result.changed)
        XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(to: original))
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testPreparedSynthesizedDisplayNodeRecoversBeforeAndAfterIndexReplacement() throws {
        for indexAlreadyReplaced in [false, true] {
            let fixture = try makeEmptyDisplayStoreFixture()
            let before = try Data(contentsOf: fixture.index)
            let target = try emptyDisplayStoreData(displayAssets: [displayID: assetA])
            if indexAlreadyReplaced { try target.write(to: fixture.index) }
            try writeChoiceJournal(
                phase: "prepared",
                path: displayChoicePath,
                originalChoices: nil,
                managedAssetIDs: [assetA],
                targetAssetID: assetA,
                createdDisplayNode: true,
                expectedData: before,
                targetData: target,
                to: fixture.journal
            )
            let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)

            let result = try editor.reconcile(assignments: [
                .init(displayUUID: displayID, assetID: assetA),
            ])

            XCTAssertTrue(result.changed)
            XCTAssertEqual(try selectedAsset(in: fixture.index), assetA)
            _ = try editor.reconcile(assignments: [])
            XCTAssertTrue(NSDictionary(dictionary: try plistRoot(at: fixture.index)).isEqual(
                to: try plistRoot(from: before)
            ))
        }
    }

    func testExternallyChangedSynthesizedDisplayNodeIsPreservedOnDisable() throws {
        let fixture = try makeEmptyDisplayStoreFixture()
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(assignments: [
            .init(displayUUID: displayID, assetID: assetA),
        ])
        var externallyChanged = try plistRoot(at: fixture.index)
        var displays = try XCTUnwrap(externallyChanged["Displays"] as? [String: Any])
        let externalNode: [String: Any] = [
            "Linked": ["Content": ["Choices": try choices(originalAsset)]],
            "ExternalMarker": Data("preserve me".utf8),
        ]
        displays[displayID.uuidString] = externalNode
        externallyChanged["Displays"] = displays
        try PropertyListSerialization.data(
            fromPropertyList: externallyChanged,
            format: .binary,
            options: 0
        ).write(to: fixture.index)

        _ = try editor.reconcile(assignments: [])

        let final = try plistRoot(at: fixture.index)
        let finalDisplays = try XCTUnwrap(final["Displays"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(
            finalDisplays[displayID.uuidString] as? [String: Any]
        )).isEqual(to: externalNode))
        let journal = try JSONDecoder().decode(
            ChoiceJournalProbe.self,
            from: Data(contentsOf: fixture.journal)
        )
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testDifferentKnownWALIAssetOnSynthesizedNodeBlocksDisableWithoutMutation() throws {
        let fixture = try makeEmptyDisplayStoreFixture()
        let editor = WallpaperStoreEditor(indexURL: fixture.index, journalURL: fixture.journal)
        _ = try editor.reconcile(
            assignments: [.init(displayUUID: displayID, assetID: assetA)],
            knownOwnedAssetIDs: [assetA, assetB]
        )
        try emptyDisplayStoreData(displayAssets: [displayID: assetB]).write(to: fixture.index)
        let indexBefore = try Data(contentsOf: fixture.index)
        let journalBefore = try Data(contentsOf: fixture.journal)

        XCTAssertThrowsError(try editor.reconcile(
            assignments: [],
            knownOwnedAssetIDs: [assetA, assetB]
        )) { error in
            guard case LockScreenCompatibilityError.ownershipConflict = error else {
                return XCTFail("Expected an ownership conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.index), indexBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.journal), journalBefore)
        XCTAssertEqual(try selectedAsset(in: fixture.index), assetB)
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
                    itemID: assetA,
                    name: "Synthetic",
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
                    itemID: assetA,
                    name: "Synthetic",
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
                        itemID: assetA,
                        name: "Synthetic",
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
            XCTAssertTrue(caughtError.localizedDescription.contains("WALI Agent"))
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
        XCTAssertTrue(direct.localizedDescription.contains("WALI Agent"))

        let nested = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)]
        )
        let mappedNested = LockScreenFileIO.actionableTransactionalWriteError(nested)
        XCTAssertTrue(mappedNested.localizedDescription.contains("Full Disk Access"))
        XCTAssertTrue(mappedNested.localizedDescription.contains("WALI Agent"))

        let unrelated = LockScreenCompatibilityError.malformedStore("Synthetic schema failure")
        XCTAssertEqual(
            LockScreenFileIO.actionableTransactionalWriteError(unrelated).localizedDescription,
            unrelated.localizedDescription
        )
    }

    func testPermissionDenialPreservesPreparedRecoveryJournalAndAppleStores() async throws {
        let fixture = try makeCoordinatorFixture(indexHasDisplay: true)
        let preparedJournal = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "transactionID": UUID().uuidString,
            "phase": "prepared",
            "records": [[
                "id": assetA.uuidString,
                "mayRemove": true,
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
            "schemaVersion": 1,
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
            itemID: assetA,
            name: "Synthetic A",
            masterURL: fixture.master,
            posterURL: fixture.poster
        )
        let secondAssignment = LockScreenWallpaperAssignment(
            displayID: "uuid:\(displayID.uuidString)",
            itemID: assetB,
            name: "Synthetic B",
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
        XCTAssertEqual(try selectedAsset(in: fixture.paths.indexURL), assetB)
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
        XCTAssertTrue(failure.localizedDescription.contains("WALI Agent"))
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

    private var displayChoicePath: String {
        "Displays/\(displayID.uuidString)/Linked/Content/Choices"
    }

    private func makeStoreFixture(selectedAsset: UUID) throws -> StoreFixture {
        let root = try temporaryDirectory()
        let index = root.appendingPathComponent("Index.plist")
        let journal = root.appendingPathComponent("choice-journal.json")
        try storeData(selectedAsset: selectedAsset).write(to: index)
        return .init(index: index, journal: journal)
    }

    private func makeEmptyDisplayStoreFixture() throws -> StoreFixture {
        let root = try temporaryDirectory()
        let index = root.appendingPathComponent("Index.plist")
        let journal = root.appendingPathComponent("choice-journal.json")
        try emptyDisplayStoreData(displayAssets: [:]).write(to: index)
        return .init(index: index, journal: journal)
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
        let indexData = indexHasDisplay
            ? try storeData(selectedAsset: originalAsset)
            : try PropertyListSerialization.data(
                fromPropertyList: ["Displays": [String: Any](), "Spaces": [String: Any]()],
                format: .binary,
                options: 0
            )
        try indexData.write(to: index)
        let master = owned.appendingPathComponent("master.mov")
        let poster = owned.appendingPathComponent("poster.bin")
        try Data("synthetic video".utf8).write(to: master)
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!.write(to: poster)
        return .init(
            ownedRoot: owned,
            master: master,
            poster: poster,
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

    private func storeData(
        selectedAsset: UUID,
        spaceSelectedAsset: UUID? = nil
    ) throws -> Data {
        let spaces: [String: Any] = if let spaceSelectedAsset {
            [
                spaceID.uuidString: [
                    "Displays": [
                        displayID.uuidString: [
                            "Linked": ["Content": ["Choices": try choices(spaceSelectedAsset)]],
                        ],
                    ],
                ],
            ]
        } else {
            [:]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Displays": [
                    displayID.uuidString: [
                        "Linked": ["Content": ["Choices": try choices(selectedAsset)]],
                    ],
                ],
                "Spaces": spaces,
            ],
            format: .binary,
            options: 0
        )
    }

    private func emptyDisplayStoreData(displayAssets: [UUID: UUID]) throws -> Data {
        let displays: [String: Any] = try Dictionary(
            uniqueKeysWithValues: displayAssets.map { displayID, assetID in
            (
                displayID.uuidString,
                ["Linked": ["Content": ["Choices": try choices(assetID)]]] as [String: Any]
            )
        })
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "AllSpacesAndDisplays": [
                    "Linked": [
                        "Content": [
                            "Choices": [[
                                "Provider": "com.apple.wallpaper.choice.image",
                                "Configuration": Data("global-image-choice".utf8),
                            ]],
                            "OpaqueGlobalValue": Data([0x01, 0x02, 0x03]),
                        ],
                    ],
                ],
                "SystemDefault": [
                    "Linked": [
                        "Content": [
                            "Choices": [[
                                "Provider": "com.apple.wallpaper.choice.image",
                                "Configuration": Data("system-image-choice".utf8),
                            ]],
                        ],
                    ],
                    "OpaqueSystemValue": Data([0x04, 0x05, 0x06]),
                ],
                "Displays": displays,
                "Spaces": [String: Any](),
            ],
            format: .binary,
            options: 0
        )
    }

    private func writeChoiceJournal(
        phase: String,
        path: String,
        originalChoices: [Any]?,
        managedAssetIDs: [UUID],
        targetAssetID: UUID?,
        createdDisplayNode: Bool = false,
        expectedData: Data? = nil,
        targetData: Data? = nil,
        to url: URL
    ) throws {
        var record: [String: Any] = [
            "path": path,
            "managedAssetIDs": managedAssetIDs.map(\.uuidString),
            "createdDisplayNode": createdDisplayNode,
        ]
        if let originalChoices {
            let original = try PropertyListSerialization.data(
                fromPropertyList: originalChoices,
                format: .binary,
                options: 0
            )
            record["originalChoices"] = original.base64EncodedString()
        }
        if let targetAssetID { record["targetAssetID"] = targetAssetID.uuidString }
        var journal: [String: Any] = [
            "schemaVersion": 2,
            "phase": phase,
            "records": [record],
        ]
        if let expectedData { journal["expectedIndexDigest"] = digest(expectedData) }
        if let targetData { journal["targetIndexDigest"] = digest(targetData) }
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: url)
    }

    private func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func selectedAsset(
        in index: URL,
        displayID: UUID? = nil,
        spaceID: UUID? = nil
    ) throws -> UUID? {
        let root = try plistRoot(at: index)
        let resolvedDisplayID = displayID ?? self.displayID
        let display: [String: Any]?
        if let spaceID {
            let spaces = root["Spaces"] as? [String: Any]
            let space = spaces?[spaceID.uuidString] as? [String: Any]
            display = (space?["Displays"] as? [String: Any])?[resolvedDisplayID.uuidString] as? [String: Any]
        } else {
            display = (root["Displays"] as? [String: Any])?[resolvedDisplayID.uuidString] as? [String: Any]
        }
        let linked = display?["Linked"] as? [String: Any]
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

    private func decodeChoices(_ data: Data) throws -> [Any] {
        guard let choices = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return choices
    }

    private func propertyListsEqual(_ lhs: [Any], _ rhs: [Any]) throws -> Bool {
        NSArray(array: lhs).isEqual(to: rhs)
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
    let paths: LockScreenStorePaths
}

private struct ChoiceJournalProbe: Decodable {
    struct Record: Decodable {
        let originalChoices: Data?
        let managedAssetIDs: [UUID]
        let targetAssetID: UUID?
        let createdDisplayNode: Bool?
    }

    let phase: String
    let records: [Record]
}

private struct AssetJournalProbe: Decodable {
    struct Record: Decodable {
        let id: UUID
    }

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
