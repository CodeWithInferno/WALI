import Darwin
import Foundation
import WALILockScreenWire

final class FixedWallpaperStore: LockScreenStoreOperating, @unchecked Sendable {
    struct Roots: Sendable {
        let manifestURL: URL
        let videosDirectory: URL
        let thumbnailsDirectory: URL
        let indexURL: URL
        let journalURL: URL
        let assetStateURL: URL
        let objectRoot: URL
        let preparedThumbnailRoot: URL

        var allURLs: [URL] {
            [manifestURL, videosDirectory, thumbnailsDirectory, indexURL, journalURL,
             assetStateURL, objectRoot, preparedThumbnailRoot]
        }

        static func live(agentBundleIdentifier: String) throws -> Self {
            guard Self.isBundleIdentifier(agentBundleIdentifier) else {
                throw LockScreenHelperError.unavailable
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let wallpaper = support.appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            let aerials = wallpaper.appendingPathComponent("aerials", isDirectory: true)
            let library = support
                .appendingPathComponent(agentBundleIdentifier, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
            let metadata = library.appendingPathComponent("Metadata", isDirectory: true)
            return .init(
                manifestURL: aerials.appendingPathComponent("manifest/entries.json"),
                videosDirectory: aerials.appendingPathComponent("videos", isDirectory: true),
                thumbnailsDirectory: aerials.appendingPathComponent("thumbnails", isDirectory: true),
                indexURL: wallpaper.appendingPathComponent("Store/Index.plist"),
                journalURL: metadata.appendingPathComponent("lock-screen-choice-journal.json"),
                assetStateURL: metadata.appendingPathComponent("lock-screen-helper-state.json"),
                objectRoot: library
                    .appendingPathComponent("Objects", isDirectory: true)
                    .appendingPathComponent("sha256", isDirectory: true),
                preparedThumbnailRoot: metadata
                    .appendingPathComponent("LockScreenPrepared", isDirectory: true)
            )
        }

        static func testing(under root: URL) -> Self {
            let apple = root.appendingPathComponent("apple", isDirectory: true)
            let metadata = root.appendingPathComponent("metadata", isDirectory: true)
            return .init(
                manifestURL: apple.appendingPathComponent("manifest/entries.json"),
                videosDirectory: apple.appendingPathComponent("videos", isDirectory: true),
                thumbnailsDirectory: apple.appendingPathComponent("thumbnails", isDirectory: true),
                indexURL: apple.appendingPathComponent("Store/Index.plist"),
                journalURL: metadata.appendingPathComponent("choice.json"),
                assetStateURL: metadata.appendingPathComponent("helper-state.json"),
                objectRoot: root.appendingPathComponent("objects/sha256", isDirectory: true),
                preparedThumbnailRoot: metadata.appendingPathComponent("prepared", isDirectory: true)
            )
        }

        private static func isBundleIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
            }
        }
    }

    private static let supportedBuilds: Set<String> = ["25F80", "25G83"]
    private static let maximumMasterBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    private static let maximumThumbnailBytes: UInt64 = 128 * 1_024 * 1_024
    private static let maximumStateBytes: UInt64 = 1_024 * 1_024

    private let roots: Roots
    private let systemBuild: String

    static func live() throws -> FixedWallpaperStore {
        let identifier = Bundle.main.object(
            forInfoDictionaryKey: "WALIExpectedAgentBundleIdentifier"
        ) as? String ?? "io.github.codewithinferno.wali.WALIAgent"
        return try .init(roots: .live(agentBundleIdentifier: identifier), systemBuild: systemBuild())
    }

    init(testingRoots: Roots, systemBuild: String) {
        roots = testingRoots
        self.systemBuild = systemBuild
    }

    private init(roots: Roots, systemBuild: String) {
        self.roots = roots
        self.systemBuild = systemBuild
    }

