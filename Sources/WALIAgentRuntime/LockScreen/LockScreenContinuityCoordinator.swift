import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LockScreenCompatibilityEpoch {
    public static let supportedSystemBuilds: Set<String> = ["25F80"]
    public static let manifestEpoch = 1
    public static let manifestRevision = 1

    public static func currentSystemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

public struct LockScreenStorePaths: Sendable, Hashable {
    public let manifestURL: URL
    public let videosDirectory: URL
    public let thumbnailsDirectory: URL
    public let indexURL: URL
    public let journalURL: URL
    public let assetJournalURL: URL

    public init(
        manifestURL: URL,
        videosDirectory: URL,
        thumbnailsDirectory: URL,
        indexURL: URL,
        journalURL: URL,
        assetJournalURL: URL
    ) {
        self.manifestURL = manifestURL
        self.videosDirectory = videosDirectory
        self.thumbnailsDirectory = thumbnailsDirectory
        self.indexURL = indexURL
        self.journalURL = journalURL
        self.assetJournalURL = assetJournalURL
    }

    public static func live(waliMetadataDirectory: URL) -> Self {
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let wallpaper = applicationSupport
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
        let aerials = wallpaper.appendingPathComponent("aerials", isDirectory: true)
        return Self(
            manifestURL: aerials.appendingPathComponent("manifest/entries.json"),
            videosDirectory: aerials.appendingPathComponent("videos", isDirectory: true),
            thumbnailsDirectory: aerials.appendingPathComponent("thumbnails", isDirectory: true),
            indexURL: wallpaper.appendingPathComponent("Store/Index.plist"),
            journalURL: waliMetadataDirectory.appendingPathComponent(
                "lock-screen-choice-journal.json",
                isDirectory: false
            ),
            assetJournalURL: waliMetadataDirectory.appendingPathComponent(
                "lock-screen-asset-journal.json",
                isDirectory: false
            )
        )
    }
}

public struct LockScreenWallpaperAssignment: Sendable, Hashable {
    public let displayID: String
    public let isMain: Bool
    public let itemID: UUID
    public let name: String
    public let masterBitDepth: UInt16?
    public let masterArtifactSHA256: String?
    public let posterArtifactSHA256: String?
    public let masterURL: URL
    public let posterURL: URL

    public init(
        displayID: String,
        isMain: Bool,
        itemID: UUID,
        name: String,
        masterBitDepth: UInt16?,
        masterArtifactSHA256: String?,
        posterArtifactSHA256: String?,
        masterURL: URL,
        posterURL: URL
    ) {
        self.displayID = displayID
        self.isMain = isMain
        self.itemID = itemID
        self.name = name
        self.masterBitDepth = masterBitDepth
        self.masterArtifactSHA256 = masterArtifactSHA256
        self.posterArtifactSHA256 = posterArtifactSHA256
        self.masterURL = masterURL
        self.posterURL = posterURL
    }
}

public struct LockScreenContinuityResult: Sendable, Hashable {
    public let changed: Bool
    public let registeredAssets: Int
    public let patchedNodes: Int
}

/// Serializes the opt-in current-user adapter. Every path and build probe is
/// injectable so validation can run against isolated fixtures without touching
/// the user's live Apple wallpaper store.
public actor LockScreenContinuityCoordinator {
    public typealias RefreshHandler = @Sendable () async -> ()
    public typealias QuiesceHandler = @Sendable () async throws -> ()
    public typealias PermissionPreflight = @Sendable ([URL]) throws -> Void

    private static let maximumMasterBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    private static let maximumPosterBytes: UInt64 = 128 * 1_024 * 1_024
    private static let maximumPNGBytes: UInt64 = 128 * 1_024 * 1_024
    private static let maximumChoiceJournalBytes: UInt64 = 4 * 1_024 * 1_024
    private static let maximumAssetJournalBytes: UInt64 = 1_024 * 1_024
    private static let maximumAssetJournalRecords = AerialManifestEditor.maximumOwnedAssets * 4

    private let paths: LockScreenStorePaths
    private let ownedLibraryRoot: URL
    private let systemBuild: String
    private let refreshHandler: RefreshHandler
    private let quiesceHandler: QuiesceHandler
    private let permissionPreflight: PermissionPreflight
    private let permissionClock = ContinuousClock()
    private var permissionPreflightValidUntil: ContinuousClock.Instant?
    private var reconciliationActive = false
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        paths: LockScreenStorePaths,
        ownedLibraryRoot: URL,
        systemBuild: String = LockScreenCompatibilityEpoch.currentSystemBuild(),
        refreshHandler: @escaping RefreshHandler = {},
        quiesceHandler: @escaping QuiesceHandler = {},
        permissionPreflight: PermissionPreflight? = nil
    ) {
        self.paths = paths
        self.ownedLibraryRoot = ownedLibraryRoot.standardizedFileURL
        self.systemBuild = systemBuild
        self.refreshHandler = refreshHandler
        self.quiesceHandler = quiesceHandler
        self.permissionPreflight = permissionPreflight ?? { directories in
            for directory in directories {
                try LockScreenFileIO.requireTransactionalWriteAccess(to: directory)
            }
        }
    }

    public static func live(
        waliMetadataDirectory: URL,
        ownedLibraryRoot: URL
    ) -> LockScreenContinuityCoordinator {
        LockScreenContinuityCoordinator(
            paths: .live(waliMetadataDirectory: waliMetadataDirectory),
            ownedLibraryRoot: ownedLibraryRoot,
            refreshHandler: {
                await Self.terminateApplications(bundleIdentifiers: [
                    "com.apple.wallpaper.agent",
                    "com.apple.wallpaper.extension.aerials",
                ])
            },
            quiesceHandler: {
                await Self.terminateApplications(bundleIdentifiers: [
                    "com.apple.wallpaper.agent",
                ])
                try await Task.sleep(for: .seconds(1))
            }
        )
    }

    public func validate(
        enabled: Bool,
        assignments: [LockScreenWallpaperAssignment]
    ) throws {
        if !enabled, !hasOwnedJournal { return }
        _ = try makePreflightPlan(
            enabled: enabled,
            assignments: assignments,
            forcePermissionPreflight: enabled
        )
    }

    @discardableResult
    public func reconcile(
        enabled: Bool,
        assignments: [LockScreenWallpaperAssignment]
    ) async throws -> LockScreenContinuityResult {
        await acquireReconciliationAccess()
        var holdsReconciliationAccess = true
        defer {
            if holdsReconciliationAccess { releaseReconciliationAccess() }
        }
        try Task.checkCancellation()
        if !enabled, !hasOwnedJournal {
            return .init(changed: false, registeredAssets: 0, patchedNodes: 0)
        }
        var plan = try makePreflightPlan(enabled: enabled, assignments: assignments)
        var didQuiesce = false
        if plan.requiresTransactionMutation {
            try await quiesceHandler()
            didQuiesce = true
            plan = try makePreflightPlan(enabled: enabled, assignments: assignments)
        }
        if !plan.recoveryActions.isEmpty {
            guard didQuiesce else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A transaction recovery sibling cannot be finalized before quiescing."
                )
            }
            for action in plan.recoveryActions {
                try LockScreenFileIO.finalizeRecoveryFile(
                    action.url,
                    expectedDigest: action.digest,
                    maximumBytes: action.maximumBytes
                )
            }
            plan = try makePreflightPlan(enabled: enabled, assignments: assignments)
        }

        if !plan.requiresTransactionMutation {
            let shouldRefresh = plan.refreshPending
            let currentJournal = try loadAssetJournal()
            releaseReconciliationAccess()
            holdsReconciliationAccess = false
            if shouldRefresh {
                await refreshHandler()
                try finalizeRefresh(
                    for: currentJournal,
                    removeJournals: plan.eligible.isEmpty
                )
            }
            return .init(
                changed: shouldRefresh,
                registeredAssets: plan.desiredIDs.count,
                patchedNodes: 0
            )
        }
        guard didQuiesce else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The Lock Screen transaction changed after preview and was not allowed to write."
            )
        }

        let transactionID = plan.transactionID
        let eligible = plan.eligible
        let grouped = Dictionary(grouping: eligible, by: \.itemID)
        let desiredIDs = plan.desiredIDs
        guard plan.preparedRecords.count <= Self.maximumAssetJournalRecords else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The interrupted asset journal exceeds WALI’s recovery bound."
            )
        }
        let preparedJournal = LockScreenAssetJournal(
            transactionID: transactionID,
            phase: .prepared,
            records: plan.preparedRecords,
            refreshPending: true
        )
        try saveAssetJournal(preparedJournal)

        let records = Dictionary(uniqueKeysWithValues: plan.preparedRecords.map { ($0.id, $0) })
        let ownershipMarker = Self.assetOwnershipMarker(for: transactionID)
        var assetFilesChanged = false
        var registrations: [AerialAssetRegistration] = []
        for itemID in desiredIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let assignment = grouped[itemID]?.first,
                  let asset = plan.desiredAssets[itemID],
                  let record = records[itemID] else {
                throw LockScreenCompatibilityError.assetRejected("A prepared asset is missing.")
            }
            assetFilesChanged = try LockScreenFileIO.atomicInstallCopy(
                from: asset.videoSourceURL,
                to: assetVideoURL(for: itemID),
                expectedDigest: record.video.expectedDigest,
                targetDigest: asset.videoDigest,
                maximumBytes: Self.maximumMasterBytes,
                ownershipMarker: ownershipMarker,
                recoveryURL: assetRecoveryURL(
                    for: itemID,
                    role: "video",
                    transactionID: transactionID
                )
            ) || assetFilesChanged
            assetFilesChanged = try LockScreenFileIO.atomicInstallData(
                asset.thumbnailData,
                to: assetThumbnailURL(for: itemID),
                expectedDigest: record.thumbnail.expectedDigest,
                targetDigest: asset.thumbnailDigest,
                maximumBytes: Self.maximumPNGBytes,
                ownershipMarker: ownershipMarker,
                recoveryURL: assetRecoveryURL(
                    for: itemID,
                    role: "thumbnail",
                    transactionID: transactionID
                )
            ) { staged in
                guard CGImageSourceCreateWithURL(staged as CFURL, nil) != nil else {
                    throw LockScreenCompatibilityError.assetRejected(
                        "The staged PNG could not be decoded."
                    )
                }
            } || assetFilesChanged
            registrations.append(.init(
                id: itemID,
                name: assignment.name,
                videoURL: assetVideoURL(for: itemID),
                thumbnailURL: assetThumbnailURL(for: itemID)
            ))
        }
        for record in plan.preparedRecords where !desiredIDs.contains(record.id) {
            assetFilesChanged = try LockScreenFileIO.atomicRemove(
                assetVideoURL(for: record.id),
                expectedDigest: record.video.expectedDigest,
                maximumBytes: Self.maximumMasterBytes,
                recoveryURL: assetRecoveryURL(
                    for: record.id,
                    role: "video",
                    transactionID: transactionID
                )
            ) || assetFilesChanged
            assetFilesChanged = try LockScreenFileIO.atomicRemove(
                assetThumbnailURL(for: record.id),
                expectedDigest: record.thumbnail.expectedDigest,
                maximumBytes: Self.maximumPNGBytes,
                recoveryURL: assetRecoveryURL(
                    for: record.id,
                    role: "thumbnail",
                    transactionID: transactionID
                )
            ) || assetFilesChanged
        }

        let manifestResult = try AerialManifestEditor(
            manifestURL: paths.manifestURL
        ).reconcile(registrations: registrations)
        let storeResult = try WallpaperStoreEditor(
            indexURL: paths.indexURL,
            journalURL: paths.journalURL
        ).reconcile(
            assignments: plan.storeAssignments,
            knownOwnedAssetIDs: plan.manifestOwnedIDs.union(plan.journalOwnedIDs).union(desiredIDs)
        )
        let shouldRefresh = assetFilesChanged
            || manifestResult.changed
            || storeResult.changed
            || plan.refreshPending
        let pendingJournal = LockScreenAssetJournal(
            transactionID: transactionID,
            phase: .committed,
            records: plan.committedRecords,
            refreshPending: shouldRefresh
        )
        try saveAssetJournal(pendingJournal)
        releaseReconciliationAccess()
        holdsReconciliationAccess = false
        if shouldRefresh { await refreshHandler() }
        try finalizeRefresh(for: pendingJournal, removeJournals: eligible.isEmpty)
        return .init(
            changed: shouldRefresh,
            registeredAssets: registrations.count,
            patchedNodes: storeResult.patchedNodeCount
        )
    }

    private func validateStore(forcePermissionPreflight: Bool) throws {
        guard LockScreenCompatibilityEpoch.supportedSystemBuilds.contains(systemBuild) else {
            let verified = LockScreenCompatibilityEpoch.supportedSystemBuilds.sorted().joined(separator: ", ")
            throw LockScreenCompatibilityError.unsupportedSystem(
                "Verified build: \(verified); current build: \(systemBuild)."
            )
        }
        let journalDirectory = paths.journalURL.deletingLastPathComponent()
        let assetJournalDirectory = paths.assetJournalURL.deletingLastPathComponent()
        guard Self.isContained(journalDirectory, in: ownedLibraryRoot),
              Self.isContained(assetJournalDirectory, in: ownedLibraryRoot) else {
            throw LockScreenCompatibilityError.unsafePath("Rollback journals escaped WALI’s library.")
        }
        guard journalDirectory.standardizedFileURL == assetJournalDirectory.standardizedFileURL else {
            throw LockScreenCompatibilityError.unsafePath("Rollback journals must share WALI’s metadata directory.")
        }
        do {
            try LockScreenFileIO.requireDirectory(paths.videosDirectory)
            try LockScreenFileIO.requireDirectory(paths.thumbnailsDirectory)
            try AerialManifestEditor(manifestURL: paths.manifestURL).validate()
            try WallpaperStoreEditor(indexURL: paths.indexURL, journalURL: paths.journalURL).validate()
        } catch {
            throw LockScreenFileIO.actionableTransactionalWriteError(error)
        }
        try LockScreenFileIO.requireDirectory(journalDirectory)
        _ = try loadAssetJournal()
        if !forcePermissionPreflight,
           let validUntil = permissionPreflightValidUntil,
           permissionClock.now < validUntil {
            return
        }
        let writeDirectories = [
            paths.videosDirectory,
            paths.thumbnailsDirectory,
            paths.manifestURL.deletingLastPathComponent(),
            paths.indexURL.deletingLastPathComponent(),
        ]
        do {
            try permissionPreflight(writeDirectories)
        } catch {
            throw LockScreenFileIO.actionableTransactionalWriteError(error)
        }
        // The manifest and Store directories are event-monitored. Cache only
        // long enough for the probe's own coalesced event to avoid a feedback
        // loop; explicit false-to-true validation always forces a fresh probe.
        permissionPreflightValidUntil = permissionClock.now.advanced(by: .seconds(5))
    }

    /// Builds and validates the complete cross-file transaction before any
    /// Apple manifest, Index, asset file, or WALI journal is mutated.
    private func makePreflightPlan(
        enabled: Bool,
        assignments: [LockScreenWallpaperAssignment],
        forcePermissionPreflight: Bool = false
    ) throws -> PreflightPlan {
        try validateStore(forcePermissionPreflight: forcePermissionPreflight)
        let eligible = enabled ? try eligibleAssignments(assignments) : []
        let grouped = Dictionary(grouping: eligible, by: \.itemID)
        guard grouped.count <= AerialManifestEditor.maximumOwnedAssets else {
            throw LockScreenCompatibilityError.assetRejected("At most eight Lock Screen wallpapers can be active.")
        }
        var desiredAssets: [UUID: PreparedLockScreenAsset] = [:]
        for assignment in eligible {
            guard assignment.masterBitDepth == 10 else {
                throw LockScreenCompatibilityError.assetRejected(
                    "Re-import this wallpaper to prepare a verified 10-bit Lock Screen master."
                )
            }
            try validateOwnedSource(assignment.masterURL, maximumBytes: Self.maximumMasterBytes)
            try validateOwnedSource(assignment.posterURL, maximumBytes: Self.maximumPosterBytes)
            let expectedMasterDigest = try Self.persistedDigest(
                assignment.masterArtifactSHA256,
                role: "master"
            )
            let expectedPosterDigest = try Self.persistedDigest(
                assignment.posterArtifactSHA256,
                role: "poster"
            )
            let masterDigest = try LockScreenFileIO.sha256(
                of: assignment.masterURL,
                maximumBytes: Self.maximumMasterBytes
            )
            let posterDigest = try LockScreenFileIO.sha256(
                of: assignment.posterURL,
                maximumBytes: Self.maximumPosterBytes
            )
            guard masterDigest == expectedMasterDigest, posterDigest == expectedPosterDigest else {
                throw LockScreenCompatibilityError.assetRejected(
                    "The verified library copy changed. Re-import this wallpaper before enabling Lock Screen continuity."
                )
            }
            let png = try Self.makePNG(from: assignment.posterURL)
            guard png.count <= Self.maximumPNGBytes else {
                throw LockScreenCompatibilityError.assetRejected("The generated thumbnail is too large.")
            }
            guard try LockScreenFileIO.sha256(
                of: assignment.posterURL,
                maximumBytes: Self.maximumPosterBytes
            ) == expectedPosterDigest else {
                throw LockScreenCompatibilityError.assetRejected(
                    "The verified poster changed while preparing it. Re-import this wallpaper."
                )
            }
            desiredAssets[assignment.itemID] = .init(
                videoSourceURL: assignment.masterURL,
                videoDigest: masterDigest,
                thumbnailData: png,
                thumbnailDigest: LockScreenFileIO.sha256(of: png)
            )
        }

        let desiredIDs = Set(grouped.keys)
        let manifestOwnedIDs = try AerialManifestEditor(
            manifestURL: paths.manifestURL
        ).preflight(desiredAssetIDs: desiredIDs)
        let assetJournal = try loadAssetJournal()
        let transactionID: UUID
        if assetJournal.phase == .prepared {
            guard let preparedTransactionID = assetJournal.transactionID else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "A prepared WALI asset journal has no recovery transaction identifier."
                )
            }
            transactionID = preparedTransactionID
        } else {
            transactionID = UUID()
        }
        let journalOwnedIDs = Set(assetJournal.records.map(\.id))
        guard manifestOwnedIDs.isSubset(of: journalOwnedIDs) else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A WALI manifest asset has no digest-backed ownership journal."
            )
        }
        let journalRecords = Dictionary(uniqueKeysWithValues: assetJournal.records.map { ($0.id, $0) })
        var preparedRecords: [LockScreenAssetJournalRecord] = []
        var recoveryActions: [LockScreenAssetRecoveryAction] = []
        var assetFilesChanged = false
        for id in journalOwnedIDs.union(desiredIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            let existing = journalRecords[id]
            let videoURL = assetVideoURL(for: id)
            let thumbnailURL = assetThumbnailURL(for: id)
            let videoRecoveryURL = assetRecoveryURL(
                for: id,
                role: "video",
                transactionID: transactionID
            )
            let thumbnailRecoveryURL = assetRecoveryURL(
                for: id,
                role: "thumbnail",
                transactionID: transactionID
            )
            let observedVideo = try observedDigest(
                at: videoURL,
                maximumBytes: Self.maximumMasterBytes,
                authorizedBy: existing?.video
            )
            let observedThumbnail = try observedDigest(
                at: thumbnailURL,
                maximumBytes: Self.maximumPNGBytes,
                authorizedBy: existing?.thumbnail
            )
            if assetJournal.phase == .prepared, let existing {
                let ownershipMarker = Self.assetOwnershipMarker(for: transactionID)
                try validatePreparedTargetProvenance(
                    at: videoURL,
                    observedDigest: observedVideo,
                    transition: existing.video,
                    ownershipMarker: ownershipMarker
                )
                try validatePreparedTargetProvenance(
                    at: thumbnailURL,
                    observedDigest: observedThumbnail,
                    transition: existing.thumbnail,
                    ownershipMarker: ownershipMarker
                )
                if let action = try recoveryAction(
                    at: videoRecoveryURL,
                    destinationDigest: observedVideo,
                    transition: existing.video,
                    ownershipMarker: ownershipMarker,
                    maximumBytes: Self.maximumMasterBytes
                ) {
                    recoveryActions.append(action)
                }
                if let action = try recoveryAction(
                    at: thumbnailRecoveryURL,
                    destinationDigest: observedThumbnail,
                    transition: existing.thumbnail,
                    ownershipMarker: ownershipMarker,
                    maximumBytes: Self.maximumPNGBytes
                ) {
                    recoveryActions.append(action)
                }
            } else if try LockScreenFileIO.nodeExists(videoRecoveryURL)
                        || LockScreenFileIO.nodeExists(thumbnailRecoveryURL) {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A transaction recovery path was already occupied before journal publication."
                )
            }
            let targetVideo = desiredAssets[id]?.videoDigest
            let targetThumbnail = desiredAssets[id]?.thumbnailDigest
            assetFilesChanged = assetFilesChanged
                || observedVideo != targetVideo
                || observedThumbnail != targetThumbnail
            if targetVideo != nil || targetThumbnail != nil
                || observedVideo != nil || observedThumbnail != nil {
                preparedRecords.append(.init(
                    id: id,
                    video: .init(expectedDigest: observedVideo, targetDigest: targetVideo),
                    thumbnail: .init(
                        expectedDigest: observedThumbnail,
                        targetDigest: targetThumbnail
                    )
                ))
            }
        }
        let committedRecords = desiredIDs.sorted(by: { $0.uuidString < $1.uuidString }).compactMap {
            id -> LockScreenAssetJournalRecord? in
            guard let asset = desiredAssets[id] else { return nil }
            return .init(
                id: id,
                video: .init(expectedDigest: asset.videoDigest, targetDigest: asset.videoDigest),
                thumbnail: .init(
                    expectedDigest: asset.thumbnailDigest,
                    targetDigest: asset.thumbnailDigest
                )
            )
        }
        let storeAssignments = try eligible.map { assignment -> WallpaperStoreAssignment in
            guard let displayID = Self.displayUUID(from: assignment.displayID) else {
                throw LockScreenCompatibilityError.assetRejected("A display does not expose a stable UUID.")
            }
            return WallpaperStoreAssignment(displayUUID: displayID, assetID: assignment.itemID)
        }
        let storePreview = try WallpaperStoreEditor(
            indexURL: paths.indexURL,
            journalURL: paths.journalURL
        ).preflight(
            assignments: storeAssignments,
            knownOwnedAssetIDs: manifestOwnedIDs.union(journalOwnedIDs).union(desiredIDs)
        )
        let registrations = grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }).compactMap {
            itemID -> AerialAssetRegistration? in
            guard let assignment = grouped[itemID]?.first else { return nil }
            return .init(
                id: itemID,
                name: assignment.name,
                videoURL: paths.videosDirectory.appendingPathComponent(
                    "\(itemID.uuidString.uppercased()).mov"
                ),
                thumbnailURL: paths.thumbnailsDirectory.appendingPathComponent(
                    "\(itemID.uuidString.uppercased()).png"
                )
            )
        }
        let manifestPreview = try AerialManifestEditor(
            manifestURL: paths.manifestURL
        ).preview(registrations: registrations)
        let requiresManagedStoreMutation = storePreview.changed || manifestPreview.changed
        let requiresJournalCommit = assetJournal.phase != .committed
            || assetJournal.records != committedRecords
        return .init(
            transactionID: transactionID,
            eligible: eligible,
            desiredIDs: desiredIDs,
            manifestOwnedIDs: manifestOwnedIDs,
            journalOwnedIDs: journalOwnedIDs,
            refreshPending: assetJournal.refreshPending,
            desiredAssets: desiredAssets,
            preparedRecords: preparedRecords,
            committedRecords: committedRecords,
            recoveryActions: recoveryActions,
            storeAssignments: storeAssignments,
            requiresManagedStoreMutation: requiresManagedStoreMutation,
            requiresTransactionMutation: assetFilesChanged
                || requiresManagedStoreMutation
                || requiresJournalCommit
                || !recoveryActions.isEmpty
                || (eligible.isEmpty && hasOwnedJournal)
        )
    }

    private var hasOwnedJournal: Bool {
        FileManager.default.fileExists(atPath: paths.journalURL.path)
            || FileManager.default.fileExists(atPath: paths.assetJournalURL.path)
    }

    /// Quiescing and refreshing suspend this actor. Keep the complete
    /// cross-file transaction single-flight so a later reconcile cannot copy
    /// or remove assets underneath an earlier suspended invocation.
    private func acquireReconciliationAccess() async {
        guard reconciliationActive else {
            reconciliationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            reconciliationWaiters.append(continuation)
        }
    }

    private func releaseReconciliationAccess() {
        guard !reconciliationWaiters.isEmpty else {
            reconciliationActive = false
            return
        }
        reconciliationWaiters.removeFirst().resume()
    }

    private func eligibleAssignments(
        _ assignments: [LockScreenWallpaperAssignment]
    ) throws -> [LockScreenWallpaperAssignment] {
        var seenDisplays: Set<UUID> = []
        var mainAssignment: LockScreenWallpaperAssignment?
        for assignment in assignments {
            guard let displayID = Self.displayUUID(from: assignment.displayID) else { continue }
            guard seenDisplays.insert(displayID).inserted else {
                throw LockScreenCompatibilityError.assetRejected("A display assignment is duplicated.")
            }
            if assignment.isMain {
                guard mainAssignment == nil else {
                    throw LockScreenCompatibilityError.assetRejected(
                        "More than one active display is marked as the main display."
                    )
                }
                mainAssignment = assignment
            }
        }
        return mainAssignment.map { [$0] } ?? []
    }

    private static func terminateApplications(bundleIdentifiers: Set<String>) async {
        await MainActor.run {
            for bundleIdentifier in bundleIdentifiers {
                for application in NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ) {
                    if !application.terminate() { _ = application.forceTerminate() }
                }
            }
        }
    }

    private static func displayUUID(from stableID: String) -> UUID? {
        guard stableID.lowercased().hasPrefix("uuid:") else { return nil }
        return UUID(uuidString: String(stableID.dropFirst(5)))
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func validateOwnedSource(_ source: URL, maximumBytes: UInt64) throws {
        try LockScreenFileIO.requireRegularFile(source, maximumBytes: maximumBytes)
        let resolvedRoot = ownedLibraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedSource == resolvedRoot || resolvedSource.hasPrefix(resolvedRoot + "/") else {
            throw LockScreenCompatibilityError.unsafePath("A source escaped WALI’s verified library.")
        }
    }

    private static func persistedDigest(_ value: String?, role: String) throws -> Data {
        guard let value,
              value.utf8.count == 64,
              value == value.lowercased() else {
            throw LockScreenCompatibilityError.assetRejected(
                "The persisted \(role) identity is missing. Re-import this wallpaper."
            )
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw LockScreenCompatibilityError.assetRejected(
                    "The persisted \(role) identity is invalid. Re-import this wallpaper."
                )
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func assetOwnershipMarker(for transactionID: UUID) -> Data {
        Data(transactionID.uuidString.lowercased().utf8)
    }

    private func assetVideoURL(for id: UUID) -> URL {
        paths.videosDirectory.appendingPathComponent(
            "\(id.uuidString.uppercased()).mov",
            isDirectory: false
        )
    }

    private func assetThumbnailURL(for id: UUID) -> URL {
        paths.thumbnailsDirectory.appendingPathComponent(
            "\(id.uuidString.uppercased()).png",
            isDirectory: false
        )
    }

    private func assetRecoveryURL(
        for id: UUID,
        role: String,
        transactionID: UUID
    ) -> URL {
        let directory = role == "video" ? paths.videosDirectory : paths.thumbnailsDirectory
        return directory.appendingPathComponent(
            ".wali-\(transactionID.uuidString.lowercased())-"
                + "\(id.uuidString.lowercased()).\(role)-recovery",
            isDirectory: false
        )
    }

    private func recoveryAction(
        at url: URL,
        destinationDigest: Data?,
        transition: LockScreenAssetFileTransition,
        ownershipMarker: Data,
        maximumBytes: UInt64
    ) throws -> LockScreenAssetRecoveryAction? {
        guard try LockScreenFileIO.nodeExists(url) else { return nil }
        let recoveryDigest = try LockScreenFileIO.sha256(of: url, maximumBytes: maximumBytes)
        let hasOwnershipMarker = try LockScreenFileIO.hasOwnershipMarker(
            at: url,
            expected: ownershipMarker
        )
        let isOwnedStage = destinationDigest == transition.expectedDigest
            && hasOwnershipMarker
        let isDisplacedExpected = recoveryDigest == transition.expectedDigest
            && destinationDigest == transition.targetDigest
        guard isOwnedStage || isDisplacedExpected else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction recovery sibling does not match its journaled asset transition."
            )
        }
        return .init(url: url, digest: recoveryDigest, maximumBytes: maximumBytes)
    }

    private func validatePreparedTargetProvenance(
        at url: URL,
        observedDigest: Data?,
        transition: LockScreenAssetFileTransition,
        ownershipMarker: Data
    ) throws {
        guard transition.expectedDigest != transition.targetDigest,
              let targetDigest = transition.targetDigest,
              observedDigest == targetDigest else {
            return
        }
        guard try LockScreenFileIO.hasOwnershipMarker(at: url, expected: ownershipMarker) else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A prepared Lock Screen target lacks its transaction ownership marker."
            )
        }
    }

    private func observedDigest(
        at url: URL,
        maximumBytes: UInt64,
        authorizedBy transition: LockScreenAssetFileTransition?
    ) throws -> Data? {
        guard try LockScreenFileIO.nodeExists(url) else {
            guard transition == nil
                    || transition?.expectedDigest == nil
                    || transition?.targetDigest == nil else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A digest-journaled Lock Screen asset file is missing."
                )
            }
            return nil
        }
        guard let transition else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "An unjournaled file already uses a requested Lock Screen asset path."
            )
        }
        let digest = try LockScreenFileIO.sha256(of: url, maximumBytes: maximumBytes)
        guard digest == transition.expectedDigest || digest == transition.targetDigest else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A digest-journaled Lock Screen asset changed outside WALI."
            )
        }
        return digest
    }

    private static func makePNG(from source: URL) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_920,
        ] as CFDictionary) else {
            throw LockScreenCompatibilityError.assetRejected("The poster image could not be decoded.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw LockScreenCompatibilityError.assetRejected("A PNG encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LockScreenCompatibilityError.assetRejected("The PNG thumbnail could not be finalized.")
        }
        return output as Data
    }

    private func loadAssetJournal() throws -> LockScreenAssetJournal {
        guard FileManager.default.fileExists(atPath: paths.assetJournalURL.path) else {
            return .init(phase: .committed, records: [])
        }
        try LockScreenFileIO.requireRegularFile(paths.assetJournalURL, maximumBytes: 1_024 * 1_024)
        do {
            let data = try Data(contentsOf: paths.assetJournalURL)
            let schema = try JSONDecoder().decode(
                LockScreenAssetJournalSchema.self,
                from: data
            )
            guard schema.schemaVersion == 2 else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "The WALI asset journal predates digest-backed ownership and will not be modified."
                )
            }
            let journal = try JSONDecoder().decode(
                LockScreenAssetJournal.self,
                from: data
            )
            guard journal.schemaVersion == 2,
                  journal.records.count <= Self.maximumAssetJournalRecords,
                  journal.records.allSatisfy(Self.validAssetJournalRecord),
                  Self.validAssetJournalPhase(journal),
                  Set(journal.records.map(\.id)).count == journal.records.count else {
                throw LockScreenCompatibilityError.unsupportedSchema("The WALI asset journal is incompatible.")
            }
            return .init(
                transactionID: journal.transactionID,
                phase: journal.phase,
                records: journal.records.sorted { $0.id.uuidString < $1.id.uuidString },
                refreshPending: journal.refreshPending
            )
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The WALI asset journal is invalid.")
        }
    }

    private func saveAssetJournal(_ journal: LockScreenAssetJournal) throws {
        guard journal.records.count <= Self.maximumAssetJournalRecords,
              journal.records.allSatisfy(Self.validAssetJournalRecord),
              Self.validAssetJournalPhase(journal),
              Set(journal.records.map(\.id)).count == journal.records.count else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The WALI asset journal exceeds its ownership bound."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        try LockScreenFileIO.atomicWrite(data, to: paths.assetJournalURL) { staged in
            let decoded = try JSONDecoder().decode(
                LockScreenAssetJournal.self,
                from: Data(contentsOf: staged)
            )
            guard decoded.schemaVersion == 2,
                  decoded.records.allSatisfy(Self.validAssetJournalRecord),
                  Self.validAssetJournalPhase(decoded) else {
                throw LockScreenCompatibilityError.unsupportedSchema("The staged WALI asset journal is incompatible.")
            }
        }
    }

    private static func validAssetJournalRecord(_ record: LockScreenAssetJournalRecord) -> Bool {
        func valid(_ transition: LockScreenAssetFileTransition) -> Bool {
            let digests = [transition.expectedDigest, transition.targetDigest].compactMap { $0 }
            return digests.allSatisfy { $0.count == 32 }
        }
        return valid(record.video)
            && valid(record.thumbnail)
            && [
                record.video.expectedDigest,
                record.video.targetDigest,
                record.thumbnail.expectedDigest,
                record.thumbnail.targetDigest,
            ].contains(where: { $0 != nil })
    }

    private static func validAssetJournalPhase(_ journal: LockScreenAssetJournal) -> Bool {
        guard journal.phase == .committed else { return true }
        return journal.records.allSatisfy { record in
            record.video.expectedDigest != nil
                && record.video.expectedDigest == record.video.targetDigest
                && record.thumbnail.expectedDigest != nil
                && record.thumbnail.expectedDigest == record.thumbnail.targetDigest
        }
    }

    /// The refresh callback suspends this actor. A later reconciliation may
    /// commit while that callback is in flight, so finalize only the exact
    /// transaction generation that requested this refresh.
    private func finalizeRefresh(
        for pendingJournal: LockScreenAssetJournal,
        removeJournals: Bool
    ) throws {
        guard try loadAssetJournal() == pendingJournal else { return }
        if removeJournals {
            try removeOwnershipJournals()
        } else {
            try saveAssetJournal(.init(
                transactionID: pendingJournal.transactionID,
                phase: pendingJournal.phase,
                records: pendingJournal.records,
                refreshPending: false
            ))
        }
    }

    private func removeOwnershipJournals() throws {
        try LockScreenFileIO.removeRegularFileIfPresent(
            paths.journalURL,
            maximumBytes: Self.maximumChoiceJournalBytes
        )
        try LockScreenFileIO.removeRegularFileIfPresent(
            paths.assetJournalURL,
            maximumBytes: Self.maximumAssetJournalBytes
        )
    }
}

