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
            "Lock Screen continuity needs Full Disk Access for WALI Agent. Open System Settings > Privacy & Security > Full Disk Access, enable WALI Agent, then try again."
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
        if changed {
            try LockScreenFileIO.atomicCompareAndSwap(
                expected: originalData,
                replacement: nextData,
                at: manifestURL
            ) { staged in
                _ = try Self.decodeAndValidate(Data(contentsOf: staged))
            }
        }
        return AerialManifestEditResult(
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

enum LockScreenFileIO {
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
        let descriptor = Darwin.open(
            probe.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw transactionalWriteError(errno)
        }
        var probeExists = true
        defer {
            _ = Darwin.close(descriptor)
            if probeExists {
                _ = Darwin.unlink(probe.path)
            }
        }

        var byte: UInt8 = 0
        let written = withUnsafeBytes(of: &byte) { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == 1 else {
            throw transactionalWriteError(errno)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw transactionalWriteError(errno)
        }
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
        try data.write(to: staged, options: [.withoutOverwriting])
        try sync(staged)
        try validate(staged)
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
                try? FileManager.default.removeItem(at: staged)
            }
        }
        try replacement.write(to: staged, options: [.withoutOverwriting])
        try sync(staged)
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

    static func atomicCopy(
        from source: URL,
        to destination: URL,
        maximumBytes: UInt64
    ) throws {
        try requireRegularFile(source, maximumBytes: maximumBytes)
        try requireDirectory(destination.deletingLastPathComponent())
        if try nodeExists(destination) {
            try requireRegularFile(destination, maximumBytes: maximumBytes)
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".wali-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try requireRegularFile(staged, maximumBytes: maximumBytes)
        try sync(staged)
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func removeRegularFileIfPresent(_ url: URL, maximumBytes: UInt64) throws {
        guard try nodeExists(url) else { return }
        try requireRegularFile(url, maximumBytes: maximumBytes)
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func sync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
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
