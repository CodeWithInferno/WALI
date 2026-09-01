import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LockScreenCompatibilityEpoch {
    public static let supportedSystemBuilds: Set<String> = ["25F80"]
    public static let manifestEpoch = 1
    public static let manifestRevision = 0

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
    public let itemID: UUID
    public let name: String
    public let masterURL: URL
    public let posterURL: URL

    public init(
        displayID: String,
        itemID: UUID,
        name: String,
        masterURL: URL,
        posterURL: URL
    ) {
        self.displayID = displayID
        self.itemID = itemID
        self.name = name
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
    private let permissionPreflight: PermissionPreflight
    private let permissionClock = ContinuousClock()
    private var permissionPreflightValidUntil: ContinuousClock.Instant?

    public init(
        paths: LockScreenStorePaths,
        ownedLibraryRoot: URL,
        systemBuild: String = LockScreenCompatibilityEpoch.currentSystemBuild(),
        refreshHandler: @escaping RefreshHandler = {},
        permissionPreflight: PermissionPreflight? = nil
    ) {
        self.paths = paths
        self.ownedLibraryRoot = ownedLibraryRoot.standardizedFileURL
        self.systemBuild = systemBuild
        self.refreshHandler = refreshHandler
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
                await MainActor.run {
                    for application in NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.wallpaper.agent"
                    ) {
                        _ = application.terminate()
                    }
                }
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
        if !enabled, !hasOwnedJournal {
            return .init(changed: false, registeredAssets: 0, patchedNodes: 0)
        }
        let plan = try makePreflightPlan(enabled: enabled, assignments: assignments)
        let transactionID = UUID()
        let eligible = plan.eligible
        let grouped = Dictionary(grouping: eligible, by: \.itemID)

        if eligible.isEmpty {
            let cleanupIDs = plan.manifestOwnedIDs.union(plan.journalOwnedIDs)
            try saveAssetJournal(.init(
                transactionID: transactionID,
                phase: .prepared,
                records: cleanupIDs.sorted(by: { $0.uuidString < $1.uuidString }).map {
                    .init(id: $0, mayRemove: true)
                },
                refreshPending: true
            ))
            let storeResult = try WallpaperStoreEditor(
                indexURL: paths.indexURL,
                journalURL: paths.journalURL
            ).reconcile(assignments: [], knownOwnedAssetIDs: cleanupIDs)
            let manifestResult = try AerialManifestEditor(
                manifestURL: paths.manifestURL
            ).reconcile(registrations: [])
            try removeOwnedFiles(ids: manifestResult.removedAssetIDs.union(cleanupIDs))
            let shouldRefresh = storeResult.changed
                || manifestResult.changed
                || !cleanupIDs.isEmpty
                || plan.refreshPending
            let pendingJournal = LockScreenAssetJournal(
                transactionID: transactionID,
                phase: .committed,
                records: [],
                refreshPending: shouldRefresh
            )
            try saveAssetJournal(pendingJournal)
            if shouldRefresh { await refreshHandler() }
            try finalizeRefresh(for: pendingJournal, removeJournals: true)
            return .init(changed: shouldRefresh, registeredAssets: 0, patchedNodes: 0)
        }

        let manifestEditor = AerialManifestEditor(manifestURL: paths.manifestURL)
        let desiredIDs = plan.desiredIDs
        let preparedIDs = plan.manifestOwnedIDs.union(plan.journalOwnedIDs).union(desiredIDs)
        guard preparedIDs.count <= Self.maximumAssetJournalRecords else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The interrupted asset journal exceeds WALI’s recovery bound."
            )
        }
        try saveAssetJournal(.init(
            transactionID: transactionID,
            phase: .prepared,
            records: preparedIDs.sorted(by: { $0.uuidString < $1.uuidString }).map {
                .init(id: $0, mayRemove: true)
            },
            refreshPending: true
        ))

        var copiedFiles = false
        var registrations: [AerialAssetRegistration] = []
        for itemID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let assignment = grouped[itemID]?.first else { continue }
            let videoURL = paths.videosDirectory.appendingPathComponent(
                "\(itemID.uuidString.uppercased()).mov",
                isDirectory: false
            )
            let thumbnailURL = paths.thumbnailsDirectory.appendingPathComponent(
                "\(itemID.uuidString.uppercased()).png",
                isDirectory: false
            )
            copiedFiles = try installVideo(from: assignment.masterURL, to: videoURL) || copiedFiles
            guard let thumbnailData = plan.thumbnailDataByID[itemID] else {
                throw LockScreenCompatibilityError.assetRejected("A prepared thumbnail is missing.")
            }
            copiedFiles = try installThumbnail(thumbnailData, to: thumbnailURL) || copiedFiles
            registrations.append(.init(
                id: itemID,
                name: assignment.name,
                videoURL: videoURL,
                thumbnailURL: thumbnailURL
            ))
        }

        let manifestResult = try manifestEditor.reconcile(registrations: registrations)
        let storeResult = try WallpaperStoreEditor(
            indexURL: paths.indexURL,
            journalURL: paths.journalURL
        ).reconcile(
            assignments: plan.storeAssignments,
            knownOwnedAssetIDs: plan.manifestOwnedIDs.union(plan.journalOwnedIDs).union(desiredIDs)
        )
        try removeOwnedFiles(
            ids: manifestResult.removedAssetIDs.union(plan.journalOwnedIDs.subtracting(desiredIDs))
        )
        let shouldRefresh = copiedFiles
            || manifestResult.changed
            || storeResult.changed
            || plan.refreshPending
        let committedRecords = desiredIDs.sorted(by: { $0.uuidString < $1.uuidString }).map {
            LockScreenAssetJournalRecord(id: $0, mayRemove: true)
        }
        let pendingJournal = LockScreenAssetJournal(
            transactionID: transactionID,
            phase: .committed,
            records: committedRecords,
            refreshPending: shouldRefresh
        )
        try saveAssetJournal(pendingJournal)
        if shouldRefresh {
            await refreshHandler()
            try finalizeRefresh(for: pendingJournal, removeJournals: false)
        }
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
        for assignment in eligible {
            try validateOwnedSource(assignment.masterURL, maximumBytes: Self.maximumMasterBytes)
            try validateOwnedSource(assignment.posterURL, maximumBytes: Self.maximumPosterBytes)
        }
        var thumbnailDataByID: [UUID: Data] = [:]
        for (itemID, assignments) in grouped {
            guard let assignment = assignments.first else { continue }
            let png = try Self.makePNG(from: assignment.posterURL)
            guard png.count <= Self.maximumPNGBytes else {
                throw LockScreenCompatibilityError.assetRejected("The generated thumbnail is too large.")
            }
            thumbnailDataByID[itemID] = png
        }

        let desiredIDs = Set(grouped.keys)
        let manifestOwnedIDs = try AerialManifestEditor(
            manifestURL: paths.manifestURL
        ).preflight(desiredAssetIDs: desiredIDs)
        let assetJournal = try loadAssetJournal()
        let journalOwnedIDs = Set(assetJournal.records.filter(\.mayRemove).map(\.id))
        try preflightDestinations(
            desiredIDs: desiredIDs,
            ownedIDs: manifestOwnedIDs.union(journalOwnedIDs)
        )
        try preflightOwnedFiles(ids: manifestOwnedIDs.union(journalOwnedIDs).subtracting(desiredIDs))
        let storeAssignments = try eligible.map { assignment -> WallpaperStoreAssignment in
            guard let displayID = Self.displayUUID(from: assignment.displayID) else {
                throw LockScreenCompatibilityError.assetRejected("A display does not expose a stable UUID.")
            }
            return WallpaperStoreAssignment(displayUUID: displayID, assetID: assignment.itemID)
        }
        try WallpaperStoreEditor(
            indexURL: paths.indexURL,
            journalURL: paths.journalURL
        ).preflight(
            assignments: storeAssignments,
            knownOwnedAssetIDs: manifestOwnedIDs.union(journalOwnedIDs).union(desiredIDs)
        )
        return .init(
            eligible: eligible,
            desiredIDs: desiredIDs,
            manifestOwnedIDs: manifestOwnedIDs,
            journalOwnedIDs: journalOwnedIDs,
            refreshPending: assetJournal.refreshPending,
            thumbnailDataByID: thumbnailDataByID,
            storeAssignments: storeAssignments
        )
    }

    private var hasOwnedJournal: Bool {
        FileManager.default.fileExists(atPath: paths.journalURL.path)
            || FileManager.default.fileExists(atPath: paths.assetJournalURL.path)
    }

    private func eligibleAssignments(
        _ assignments: [LockScreenWallpaperAssignment]
    ) throws -> [LockScreenWallpaperAssignment] {
        var seenDisplays: Set<UUID> = []
        var result: [LockScreenWallpaperAssignment] = []
        for assignment in assignments {
            guard let displayID = Self.displayUUID(from: assignment.displayID) else { continue }
            guard seenDisplays.insert(displayID).inserted else {
                throw LockScreenCompatibilityError.assetRejected("A display assignment is duplicated.")
            }
            result.append(assignment)
        }
        return result
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

    private func installVideo(from source: URL, to destination: URL) throws -> Bool {
        if try LockScreenFileIO.nodeExists(destination) {
            try LockScreenFileIO.requireRegularFile(destination, maximumBytes: Self.maximumMasterBytes)
            if FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) {
                return false
            }
        }
        try LockScreenFileIO.atomicCopy(
            from: source,
            to: destination,
            maximumBytes: Self.maximumMasterBytes
        )
        return true
    }

    private func preflightDestinations(desiredIDs: Set<UUID>, ownedIDs: Set<UUID>) throws {
        for id in desiredIDs {
            let video = paths.videosDirectory.appendingPathComponent(
                "\(id.uuidString.uppercased()).mov",
                isDirectory: false
            )
            let thumbnail = paths.thumbnailsDirectory.appendingPathComponent(
                "\(id.uuidString.uppercased()).png",
                isDirectory: false
            )
            if try LockScreenFileIO.nodeExists(video) {
                guard ownedIDs.contains(id) else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A non-WALI video already uses the requested asset filename."
                    )
                }
                try LockScreenFileIO.requireRegularFile(video, maximumBytes: Self.maximumMasterBytes)
            }
            if try LockScreenFileIO.nodeExists(thumbnail) {
                guard ownedIDs.contains(id) else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A non-WALI thumbnail already uses the requested asset filename."
                    )
                }
                try LockScreenFileIO.requireRegularFile(thumbnail, maximumBytes: Self.maximumPNGBytes)
            }
        }
    }

    private func preflightOwnedFiles(ids: Set<UUID>) throws {
        for id in ids {
            let video = paths.videosDirectory.appendingPathComponent(
                "\(id.uuidString.uppercased()).mov",
                isDirectory: false
            )
            let thumbnail = paths.thumbnailsDirectory.appendingPathComponent(
                "\(id.uuidString.uppercased()).png",
                isDirectory: false
            )
            if try LockScreenFileIO.nodeExists(video) {
                try LockScreenFileIO.requireRegularFile(video, maximumBytes: Self.maximumMasterBytes)
            }
            if try LockScreenFileIO.nodeExists(thumbnail) {
                try LockScreenFileIO.requireRegularFile(thumbnail, maximumBytes: Self.maximumPNGBytes)
            }
        }
    }

    private func installThumbnail(_ png: Data, to destination: URL) throws -> Bool {
        if try LockScreenFileIO.nodeExists(destination) {
            try LockScreenFileIO.requireRegularFile(destination, maximumBytes: Self.maximumPNGBytes)
            if try Data(contentsOf: destination, options: [.mappedIfSafe]) == png { return false }
        }
        try LockScreenFileIO.atomicWrite(png, to: destination) { staged in
            guard CGImageSourceCreateWithURL(staged as CFURL, nil) != nil else {
                throw LockScreenCompatibilityError.assetRejected("The staged PNG could not be decoded.")
            }
        }
        return true
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

    private func removeOwnedFiles(ids: Set<UUID>) throws {
        for id in ids {
            try LockScreenFileIO.removeRegularFileIfPresent(
                paths.videosDirectory.appendingPathComponent(
                    "\(id.uuidString.uppercased()).mov",
                    isDirectory: false
                ),
                maximumBytes: Self.maximumMasterBytes
            )
            try LockScreenFileIO.removeRegularFileIfPresent(
                paths.thumbnailsDirectory.appendingPathComponent(
                    "\(id.uuidString.uppercased()).png",
                    isDirectory: false
                ),
                maximumBytes: Self.maximumPNGBytes
            )
        }
    }

    private func loadAssetJournal() throws -> LockScreenAssetJournal {
        guard FileManager.default.fileExists(atPath: paths.assetJournalURL.path) else {
            return .init(phase: .committed, records: [])
        }
        try LockScreenFileIO.requireRegularFile(paths.assetJournalURL, maximumBytes: 1_024 * 1_024)
        do {
            let journal = try JSONDecoder().decode(
                LockScreenAssetJournal.self,
                from: Data(contentsOf: paths.assetJournalURL)
            )
            guard journal.schemaVersion == 1,
                  journal.records.count <= Self.maximumAssetJournalRecords,
                  journal.records.allSatisfy(\.mayRemove),
                  Set(journal.records.map(\.id)).count == journal.records.count else {
                throw LockScreenCompatibilityError.unsupportedSchema("The WALI asset journal is incompatible.")
            }
            return journal
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The WALI asset journal is invalid.")
        }
    }

    private func saveAssetJournal(_ journal: LockScreenAssetJournal) throws {
        guard journal.records.count <= Self.maximumAssetJournalRecords,
              journal.records.allSatisfy(\.mayRemove),
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
            guard decoded.schemaVersion == 1 else {
                throw LockScreenCompatibilityError.unsupportedSchema("The staged WALI asset journal is incompatible.")
            }
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
    let eligible: [LockScreenWallpaperAssignment]
    let desiredIDs: Set<UUID>
    let manifestOwnedIDs: Set<UUID>
    let journalOwnedIDs: Set<UUID>
    let refreshPending: Bool
    let thumbnailDataByID: [UUID: Data]
    let storeAssignments: [WallpaperStoreAssignment]
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
        schemaVersion = 1
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

private struct LockScreenAssetJournalRecord: Codable, Sendable, Equatable {
    let id: UUID
    let mayRemove: Bool
}
