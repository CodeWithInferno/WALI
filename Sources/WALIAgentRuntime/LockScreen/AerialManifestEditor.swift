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
            try LockScreenFileIO.atomicWrite(nextData, to: manifestURL) { staged in
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

    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        validate: (URL) throws -> Void
    ) throws {
        try requireDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
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

    static func atomicCopy(
        from source: URL,
        to destination: URL,
        maximumBytes: UInt64
    ) throws {
        try requireRegularFile(source, maximumBytes: maximumBytes)
        try requireDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
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
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
}
