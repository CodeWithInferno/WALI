import Foundation

public struct WallpaperStoreAssignment: Sendable, Hashable {
    public let displayUUID: UUID
    public let assetID: UUID

    public init(displayUUID: UUID, assetID: UUID) {
        self.displayUUID = displayUUID
        self.assetID = assetID
    }
}

public struct WallpaperStoreEditResult: Sendable, Hashable {
    public let changed: Bool
    public let patchedNodeCount: Int
}

/// Transactional, display-scoped editor for the verified current-user
/// WallpaperAgent Index.plist shape. Global and Space-default choices are
/// deliberately outside this adapter's authority.
public struct WallpaperStoreEditor: Sendable {
    public static let provider = "com.apple.wallpaper.choice.aerials"
    private static let maximumStoreBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumJournalBytes: UInt64 = 4 * 1_024 * 1_024
    private static let maximumNodes = 512

    public let indexURL: URL
    public let journalURL: URL

    public init(indexURL: URL, journalURL: URL) {
        self.indexURL = indexURL
        self.journalURL = journalURL
    }

    @discardableResult
    public func reconcile(
        assignments: [WallpaperStoreAssignment]
    ) throws -> WallpaperStoreEditResult {
        guard Set(assignments.map(\.displayUUID)).count == assignments.count else {
            throw LockScreenCompatibilityError.malformedStore("Duplicate display assignments were requested.")
        }
        let loaded = try loadStore()
        var root = loaded.root
        var journal = try loadJournal()
        let existingNodePaths = try Self.displayNodePaths(in: root)
        let allowedJournalPaths = Set(existingNodePaths.map(\.path))
        guard journal.records.allSatisfy({ allowedJournalPaths.contains($0.path) }) else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The rollback journal contains a node outside WALI’s display scope."
            )
        }
        let requested = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.displayUUID.uuidString.uppercased(), $0.assetID)
        })
        let topLevelDisplayIDs = Set(existingNodePaths.compactMap { entry in
            entry.path.hasPrefix("Displays/") ? entry.displayUUID : nil
        })
        guard Set(requested.keys).isSubset(of: topLevelDisplayIDs) else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "A connected display is missing from the current-user wallpaper store."
            )
        }
        let desiredPaths = Dictionary(uniqueKeysWithValues: existingNodePaths.compactMap { entry in
            requested[entry.displayUUID].map { (entry.path, $0) }
        })

        var changed = false
        var nextRecords: [WallpaperChoiceJournalRecord] = []
        for record in journal.records {
            guard desiredPaths[record.path] == nil else { continue }
            if Self.currentChoices(in: root, path: record.path).map({
                Self.pointsToAsset($0, assetID: record.waliAssetID)
            }) == true {
                root = try Self.restoring(record, in: root)
                changed = true
            }
        }

        let recordsByPath = Dictionary(
            journal.records.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (path, assetID) in desiredPaths.sorted(by: { $0.key < $1.key }) {
            let current = Self.currentChoices(in: root, path: path)
            if let existing = recordsByPath[path] {
                let isExistingWALIChoice = current.map {
                    Self.pointsToAsset($0, assetID: existing.waliAssetID)
                        || Self.pointsToAsset($0, assetID: assetID)
                } ?? false
                let isPreparedOriginal: Bool
                if journal.phase == .prepared {
                    isPreparedOriginal = try Self.matchesRecordedOriginal(current, record: existing)
                } else {
                    isPreparedOriginal = false
                }
                guard isExistingWALIChoice || isPreparedOriginal else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A display choice changed outside WALI; it was preserved."
                    )
                }
                var updated = existing
                updated.waliAssetID = assetID
                nextRecords.append(updated)
            } else {
                let originalData = try current.map(Self.encodePlistValue)
                nextRecords.append(.init(
                    path: path,
                    originalChoices: originalData,
                    waliAssetID: assetID
                ))
            }
            let replacement = try Self.wallpaperChoices(assetID: assetID)
            if !Self.propertyListsEqual(current, replacement) {
                root = try Self.settingChoices(replacement, at: path, in: root)
                changed = true
            }
        }

        guard nextRecords.count <= Self.maximumNodes else {
            throw LockScreenCompatibilityError.malformedStore("Too many wallpaper choice nodes.")
        }
        nextRecords.sort { $0.path < $1.path }
        journal = WallpaperChoiceJournal(phase: .prepared, records: nextRecords)
        try saveJournal(journal)

        if changed {
            let nextData = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: loaded.format,
                options: 0
            )
            _ = try Self.decodeAndValidateStore(nextData)
            try LockScreenFileIO.atomicWrite(nextData, to: indexURL) { staged in
                _ = try Self.decodeAndValidateStore(Data(contentsOf: staged))
            }
        }
        journal.phase = .committed
        try saveJournal(journal)
        return WallpaperStoreEditResult(changed: changed, patchedNodeCount: nextRecords.count)
    }

    public func validate() throws {
        _ = try loadStore()
        _ = try loadJournal()
    }

    private func loadStore() throws -> (root: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        try LockScreenFileIO.requireRegularFile(indexURL, maximumBytes: Self.maximumStoreBytes)
        let data = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
        return try Self.decodeAndValidateStore(data)
    }

    private static func decodeAndValidateStore(
        _ data: Data
    ) throws -> (root: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: &format
            )
        } catch {
            throw LockScreenCompatibilityError.malformedStore("Index.plist is not a valid property list.")
        }
        guard let root = object as? [String: Any],
              root["Displays"] is [String: Any],
              root["Spaces"] is [String: Any],
              root.keys.count <= maximumNodes else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "Expected the verified display-and-Space Index.plist layout."
            )
        }
        _ = try displayNodePaths(in: root)
        return (root, format)
    }

    private func loadJournal() throws -> WallpaperChoiceJournal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return WallpaperChoiceJournal(phase: .committed, records: [])
        }
        try LockScreenFileIO.requireRegularFile(
            journalURL,
            maximumBytes: Self.maximumJournalBytes
        )
        do {
            let journal = try JSONDecoder().decode(
                WallpaperChoiceJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.schemaVersion == 1,
                  journal.records.count <= Self.maximumNodes,
                  Set(journal.records.map(\.path)).count == journal.records.count else {
                throw LockScreenCompatibilityError.unsupportedSchema("The WALI rollback journal is incompatible.")
            }
            return journal
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The WALI rollback journal is invalid.")
        }
    }

    private func saveJournal(_ journal: WallpaperChoiceJournal) throws {
        try LockScreenFileIO.requireDirectory(journalURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw LockScreenCompatibilityError.malformedStore("The WALI rollback journal exceeds its safety limit.")
        }
        try LockScreenFileIO.atomicWrite(data, to: journalURL) { staged in
            let decoded = try JSONDecoder().decode(
                WallpaperChoiceJournal.self,
                from: Data(contentsOf: staged)
            )
            guard decoded.schemaVersion == 1 else {
                throw LockScreenCompatibilityError.unsupportedSchema("The staged rollback journal is incompatible.")
            }
        }
    }

    private struct DisplayNodePath: Hashable {
        let displayUUID: String
        let path: String
    }

    private static func displayNodePaths(in root: [String: Any]) throws -> [DisplayNodePath] {
        guard let displays = root["Displays"] as? [String: Any],
              let spaces = root["Spaces"] as? [String: Any],
              displays.count <= maximumNodes,
              spaces.count <= maximumNodes else {
            throw LockScreenCompatibilityError.unsupportedSchema("Display or Space maps are missing or unbounded.")
        }
        var result: [DisplayNodePath] = []
        for (rawID, value) in displays {
            guard let id = UUID(uuidString: rawID),
                  rawID == id.uuidString.uppercased(),
                  value is [String: Any] else {
                throw LockScreenCompatibilityError.unsupportedSchema("A display node is malformed.")
            }
            let displayID = id.uuidString.uppercased()
            result.append(.init(
                displayUUID: displayID,
                path: "Displays/\(displayID)/Linked/Content/Choices"
            ))
        }
        for (spaceID, value) in spaces {
            guard let parsedSpaceID = UUID(uuidString: spaceID),
                  spaceID == parsedSpaceID.uuidString.uppercased(),
                  let space = value as? [String: Any],
                  let spaceDisplays = space["Displays"] as? [String: Any],
                  spaceDisplays.count <= maximumNodes else {
                throw LockScreenCompatibilityError.unsupportedSchema("A Space node is malformed.")
            }
            for (rawID, displayValue) in spaceDisplays {
                guard let id = UUID(uuidString: rawID),
                      rawID == id.uuidString.uppercased(),
                      displayValue is [String: Any] else {
                    throw LockScreenCompatibilityError.unsupportedSchema("A Space display node is malformed.")
                }
                let displayID = id.uuidString.uppercased()
                result.append(.init(
                    displayUUID: displayID,
                    path: "Spaces/\(spaceID)/Displays/\(displayID)/Linked/Content/Choices"
                ))
            }
        }
        guard result.count <= maximumNodes, Set(result.map(\.path)).count == result.count else {
            throw LockScreenCompatibilityError.unsupportedSchema("Wallpaper choice nodes are duplicated or unbounded.")
        }
        for entry in result {
            let components = entry.path.split(separator: "/").map(String.init)
            let contentPath = Array(components.dropLast())
            guard value(at: contentPath, in: root) is [String: Any] else {
                throw LockScreenCompatibilityError.unsupportedSchema("A wallpaper content node is missing.")
            }
            if let choices = value(at: components, in: root), !(choices is [Any]) {
                throw LockScreenCompatibilityError.unsupportedSchema("A Choices node is not an array.")
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func wallpaperChoices(assetID: UUID) throws -> [Any] {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID.uuidString.uppercased()],
            format: .binary,
            options: 0
        )
        return [[
            "Configuration": configuration,
            "Files": [Any](),
            "Provider": provider,
        ]]
    }

    private static func pointsToAsset(_ choices: [Any], assetID: UUID) -> Bool {
        guard choices.count == 1,
              let choice = choices[0] as? [String: Any],
              choice["Provider"] as? String == provider,
              let configuration = choice["Configuration"] as? Data else {
            return false
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let decoded = try? PropertyListSerialization.propertyList(
            from: configuration,
            options: [],
            format: &format
        ) as? [String: Any],
              format == .binary,
              let rawID = decoded["assetID"] as? String,
              UUID(uuidString: rawID) == assetID else {
            return false
        }
        return true
    }

    private static func currentChoices(in root: [String: Any], path: String) -> [Any]? {
        value(at: path.split(separator: "/").map(String.init), in: root) as? [Any]
    }

    private static func restoring(
        _ record: WallpaperChoiceJournalRecord,
        in root: [String: Any]
    ) throws -> [String: Any] {
        let value: [Any]?
        if let data = record.originalChoices {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let decoded = try PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: &format
            ) as? [Any] else {
                throw LockScreenCompatibilityError.malformedStore("A rollback choice is invalid.")
            }
            value = decoded
        } else {
            value = nil
        }
        return try settingChoices(value, at: record.path, in: root)
    }

    private static func matchesRecordedOriginal(
        _ current: [Any]?,
        record: WallpaperChoiceJournalRecord
    ) throws -> Bool {
        guard let data = record.originalChoices else { return current == nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let original = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [Any] else {
            throw LockScreenCompatibilityError.malformedStore("A rollback choice is invalid.")
        }
        guard let current else { return false }
        return propertyListsEqual(current, original)
    }

    private static func encodePlistValue(_ value: [Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func propertyListsEqual(_ lhs: [Any]?, _ rhs: [Any]) -> Bool {
        guard let lhs else { return false }
        return NSArray(array: lhs).isEqual(to: rhs)
    }

    private static func value(at path: [String], in root: [String: Any]) -> Any? {
        var current: Any = root
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component] else { return nil }
            current = next
        }
        return current
    }

    private static func settingChoices(
        _ choices: [Any]?,
        at path: String,
        in root: [String: Any]
    ) throws -> [String: Any] {
        let components = path.split(separator: "/").map(String.init)
        guard components.last == "Choices" else {
            throw LockScreenCompatibilityError.unsafePath("A rollback node escaped Choices.")
        }
        return try setting(value: choices, at: components[...], in: root)
    }

    private static func setting(
        value: Any?,
        at path: ArraySlice<String>,
        in dictionary: [String: Any]
    ) throws -> [String: Any] {
        guard let key = path.first else { return dictionary }
        var copy = dictionary
        if path.count == 1 {
            copy[key] = value
            return copy
        }
        guard let child = dictionary[key] as? [String: Any] else {
            throw LockScreenCompatibilityError.unsupportedSchema("A wallpaper choice path is incomplete.")
        }
        copy[key] = try setting(value: value, at: path.dropFirst(), in: child)
        return copy
    }
}

private struct WallpaperChoiceJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    let schemaVersion: Int
    var phase: Phase
    var records: [WallpaperChoiceJournalRecord]

    init(phase: Phase, records: [WallpaperChoiceJournalRecord]) {
        schemaVersion = 1
        self.phase = phase
        self.records = records
    }
}

private struct WallpaperChoiceJournalRecord: Codable, Sendable {
    let path: String
    let originalChoices: Data?
    var waliAssetID: UUID
}