    func masterSourceURL(forSHA256 digest: String) throws -> URL {
        try requireDigest(digest)
        return roots.objectRoot
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).mov", isDirectory: false)
    }

    func thumbnailSourceURL(forSHA256 digest: String) throws -> URL {
        try requireDigest(digest)
        return roots.preparedThumbnailRoot
            .appendingPathComponent("\(digest).png", isDirectory: false)
    }

    func status() throws -> LockScreenHelperStatus {
        let state = try loadState()
        let permission: LockScreenHelperPermission
        if !Self.supportedBuilds.contains(systemBuild) {
            permission = .unsupportedBuild
        } else {
            do {
                try validateStore()
                permission = .available
            } catch {
                permission = Self.isPermissionError(error) ? .permissionRequired : .unavailable
            }
        }
        return makeStatus(state: state, permission: permission)
    }

    func activate(
        _ release: LockScreenVerifiedRelease,
        expectedRevision: UInt64
    ) throws -> (changed: Bool, status: LockScreenHelperStatus) {
        try requireSupportedStore()
        var state = try loadState()
        guard state.revision == expectedRevision else { throw LockScreenHelperError.staleRevision }
        if state.active == .init(release), state.pending == nil {
            return (false, makeStatus(state: state, permission: .available))
        }
        guard state.pending == nil else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "An interrupted helper transaction must be restored before activation."
            )
        }

        let target = ActiveRelease(release)
        let masterSource = try masterSourceURL(forSHA256: target.masterSHA256)
        let thumbnailSource = try thumbnailSourceURL(forSHA256: target.thumbnailSHA256)
        let masterDigest = try digestData(target.masterSHA256)
        let thumbnailDigest = try digestData(target.thumbnailSHA256)
        guard try LockScreenFileIO.sha256(
            of: masterSource,
            maximumBytes: Self.maximumMasterBytes
        ) == masterDigest,
        try LockScreenFileIO.sha256(
            of: thumbnailSource,
            maximumBytes: Self.maximumThumbnailBytes
        ) == thumbnailDigest else {
            throw LockScreenCompatibilityError.assetRejected(
                "A verified WALI-owned source changed before helper activation."
            )
        }

        state.pending = .init(previous: state.active, target: target)
        try saveState(state)
        try install(target, masterSource: masterSource, thumbnailSource: thumbnailSource)
        if let previous = state.pending?.previous, previous.assetID != target.assetID {
            try removeAssets(previous)
        }
        state.active = target
        state.pending = nil
        state.revision += 1
        try saveState(state)
        return (true, makeStatus(state: state, permission: .available))
    }

    func deactivate(
        expectedRevision: UInt64
    ) throws -> (changed: Bool, status: LockScreenHelperStatus) {
        try restore(expectedRevision: expectedRevision)
    }

    func restore(
        expectedRevision: UInt64
    ) throws -> (changed: Bool, status: LockScreenHelperStatus) {
        try requireSupportedStore()
        var state = try loadState()
        guard state.revision == expectedRevision else { throw LockScreenHelperError.staleRevision }
        let records = [state.active, state.pending?.target].compactMap { $0 }
        guard !records.isEmpty else {
            return (false, makeStatus(state: state, permission: .available))
        }
        let previous = state.pending?.previous
        if let previous {
            let master = try masterSourceURL(forSHA256: previous.masterSHA256)
            let thumbnail = try thumbnailSourceURL(forSHA256: previous.thumbnailSHA256)
            try install(previous, masterSource: master, thumbnailSource: thumbnail)
        } else {
            _ = try WallpaperStoreEditor(
                indexURL: roots.indexURL,
                journalURL: roots.journalURL
            ).reconcile(assignments: [], knownOwnedAssetIDs: Set(records.map(\.assetID)))
            _ = try AerialManifestEditor(manifestURL: roots.manifestURL).reconcile(registrations: [])
        }
        for record in records where record.assetID != previous?.assetID {
            try removeAssets(record)
        }
        state.active = previous
        state.pending = nil
        state.revision += 1
        try saveState(state)
        return (true, makeStatus(state: state, permission: .available))
    }

    private func install(
        _ release: ActiveRelease,
        masterSource: URL,
        thumbnailSource: URL
    ) throws {
        let marker = Data("wali-helper:\(release.releaseID.uuidString.lowercased())".utf8)
        let masterDigest = try digestData(release.masterSHA256)
        let thumbnailDigest = try digestData(release.thumbnailSHA256)
        let video = roots.videosDirectory.appendingPathComponent("\(release.assetID.uuidString).mov")
        let thumbnail = roots.thumbnailsDirectory.appendingPathComponent("\(release.assetID.uuidString).png")
        let current = try loadState().active
        let existingMaster = current?.assetID == release.assetID
            ? try digestData(current?.masterSHA256 ?? "") : nil
        let existingThumbnail = current?.assetID == release.assetID
            ? try digestData(current?.thumbnailSHA256 ?? "") : nil
        _ = try LockScreenFileIO.atomicInstallCopy(
            from: masterSource,
            to: video,
            expectedDigest: existingMaster,
            targetDigest: masterDigest,
            maximumBytes: Self.maximumMasterBytes,
            ownershipMarker: marker,
            recoveryURL: video.appendingPathExtension("wali-recovery")
        )
        _ = try LockScreenFileIO.atomicInstallCopy(
            from: thumbnailSource,
            to: thumbnail,
            expectedDigest: existingThumbnail,
            targetDigest: thumbnailDigest,
            maximumBytes: Self.maximumThumbnailBytes,
            ownershipMarker: marker,
            recoveryURL: thumbnail.appendingPathExtension("wali-recovery")
        )
        _ = try AerialManifestEditor(manifestURL: roots.manifestURL).reconcile(registrations: [
            .init(id: release.assetID, name: release.title, videoURL: video, thumbnailURL: thumbnail),
        ])
        _ = try WallpaperStoreEditor(
            indexURL: roots.indexURL,
            journalURL: roots.journalURL
        ).reconcile(
            assignments: [.init(displayUUID: release.assetID, assetID: release.assetID)],
            knownOwnedAssetIDs: [release.assetID]
        )
    }

    private func removeAssets(_ release: ActiveRelease) throws {
        let video = roots.videosDirectory.appendingPathComponent("\(release.assetID.uuidString).mov")
        let thumbnail = roots.thumbnailsDirectory.appendingPathComponent("\(release.assetID.uuidString).png")
        if try LockScreenFileIO.nodeExists(video) {
            _ = try LockScreenFileIO.atomicRemove(
                video,
                expectedDigest: try digestData(release.masterSHA256),
                maximumBytes: Self.maximumMasterBytes,
                recoveryURL: video.appendingPathExtension("wali-remove")
            )
        }
        if try LockScreenFileIO.nodeExists(thumbnail) {
            _ = try LockScreenFileIO.atomicRemove(
                thumbnail,
                expectedDigest: try digestData(release.thumbnailSHA256),
                maximumBytes: Self.maximumThumbnailBytes,
                recoveryURL: thumbnail.appendingPathExtension("wali-remove")
            )
        }
    }

    private func requireSupportedStore() throws {
        guard Self.supportedBuilds.contains(systemBuild) else {
            throw LockScreenCompatibilityError.unsupportedSystem(
                "Verified builds: \(Self.supportedBuilds.sorted().joined(separator: ", ")); current build: \(systemBuild)."
            )
        }
        try validateStore()
    }

    private func validateStore() throws {
        try LockScreenFileIO.requireDirectory(roots.videosDirectory)
        try LockScreenFileIO.requireDirectory(roots.thumbnailsDirectory)
        try LockScreenFileIO.requireDirectory(roots.assetStateURL.deletingLastPathComponent())
        try LockScreenFileIO.requireDirectory(roots.objectRoot)
        try LockScreenFileIO.requireDirectory(roots.preparedThumbnailRoot)
        try AerialManifestEditor(manifestURL: roots.manifestURL).validate()
        try WallpaperStoreEditor(indexURL: roots.indexURL, journalURL: roots.journalURL).validate()
    }

    private func loadState() throws -> HelperState {
        guard try LockScreenFileIO.nodeExists(roots.assetStateURL) else { return .empty }
        try LockScreenFileIO.requireRegularFile(
            roots.assetStateURL,
            maximumBytes: Self.maximumStateBytes
        )
        do {
            let state = try JSONDecoder().decode(
                HelperState.self,
                from: Data(contentsOf: roots.assetStateURL)
            )
            guard state.schemaVersion == 1 else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "The helper journal schema is incompatible."
                )
            }
            return state
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The helper journal is invalid.")
        }
    }

    private func saveState(_ state: HelperState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumStateBytes else {
            throw LockScreenCompatibilityError.malformedStore("The helper journal is too large.")
        }
        try LockScreenFileIO.atomicWrite(data, to: roots.assetStateURL) { staged in
            _ = try JSONDecoder().decode(HelperState.self, from: Data(contentsOf: staged))
        }
    }

    private func makeStatus(
        state: HelperState,
        permission: LockScreenHelperPermission
    ) -> LockScreenHelperStatus {
        .init(
            revision: state.revision,
            permission: permission,
            activeReleaseID: state.active?.releaseID
        )
    }

    private func requireDigest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw LockScreenHelperError.invalidPayload }
    }

    private func digestData(_ value: String) throws -> Data {
        try requireDigest(value)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw LockScreenHelperError.invalidPayload
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func systemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if case LockScreenCompatibilityError.permissionDenied = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && [EACCES, EPERM].contains(Int32(nsError.code))
    }
}

private struct HelperState: Codable, Sendable {
    let schemaVersion: UInt16
    var revision: UInt64
    var active: ActiveRelease?
    var pending: PendingMutation?

    static let empty = HelperState(schemaVersion: 1, revision: 0, active: nil, pending: nil)
}

private struct PendingMutation: Codable, Sendable {
    let previous: ActiveRelease?
    let target: ActiveRelease
}

private struct ActiveRelease: Codable, Sendable, Equatable {
    let releaseID: UUID
    let assetID: UUID
    let title: String
    let masterSHA256: String
    let thumbnailSHA256: String

    init(_ release: LockScreenVerifiedRelease) {
        releaseID = release.releaseID
        assetID = release.assetID
        title = release.title
        masterSHA256 = release.masterSHA256
        thumbnailSHA256 = release.thumbnailSHA256
    }
}
