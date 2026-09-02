import CryptoKit
import Darwin
import Foundation

public enum LockScreenCompatibilityError: LocalizedError, Sendable {
    case unsupportedSystem(String)
    case missingStore(String)
    case unsafePath(String)
    case malformedStore(String)
    case ownershipConflict(String)
    case unsupportedSchema(String)
    case assetRejected(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSystem(detail):
            "Lock Screen continuity is unavailable on this macOS build. \(detail)"
        case let .missingStore(detail):
            "The current user’s wallpaper store is not ready. \(detail)"
        case let .unsafePath(detail):
            "WALI refused an unsafe wallpaper-store path. \(detail)"
        case let .malformedStore(detail):
            "The current user’s wallpaper store has an unexpected structure. \(detail)"
        case let .ownershipConflict(detail):
            "WALI found a conflicting Lock Screen record and made no changes. \(detail)"
        case let .unsupportedSchema(detail):
            "This wallpaper-store format has not been verified. \(detail)"
        case let .assetRejected(detail):
            "The wallpaper could not be prepared for the Lock Screen. \(detail)"
        case .permissionDenied:
            "Lock Screen continuity needs Full Disk Access for WALI Lock Screen Helper. Open System Settings > Privacy & Security > Full Disk Access and enable the helper; WALI Agent does not need that permission."
        }
    }
}

public struct AerialAssetRegistration: Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let videoURL: URL
    public let thumbnailURL: URL

    public init(id: UUID, name: String, videoURL: URL, thumbnailURL: URL) {
        self.id = id
        self.name = name
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
    }
}

public struct AerialManifestEditResult: Sendable, Hashable {
    public let changed: Bool
    public let removedAssetIDs: Set<UUID>
}

/// Bounded editor for the verified macOS 26 Aerial manifest shape.
public struct AerialManifestEditor: Sendable {
    public static let manifestVersion = 1
    public static let categoryID = "57414C49-0000-4000-8000-000000000001"
    public static let subcategoryID = "57414C49-0000-4000-8000-000000000002"
    public static let shotPrefix = "CUSTOM_WALI_"
    public static let maximumOwnedAssets = 8

    private static let maximumManifestBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumTotalAssets = 20_000

    public let manifestURL: URL

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    @discardableResult
    public func reconcile(
        registrations: [AerialAssetRegistration]
    ) throws -> AerialManifestEditResult {
        let plan = try makePlan(registrations: registrations)
        if plan.changed {
            try LockScreenFileIO.atomicCompareAndSwap(
                expected: plan.originalData,
                replacement: plan.nextData,
                at: manifestURL
            ) { staged in
                _ = try Self.decodeAndValidate(Data(contentsOf: staged))
            }
        }
        return .init(changed: plan.changed, removedAssetIDs: plan.removedAssetIDs)
    }

    /// Computes the exact manifest mutation without publishing it. The
    /// coordinator uses this to quiesce WallpaperAgent only for a real write.
    public func preview(
        registrations: [AerialAssetRegistration]
    ) throws -> AerialManifestEditResult {
        let plan = try makePlan(registrations: registrations)
        return .init(changed: plan.changed, removedAssetIDs: plan.removedAssetIDs)
    }

    private func makePlan(
        registrations: [AerialAssetRegistration]
    ) throws -> ManifestPlan {
        guard registrations.count <= Self.maximumOwnedAssets,
              Set(registrations.map(\.id)).count == registrations.count else {
            throw LockScreenCompatibilityError.assetRejected("Too many or duplicate WALI assets.")
        }
        try LockScreenFileIO.requireRegularFile(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes
        )
        let originalData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        var root = try Self.decodeAndValidate(originalData)
        let normalizedOriginalData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        guard var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw LockScreenCompatibilityError.malformedStore("Missing categories or assets.")
        }