private struct PreflightPlan: Sendable {
    let transactionID: UUID
    let eligible: [LockScreenWallpaperAssignment]
    let desiredIDs: Set<UUID>
    let manifestOwnedIDs: Set<UUID>
    let journalOwnedIDs: Set<UUID>
    let refreshPending: Bool
    let desiredAssets: [UUID: PreparedLockScreenAsset]
    let preparedRecords: [LockScreenAssetJournalRecord]
    let committedRecords: [LockScreenAssetJournalRecord]
    let recoveryActions: [LockScreenAssetRecoveryAction]
    let storeAssignments: [WallpaperStoreAssignment]
    let requiresManagedStoreMutation: Bool
    let requiresTransactionMutation: Bool
}

private struct LockScreenAssetRecoveryAction: Sendable {
    let url: URL
    let digest: Data
    let maximumBytes: UInt64
}

private struct PreparedLockScreenAsset: Sendable {
    let videoSourceURL: URL
    let videoDigest: Data
    let thumbnailData: Data
    let thumbnailDigest: Data
}

private struct LockScreenAssetJournal: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    let schemaVersion: Int
    let transactionID: UUID?
    let phase: Phase
    let records: [LockScreenAssetJournalRecord]
    let refreshPending: Bool

    init(
        transactionID: UUID? = nil,
        phase: Phase,
        records: [LockScreenAssetJournalRecord],
        refreshPending: Bool = false
    ) {
        schemaVersion = 2
        self.transactionID = transactionID
        self.phase = phase
        self.records = records
        self.refreshPending = refreshPending
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, transactionID, phase, records, refreshPending
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        transactionID = try values.decodeIfPresent(UUID.self, forKey: .transactionID)
        phase = try values.decode(Phase.self, forKey: .phase)
        records = try values.decode([LockScreenAssetJournalRecord].self, forKey: .records)
        refreshPending = try values.decodeIfPresent(Bool.self, forKey: .refreshPending) ?? false
    }
}

private struct LockScreenAssetJournalSchema: Decodable {
    let schemaVersion: Int
}

private struct LockScreenAssetJournalRecord: Codable, Sendable, Equatable {
    let id: UUID
    let video: LockScreenAssetFileTransition
    let thumbnail: LockScreenAssetFileTransition
}

private struct LockScreenAssetFileTransition: Codable, Sendable, Equatable {
    let expectedDigest: Data?
    let targetDigest: Data?
}