        try Self.validateOwnership(categories: categories, assets: assets)
        let desiredIDs = Set(registrations.map(\.id))
        for asset in assets where (asset["id"] as? String).flatMap(UUID.init(uuidString:)).map(desiredIDs.contains) == true {
            guard Self.ownedAssetID(asset) != nil else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A non-WALI asset already uses a requested wallpaper UUID."
                )
            }
        }
        let existingOwnedIDs = Set(assets.compactMap(Self.ownedAssetID))
        assets.removeAll { Self.ownedAssetID($0) != nil }
        assets.append(contentsOf: registrations.map(Self.assetRecord))
        guard assets.count <= Self.maximumTotalAssets else {
            throw LockScreenCompatibilityError.malformedStore("The asset list exceeds the safety limit.")
        }

        categories.removeAll { ($0["id"] as? String) == Self.categoryID }
        if let representative = registrations.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
            categories.append(Self.categoryRecord(representative: representative))
        }
        root["categories"] = categories
        root["assets"] = assets

        let nextData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        _ = try Self.decodeAndValidate(nextData)
        let changed = nextData != normalizedOriginalData
        return ManifestPlan(
            originalData: originalData,
            nextData: nextData,
            changed: changed,
            removedAssetIDs: existingOwnedIDs.subtracting(desiredIDs)
        )
    }

    public func validate() throws {
        try LockScreenFileIO.requireRegularFile(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes
        )
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        _ = try Self.decodeAndValidate(data)
    }

    /// Verifies reserved identifiers before the coordinator installs any
    /// destination bytes and returns the asset IDs already owned by WALI.
    public func preflight(desiredAssetIDs: Set<UUID>) throws -> Set<UUID> {
        try LockScreenFileIO.requireRegularFile(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes
        )
        let root = try Self.decodeAndValidate(
            Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        guard let categories = root["categories"] as? [[String: Any]],
              let assets = root["assets"] as? [[String: Any]] else {
            throw LockScreenCompatibilityError.malformedStore("Missing categories or assets.")
        }
        try Self.validateOwnership(categories: categories, assets: assets)
        for asset in assets where (asset["id"] as? String).flatMap(UUID.init(uuidString:)).map(desiredAssetIDs.contains) == true {
            guard Self.ownedAssetID(asset) != nil else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A non-WALI asset already uses a requested wallpaper UUID."
                )
            }
        }
        return Set(assets.compactMap(Self.ownedAssetID))
    }

    private static func decodeAndValidate(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers])
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The Aerial manifest is not valid JSON.")
        }
        guard let root = object as? [String: Any],
              let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == manifestVersion,
              let categories = root["categories"] as? [Any],
              let assets = root["assets"] as? [Any],
              categories.count <= maximumTotalAssets,
              assets.count <= maximumTotalAssets,
              categories.allSatisfy({ $0 is [String: Any] }),
              assets.allSatisfy({ $0 is [String: Any] }) else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "Expected Aerial manifest version \(manifestVersion)."
            )
        }
        return root
    }

    private static func validateOwnership(
        categories: [[String: Any]],
        assets: [[String: Any]]
    ) throws {
        let ownedCategories = categories.filter { ($0["id"] as? String) == categoryID }
        guard ownedCategories.count <= 1 else {
            throw LockScreenCompatibilityError.ownershipConflict("The reserved WALI category is duplicated.")
        }
        let reservedSubcategoryOwners = categories.filter { category in
            (category["subcategories"] as? [[String: Any]])?.contains {
                ($0["id"] as? String) == subcategoryID
            } == true
        }
        guard reservedSubcategoryOwners.count <= 1,
              reservedSubcategoryOwners.first?["id"] as? String == ownedCategories.first?["id"] as? String else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The reserved WALI subcategory is duplicated or owned by another category."
            )
        }
        if let category = ownedCategories.first {
            guard let subcategories = category["subcategories"] as? [[String: Any]],
                  subcategories.count == 1,
                  (subcategories[0]["id"] as? String) == subcategoryID else {
                throw LockScreenCompatibilityError.ownershipConflict("The reserved WALI category ID is already in use.")
            }
        }
        var ownedIDs: Set<UUID> = []
        var ownedShotIDs: Set<String> = []
        for asset in assets {
            let shotID = asset["shotID"] as? String
            let categories = asset["categories"] as? [String]
            let subcategories = asset["subcategories"] as? [String]
            let claimsWALIPrefix = shotID?.hasPrefix(shotPrefix) == true
            let claimsWALICategory = categories?.contains(categoryID) == true
                || subcategories?.contains(subcategoryID) == true
            guard claimsWALIPrefix == claimsWALICategory else {
                throw LockScreenCompatibilityError.ownershipConflict("A partial WALI asset record was found.")
            }
            if claimsWALIPrefix {
                guard let id = ownedAssetID(asset), let shotID else {
                    throw LockScreenCompatibilityError.ownershipConflict("A WALI asset record has an invalid identifier.")
                }
                guard ownedIDs.insert(id).inserted, ownedShotIDs.insert(shotID).inserted else {
                    throw LockScreenCompatibilityError.ownershipConflict("A WALI asset record is duplicated.")
                }
            }
        }
        guard ownedIDs.count <= maximumOwnedAssets else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The manifest contains more WALI assets than the supported ownership bound."
            )
        }
    }

    private static func ownedAssetID(_ asset: [String: Any]) -> UUID? {
        guard let shotID = asset["shotID"] as? String,
              shotID.hasPrefix(shotPrefix),
              let categories = asset["categories"] as? [String],
              categories.contains(categoryID),
              let subcategories = asset["subcategories"] as? [String],
              subcategories.contains(subcategoryID),
              let rawID = asset["id"] as? String,
              let id = UUID(uuidString: rawID),
              shotID == shotIdentifier(for: id) else {
            return nil
        }
        return id
    }

    private static func categoryRecord(
        representative: AerialAssetRegistration
    ) -> [String: Any] {
        let preview = representative.thumbnailURL.absoluteString
        let id = representative.id.uuidString.uppercased()
        let description = "Wallpapers managed by WALI"
        let subcategory: [String: Any] = [
            "localizedNameKey": "WALI",
            "localizedDescriptionKey": description,
            "preferredOrder": 0,
            "representativeAssetID": id,
            "id": subcategoryID,
            "previewImage": preview,
        ]
        return [
            "localizedDescriptionKey": description,
            "localizedNameKey": "WALI",
            "subcategories": [subcategory],
            "previewImage": preview,
            "id": categoryID,
            "representativeAssetID": id,
            "preferredOrder": 0,
        ]
    }

    private static func assetRecord(
        _ registration: AerialAssetRegistration
    ) -> [String: Any] {
        let shotID = shotIdentifier(for: registration.id)
        return [
            "showInTopLevel": true,
            "categories": [categoryID],
            "localizedNameKey": boundedName(registration.name),
            "url-4K-SDR-240FPS": registration.videoURL.absoluteString,
            "accessibilityLabel": boundedName(registration.name),
            "shotID": shotID,
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "previewImage": registration.thumbnailURL.absoluteString,
            "id": registration.id.uuidString.uppercased(),
            "includeInShuffle": true,
            "subcategories": [subcategoryID],
            "preferredOrder": 0,
        ]
    }

    private static func shotIdentifier(for id: UUID) -> String {
        shotPrefix + id.uuidString.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func boundedName(_ name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((value.isEmpty ? "WALI Wallpaper" : value).prefix(120))
    }
}

private struct ManifestPlan {
    let originalData: Data
    let nextData: Data
    let changed: Bool
    let removedAssetIDs: Set<UUID>
}

enum LockScreenFileIO {
    private static let ownershipXattrName = "com.wali.lock-screen-transaction"

    static func nodeExists(_ url: URL) throws -> Bool {
        guard url.isFileURL else {
            throw LockScreenCompatibilityError.unsafePath("Expected a local filesystem node.")
        }
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else {
            throw LockScreenCompatibilityError.unsafePath("Expected a local directory.")
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LockScreenCompatibilityError.unsafePath("A required directory is missing or symbolic.")
        }
    }

    static func requireRegularFile(_ url: URL, maximumBytes: UInt64) throws {
        guard url.isFileURL else {
            throw LockScreenCompatibilityError.unsafePath("Expected a local file.")
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              UInt64(fileSize) <= maximumBytes else {
            throw LockScreenCompatibilityError.unsafePath("A file is missing, symbolic, or exceeds its safety limit.")
        }
    }

    /// Exercises the same sibling-file capability used by the transactional
    /// writers. A successful probe is one byte and is removed before return.
    static func requireTransactionalWriteAccess(to directory: URL) throws {
        try requireDirectory(directory)
        let probe = directory.appendingPathComponent(
            ".wali-permission-probe-\(UUID().uuidString)",
            isDirectory: false
        )
        var probeExists = true
        defer {
            if probeExists {
                _ = Darwin.unlink(probe.path)
            }
        }
        try writeData(Data([0]), to: probe)
        guard Darwin.unlink(probe.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        probeExists = false
        try syncDirectory(directory)
    }

    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        validate: (URL) throws -> Void
    ) throws {
        try requireDirectory(destination.deletingLastPathComponent())
        if try nodeExists(destination) {
            try requireRegularFile(destination, maximumBytes: UInt64.max)
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".wali-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: staged) }
        try writeData(data, to: staged)
        try validate(staged)
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    /// Replaces a validated file only while its bytes still match the exact
    /// snapshot used to derive `replacement`. File coordination serializes
    /// cooperating writers; an atomic exchange then verifies the file actually
    /// displaced, catching a noncooperating rename in the compare/commit gap.
    static func atomicCompareAndSwap(
        expected: Data,
        replacement: Data,
        at destination: URL,
        validate: (URL) throws -> Void
    ) throws {
        try requireDirectory(destination.deletingLastPathComponent())
        try requireRegularFile(destination, maximumBytes: UInt64.max)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".wali-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var stagedIsSafeToRemove = true
        defer {
            if stagedIsSafeToRemove {
                if Darwin.unlink(staged.path) == 0 {
                    try? syncDirectory(staged.deletingLastPathComponent())
                }
            }
        }
        try writeData(replacement, to: staged)
        try validate(staged)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try requireRegularFile(coordinatedURL, maximumBytes: UInt64.max)
                let current = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
                guard current == expected else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "The wallpaper store changed while WALI was preparing its update; retry safely."
                    )
                }
                guard Darwin.renameatx_np(
                    AT_FDCWD,
                    staged.path,
                    AT_FDCWD,
                    coordinatedURL.path,
                    UInt32(RENAME_SWAP)
                ) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                stagedIsSafeToRemove = false
                let displaced = try Data(contentsOf: staged, options: [.mappedIfSafe])
                guard displaced == expected else {
                    // A noncooperating writer won after the first comparison.
                    // If our replacement is still current, exchange it back.
                    // A second noncooperating write during rollback is retained
                    // in the sibling file rather than deleted.
                    let installed = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
                    if installed == replacement,
                       Darwin.renameatx_np(
                           AT_FDCWD,
                           staged.path,
                           AT_FDCWD,
                           coordinatedURL.path,
                           UInt32(RENAME_SWAP)
                       ) == 0 {
                        let rolledOut = try Data(contentsOf: staged, options: [.mappedIfSafe])
                        stagedIsSafeToRemove = rolledOut == replacement
                    }
                    throw LockScreenCompatibilityError.ownershipConflict(
                        stagedIsSafeToRemove
                            ? "The wallpaper store changed during commit; its update was restored."
                            : "The wallpaper store changed during commit; conflicting bytes were preserved in a recovery sibling."
                    )
                }
                // The exchanged sibling is the exact baseline WALI already
                // validated, so it is safe to remove after leaving the scope.
                stagedIsSafeToRemove = true
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func sha256(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256(of url: URL, maximumBytes: UInt64) throws -> Data {
        guard url.isFileURL else {
            throw LockScreenCompatibilityError.unsafePath("Expected a local file.")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0,
              UInt64(information.st_size) <= maximumBytes else {
            throw LockScreenCompatibilityError.unsafePath(
                "A file is missing, symbolic, or exceeds its safety limit."
            )
        }
        var hasher = SHA256()
        var totalBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                var result: Int
                repeat {
                    result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                } while result < 0 && errno == EINTR
                return result
            }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            totalBytes += UInt64(count)
            guard totalBytes <= maximumBytes else {
                throw LockScreenCompatibilityError.unsafePath(
                    "A file changed or exceeds its safety limit."
                )
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return Data(hasher.finalize())
    }

    static func atomicInstallCopy(
        from source: URL,
        to destination: URL,
        expectedDigest: Data?,
        targetDigest: Data,
        maximumBytes: UInt64,
        ownershipMarker: Data,
        recoveryURL: URL
    ) throws -> Bool {
        try requireRegularFile(source, maximumBytes: maximumBytes)
        return try atomicInstall(
            to: destination,
            expectedDigest: expectedDigest,
            targetDigest: targetDigest,
            maximumBytes: maximumBytes,
            ownershipMarker: ownershipMarker,
            recoveryURL: recoveryURL,
            validate: { _ in }
        ) { staged in
            try streamCopy(
                from: source,
                to: staged,
                maximumBytes: maximumBytes,
                ownershipMarker: ownershipMarker
            )
        }
    }

    static func atomicInstallData(
        _ data: Data,
        to destination: URL,
        expectedDigest: Data?,
        targetDigest: Data,
        maximumBytes: UInt64,
        ownershipMarker: Data,
        recoveryURL: URL,
        ownershipDidBecomeDurable: ((URL) throws -> Void)? = nil,
        validate: (URL) throws -> Void
    ) throws -> Bool {
        guard UInt64(data.count) <= maximumBytes, sha256(of: data) == targetDigest else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "Prepared Lock Screen asset bytes do not match their digest."
            )
        }
        return try atomicInstall(
            to: destination,
            expectedDigest: expectedDigest,
            targetDigest: targetDigest,
            maximumBytes: maximumBytes,
            ownershipMarker: ownershipMarker,
            recoveryURL: recoveryURL,
            validate: validate
        ) { staged in
            try writeData(
                data,
                to: staged,
                ownershipMarker: ownershipMarker,
                ownershipDidBecomeDurable: ownershipDidBecomeDurable
            )
        }
    }

    static func atomicRemove(
        _ destination: URL,
        expectedDigest: Data?,
        maximumBytes: UInt64,
        recoveryURL: URL
    ) throws -> Bool {
        guard try nodeExists(destination) else {
            guard expectedDigest == nil else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A Lock Screen asset disappeared before its journaled removal."
                )
            }
            return false
        }
        guard let expectedDigest, expectedDigest.count == SHA256.byteCount else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "WALI has no digest authority to remove a Lock Screen asset file."
            )
        }
        try requireRegularFile(destination, maximumBytes: maximumBytes)
        try requireSiblingRecoveryURL(recoveryURL, for: destination)
        guard !(try nodeExists(recoveryURL)) else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction recovery sibling already exists."
            )
        }
        guard Darwin.renameatx_np(
            AT_FDCWD,
            destination.path,
            AT_FDCWD,
            recoveryURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw transactionalWriteError(errno)
        }
        let removedDigest: Data
        do {
            removedDigest = try sha256(of: recoveryURL, maximumBytes: maximumBytes)
        } catch {
            if Darwin.renameatx_np(
                AT_FDCWD,
                recoveryURL.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 {
                try syncDirectory(destination.deletingLastPathComponent())
                throw error
            }
            throw LockScreenCompatibilityError.ownershipConflict(
                "An unreadable Lock Screen asset was preserved in a recovery sibling."
            )
        }
        guard removedDigest == expectedDigest else {
            if Darwin.renameatx_np(
                AT_FDCWD,
                recoveryURL.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 {
                try syncDirectory(destination.deletingLastPathComponent())
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A changed Lock Screen asset was restored without deletion."
                )
            }
            throw LockScreenCompatibilityError.ownershipConflict(
                "A changed Lock Screen asset was preserved in a recovery sibling."
            )
        }
        guard Darwin.unlink(recoveryURL.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        try syncDirectory(destination.deletingLastPathComponent())
        return true
    }

    static func finalizeRecoveryFile(
        _ recoveryURL: URL,
        expectedDigest: Data,
        maximumBytes: UInt64
    ) throws {
        guard expectedDigest.count == SHA256.byteCount else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction recovery digest is invalid."
            )
        }
        try requireRegularFile(recoveryURL, maximumBytes: maximumBytes)
        guard try sha256(of: recoveryURL, maximumBytes: maximumBytes) == expectedDigest else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction recovery sibling changed outside WALI."
            )
        }
        guard Darwin.unlink(recoveryURL.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        try syncDirectory(recoveryURL.deletingLastPathComponent())
    }

    static func hasOwnershipMarker(at url: URL, expected: Data) throws -> Bool {
        try ownershipMarker(at: url) == expected
    }

    private static func atomicInstall(
        to destination: URL,
        expectedDigest: Data?,
        targetDigest: Data,
        maximumBytes: UInt64,
        ownershipMarker: Data,
        recoveryURL: URL,
        validate: (URL) throws -> Void,
        stage: (URL) throws -> Void
    ) throws -> Bool {
        guard targetDigest.count == SHA256.byteCount,
              expectedDigest == nil || expectedDigest?.count == SHA256.byteCount,
              !ownershipMarker.isEmpty,
              ownershipMarker.count <= 128 else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A Lock Screen asset digest is invalid."
            )
        }
        try requireDirectory(destination.deletingLastPathComponent())
        try requireSiblingRecoveryURL(recoveryURL, for: destination)
        let staged = recoveryURL
        guard !(try nodeExists(staged)) else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction recovery sibling already exists."
            )
        }
        var stagedIsSafeToRemove = false
        defer {
            if stagedIsSafeToRemove {
                try? FileManager.default.removeItem(at: staged)
            }
        }
        try stage(staged)
        stagedIsSafeToRemove = true
        try requireRegularFile(staged, maximumBytes: maximumBytes)
        try validate(staged)
        guard try sha256(of: staged, maximumBytes: maximumBytes) == targetDigest else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The staged Lock Screen asset changed before installation."
            )
        }

        if !(try nodeExists(destination)) {
            guard expectedDigest == nil else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A digest-journaled Lock Screen asset disappeared before replacement."
                )
            }
            guard Darwin.renameatx_np(
                AT_FDCWD,
                staged.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A file appeared at the Lock Screen asset path before installation."
                    )
                }
                throw transactionalWriteError(errno)
            }
            stagedIsSafeToRemove = false
            try syncDirectory(destination.deletingLastPathComponent())
            return true
        }

        try requireRegularFile(destination, maximumBytes: maximumBytes)
        let currentDigest = try sha256(of: destination, maximumBytes: maximumBytes)
        if currentDigest == targetDigest {
            guard expectedDigest == targetDigest else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A file appeared or changed at the Lock Screen asset path before installation."
                )
            }
            guard Darwin.unlink(staged.path) == 0 else {
                throw transactionalWriteError(errno)
            }
            stagedIsSafeToRemove = false
            try syncDirectory(destination.deletingLastPathComponent())
            return false
        }
        guard let expectedDigest, currentDigest == expectedDigest else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A Lock Screen asset changed before replacement."
            )
        }
        guard Darwin.renameatx_np(
            AT_FDCWD,
            staged.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw transactionalWriteError(errno)
        }
        stagedIsSafeToRemove = false
        let displacedDigest = try sha256(of: staged, maximumBytes: maximumBytes)
        guard displacedDigest == expectedDigest else {
            let installedDigest = try? sha256(of: destination, maximumBytes: maximumBytes)
            if installedDigest == targetDigest,
               Darwin.renameatx_np(
                   AT_FDCWD,
                   staged.path,
                   AT_FDCWD,
                   destination.path,
                   UInt32(RENAME_SWAP)
               ) == 0 {
                stagedIsSafeToRemove = (try? sha256(
                    of: staged,
                    maximumBytes: maximumBytes
                )) == targetDigest
            }
            try syncDirectory(destination.deletingLastPathComponent())
            throw LockScreenCompatibilityError.ownershipConflict(
                stagedIsSafeToRemove
                    ? "A changed Lock Screen asset was restored during replacement."
                    : "Conflicting Lock Screen asset bytes were preserved in a recovery sibling."
            )
        }
        guard Darwin.unlink(staged.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        stagedIsSafeToRemove = false
        try syncDirectory(destination.deletingLastPathComponent())
        return true
    }

    private static func requireSiblingRecoveryURL(_ recoveryURL: URL, for destination: URL) throws {
        guard recoveryURL.isFileURL,
              recoveryURL.standardizedFileURL != destination.standardizedFileURL,
              recoveryURL.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL,
              recoveryURL.lastPathComponent.hasPrefix(".wali-"),
              !recoveryURL.lastPathComponent.contains("/") else {
            throw LockScreenCompatibilityError.unsafePath(
                "A transaction recovery path escaped its asset directory."
            )
        }
    }

    private static func ownershipMarker(at url: URL) throws -> Data? {
        let length = url.path.withCString { path in
            ownershipXattrName.withCString { name in
                Darwin.getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        if length < 0 {
            if errno == ENOATTR { return nil }
            throw transactionalWriteError(errno)
        }
        guard length > 0, length <= 128 else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction ownership marker is invalid."
            )
        }
        var bytes = [UInt8](repeating: 0, count: length)
        let readCount = url.path.withCString { path in
            ownershipXattrName.withCString { name in
                bytes.withUnsafeMutableBytes { buffer in
                    Darwin.getxattr(
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
        guard readCount == length else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction ownership marker changed while it was read."
            )
        }
        return Data(bytes)
    }

    static func removeRegularFileIfPresent(_ url: URL, maximumBytes: UInt64) throws {
        guard try nodeExists(url) else { return }
        try requireRegularFile(url, maximumBytes: maximumBytes)
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func writeData(
        _ data: Data,
        to destination: URL,
        ownershipMarker: Data? = nil,
        ownershipDidBecomeDurable: ((URL) throws -> Void)? = nil
    ) throws {
        try withExclusiveWritableFile(
            at: destination,
            ownershipMarker: ownershipMarker,
            ownershipDidBecomeDurable: ownershipDidBecomeDurable
        ) { descriptor in
            try data.withUnsafeBytes { buffer in
                try writeAll(buffer, to: descriptor)
            }
        }
    }

    private static func streamCopy(
        from source: URL,
        to destination: URL,
        maximumBytes: UInt64,
        ownershipMarker: Data? = nil
    ) throws {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(sourceDescriptor) }

        try withExclusiveWritableFile(
            at: destination,
            ownershipMarker: ownershipMarker
        ) { destinationDescriptor in
            var totalBytes: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                let bytesRead: Int = buffer.withUnsafeMutableBytes { bytes in
                    var result: Int
                    repeat {
                        result = Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
                    } while result < 0 && errno == EINTR
                    return result
                }
                guard bytesRead >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if bytesRead == 0 { break }
                totalBytes += UInt64(bytesRead)
                guard totalBytes <= maximumBytes else {
                    throw LockScreenCompatibilityError.unsafePath(
                        "A source file changed or exceeds its safety limit."
                    )
                }
                try buffer.withUnsafeBytes { bytes in
                    try writeAll(
                        UnsafeRawBufferPointer(start: bytes.baseAddress, count: bytesRead),
                        to: destinationDescriptor
                    )
                }
            }
        }
    }

    private static func withExclusiveWritableFile(
        at destination: URL,
        ownershipMarker: Data? = nil,
        ownershipDidBecomeDurable: ((URL) throws -> Void)? = nil,
        _ operation: (Int32) throws -> Void
    ) throws {
        if let ownershipMarker {
            guard !ownershipMarker.isEmpty, ownershipMarker.count <= 128 else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A transaction ownership marker is invalid."
                )
            }
        }
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw transactionalWriteError(errno)
        }
        var needsClose = true
        defer {
            if needsClose { _ = Darwin.close(descriptor) }
        }
        if let ownershipMarker {
            do {
                let result = ownershipXattrName.withCString { name in
                    ownershipMarker.withUnsafeBytes { buffer in
                        Darwin.fsetxattr(
                            descriptor,
                            name,
                            buffer.baseAddress,
                            buffer.count,
                            0,
                            0
                        )
                    }
                }
                guard result == 0 else { throw transactionalWriteError(errno) }
                guard Darwin.fsync(descriptor) == 0 else {
                    throw transactionalWriteError(errno)
                }
                try syncDirectory(destination.deletingLastPathComponent())
            } catch {
                try removeExclusivelyCreatedFile(destination, descriptor: descriptor)
                throw error
            }
            try ownershipDidBecomeDurable?(destination)
        }
        try operation(descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw transactionalWriteError(errno)
        }
        let closeResult = Darwin.close(descriptor)
        needsClose = false
        guard closeResult == 0 else {
            throw transactionalWriteError(errno)
        }
    }

    private static func removeExclusivelyCreatedFile(
        _ url: URL,
        descriptor: Int32
    ) throws {
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw transactionalWriteError(errno)
        }
        var pathStatus = stat()
        guard Darwin.lstat(url.path, &pathStatus) == 0 else {
            if errno == ENOENT { return }
            throw transactionalWriteError(errno)
        }
        guard descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A transaction staging path changed during setup."
            )
        }
        guard Darwin.unlink(url.path) == 0 else {
            throw transactionalWriteError(errno)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            var written: Int
            repeat {
                written = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            } while written < 0 && errno == EINTR
            guard written > 0 else {
                throw transactionalWriteError(errno)
            }
            offset += written
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private static func transactionalWriteError(_ code: Int32) -> Error {
        if code == EACCES || code == EPERM {
            return LockScreenCompatibilityError.permissionDenied
        }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func actionableTransactionalWriteError(_ error: Error) -> Error {
        if case LockScreenCompatibilityError.permissionDenied = error {
            return error
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(cocoaError.code) {
            return LockScreenCompatibilityError.permissionDenied
        }
        if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error {
            return actionableTransactionalWriteError(underlying)
        }
        return error
    }
}
