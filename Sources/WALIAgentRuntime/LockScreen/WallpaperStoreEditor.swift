import CryptoKit
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
    private static let maximumManagedIDsPerNode = 8

    public let indexURL: URL
    public let journalURL: URL

    public init(indexURL: URL, journalURL: URL) {
        self.indexURL = indexURL
        self.journalURL = journalURL
    }

    /// Runs complete schema, scope, ownership and rollback validation without
    /// writing either the Apple store or WALI's journal.
    public func preflight(
        assignments: [WallpaperStoreAssignment],
        knownOwnedAssetIDs: Set<UUID> = []
    ) throws {
        _ = try makePlan(
            assignments: assignments,
            knownOwnedAssetIDs: knownOwnedAssetIDs
        )
    }

    @discardableResult
    public func reconcile(
        assignments: [WallpaperStoreAssignment],
        knownOwnedAssetIDs: Set<UUID> = []
    ) throws -> WallpaperStoreEditResult {
        let plan = try makePlan(
            assignments: assignments,
            knownOwnedAssetIDs: knownOwnedAssetIDs
        )
        if let preparedJournal = plan.preparedJournal,
           let nextData = plan.nextData {
            try saveJournal(preparedJournal)
            try LockScreenFileIO.atomicCompareAndSwap(
                expected: plan.loaded.data,
                replacement: nextData,
                at: indexURL
            ) { staged in
                _ = try Self.decodeAndValidateStore(Data(contentsOf: staged))
            }
        }
        try saveJournal(plan.committedJournal)
        return WallpaperStoreEditResult(
            changed: plan.nextData != nil || plan.recoveredCommittedChange,
            patchedNodeCount: plan.committedJournal.records.count
        )
    }

    public func validate() throws {
        _ = try loadStore()
        _ = try loadJournal()
    }

    private func makePlan(
        assignments: [WallpaperStoreAssignment],
        knownOwnedAssetIDs: Set<UUID>
    ) throws -> ReconciliationPlan {
        guard Set(assignments.map(\.displayUUID)).count == assignments.count else {
            throw LockScreenCompatibilityError.malformedStore("Duplicate display assignments were requested.")
        }
        let loaded = try loadStore()
        let journal = try loadJournal()
        let existingNodePaths = try Self.displayNodePaths(in: loaded.root)
        let existingPathSet = Set(existingNodePaths.map(\.path))
        let requested = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.displayUUID.uuidString.uppercased(), $0.assetID)
        })
        let topLevelDisplayIDs = Set(existingNodePaths.compactMap { entry in
            entry.path.hasPrefix("Displays/") ? entry.displayUUID : nil
        })
        let missingTopLevelPaths = Set(Set(requested.keys).subtracting(topLevelDisplayIDs).map {
            "Displays/\($0)/Linked/Content/Choices"
        })
        let desiredEntries = existingNodePaths.compactMap { entry in
            requested[entry.displayUUID].map { (entry.path, $0) }
        } + missingTopLevelPaths.compactMap { path in
            Self.displayUUID(inChoicePath: path).flatMap { requested[$0].map { (path, $0) } }
        }
        guard desiredEntries.count <= Self.maximumNodes else {
            throw LockScreenCompatibilityError.malformedStore("Too many wallpaper choice nodes.")
        }
        let desiredPaths = Dictionary(uniqueKeysWithValues: desiredEntries)
        let recordsByPath = Dictionary(uniqueKeysWithValues: journal.records.map { ($0.path, $0) })
        let loadedDigest = Self.digest(loaded.data)
        let recoveredCommittedChange: Bool
        if journal.phase == .prepared {
            let targetIsReflected = try Self.preparedTargetIsReflected(
                    journal,
                    in: loaded.root,
                    existingPaths: existingPathSet
                )
            recoveredCommittedChange = journal.targetIndexDigest == loadedDigest
                || targetIsReflected
        } else {
            recoveredCommittedChange = false
        }

        var root = loaded.root
        for record in journal.records where desiredPaths[record.path] == nil {
            guard existingPathSet.contains(record.path) else { continue }
            let current = Self.currentChoices(in: root, path: record.path)
            if record.createdDisplayNode {
                if let currentID = Self.aerialAssetID(in: current) {
                    if Set(record.managedAssetIDs).contains(currentID) {
                        guard try Self.isExactSynthesizedDisplayNode(
                            in: root,
                            choicePath: record.path,
                            assetID: currentID
                        ) else {
                            throw LockScreenCompatibilityError.ownershipConflict(
                                "A WALI-created display override changed outside WALI; it was preserved."
                            )
                        }
                        root = try Self.removingSynthesizedDisplayNode(
                            atChoicePath: record.path,
                            in: root
                        )
                    } else if knownOwnedAssetIDs.contains(currentID) {
                        throw LockScreenCompatibilityError.ownershipConflict(
                            "A WALI-created display override points to another owned asset; it was preserved."
                        )
                    }
                }
                // A removed node or one with an external choice is no longer
                // WALI-owned. Preserve it and retire the stale record.
                continue
            }
            if Self.pointsToAnyAsset(current, assetIDs: Set(record.managedAssetIDs)) {
                root = try Self.restoring(record, in: root)
            }
            // Preserve externally changed nodes while retiring their stale
            // record. Removed displays and Spaces are also safely retired.
        }

        var committedRecords: [WallpaperChoiceJournalRecord] = []
        for (path, assetID) in desiredPaths.sorted(by: { $0.key < $1.key }) {
            let current = Self.currentChoices(in: root, path: path)
            let originalChoices: Data?
            let createdDisplayNode: Bool
            if let existing = recordsByPath[path] {
                let isManaged = Self.pointsToAnyAsset(
                    current,
                    assetIDs: Set(existing.managedAssetIDs).union([assetID])
                )
                let isPreparedOriginal = if journal.phase == .prepared,
                                            journal.expectedIndexDigest == loadedDigest {
                    try Self.matchesRecordedOriginal(current, record: existing)
                } else {
                    false
                }
                guard isManaged || isPreparedOriginal else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A display choice changed outside WALI; it was preserved."
                    )
                }
                if existing.createdDisplayNode,
                   isManaged,
                   let currentID = Self.aerialAssetID(in: current) {
                    guard try Self.isExactSynthesizedDisplayNode(
                        in: root,
                        choicePath: path,
                        assetID: currentID
                    ) else {
                        throw LockScreenCompatibilityError.ownershipConflict(
                            "A WALI-created display override changed outside WALI; it was preserved."
                        )
                    }
                }
                originalChoices = existing.originalChoices
                createdDisplayNode = existing.createdDisplayNode
            } else {
                if missingTopLevelPaths.contains(path) {
                    guard current == nil else {
                        throw LockScreenCompatibilityError.ownershipConflict(
                            "A missing display override appeared during reconciliation; it was preserved."
                        )
                    }
                    originalChoices = nil
                    createdDisplayNode = true
                } else if let currentID = Self.aerialAssetID(in: current),
                   knownOwnedAssetIDs.contains(currentID) {
                    guard currentID == assetID else {
                        throw LockScreenCompatibilityError.ownershipConflict(
                            "A new display choice points to a different WALI asset; it was preserved."
                        )
                    }
                    originalChoices = try Self.inheritedOriginalChoices(
                        forNewPath: path,
                        managedAssetID: currentID,
                        from: journal.records
                    )
                    createdDisplayNode = false
                } else {
                    originalChoices = try current.map(Self.encodePlistValue)
                    createdDisplayNode = false
                }
            }
            committedRecords.append(.init(
                path: path,
                originalChoices: originalChoices,
                managedAssetIDs: [assetID],
                targetAssetID: assetID,
                createdDisplayNode: createdDisplayNode
            ))
            let replacement = try Self.wallpaperChoices(assetID: assetID)
            if !Self.propertyListsEqual(current, replacement) {
                if createdDisplayNode, !existingPathSet.contains(path) {
                    root = try Self.addingSynthesizedDisplayNode(
                        choices: replacement,
                        atChoicePath: path,
                        in: root
                    )
                } else {
                    root = try Self.settingChoices(replacement, at: path, in: root)
                }
            }
        }

        guard committedRecords.count <= Self.maximumNodes else {
            throw LockScreenCompatibilityError.malformedStore("Too many wallpaper choice nodes.")
        }
        committedRecords.sort { $0.path < $1.path }
        let committedJournal = WallpaperChoiceJournal(
            phase: .committed,
            records: committedRecords
        )
        try Self.validateJournal(committedJournal)

        let hasStoreChange = !NSDictionary(dictionary: loaded.root).isEqual(to: root)
        guard hasStoreChange else {
            return .init(
                loaded: loaded,
                nextData: nil,
                preparedJournal: nil,
                committedJournal: committedJournal,
                recoveredCommittedChange: recoveredCommittedChange
            )
        }

        let nextData = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: loaded.format,
            options: 0
        )
        _ = try Self.decodeAndValidateStore(nextData)
        let committedByPath = Dictionary(
            uniqueKeysWithValues: committedRecords.map { ($0.path, $0) }
        )
        var transitionRecords: [WallpaperChoiceJournalRecord] = []
        for path in Set(journal.records.map(\.path)).union(committedRecords.map(\.path)).sorted() {
            let prior = recordsByPath[path]
            let post = committedByPath[path]
            guard existingPathSet.contains(path) || post?.createdDisplayNode == true else { continue }
            let original = prior?.originalChoices ?? post?.originalChoices
            let managed = Set(prior?.managedAssetIDs ?? [])
                .union(post?.managedAssetIDs ?? [])
            guard !managed.isEmpty,
                  managed.count <= Self.maximumManagedIDsPerNode else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A wallpaper choice transition exceeds WALI’s ownership bound."
                )
            }
            transitionRecords.append(.init(
                path: path,
                originalChoices: original,
                managedAssetIDs: managed.sorted { $0.uuidString < $1.uuidString },
                targetAssetID: post?.targetAssetID,
                createdDisplayNode: prior?.createdDisplayNode ?? post?.createdDisplayNode ?? false
            ))
        }
        let preparedJournal = WallpaperChoiceJournal(
            phase: .prepared,
            expectedIndexDigest: Self.digest(loaded.data),
            targetIndexDigest: Self.digest(nextData),
            records: transitionRecords
        )
        try Self.validateJournal(preparedJournal)
        return .init(
            loaded: loaded,
            nextData: nextData,
            preparedJournal: preparedJournal,
            committedJournal: committedJournal,
            recoveredCommittedChange: recoveredCommittedChange
        )
    }

    private func loadStore() throws -> LoadedStore {
        try LockScreenFileIO.requireRegularFile(indexURL, maximumBytes: Self.maximumStoreBytes)
        let data = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
        let decoded = try Self.decodeAndValidateStore(data)
        return .init(root: decoded.root, format: decoded.format, data: data)
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
            guard journal.schemaVersion == 2 else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "The WALI rollback journal is incompatible."
                )
            }
            try Self.validateJournal(journal)
            return journal
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore("The WALI rollback journal is invalid.")
        }
    }

    private func saveJournal(_ journal: WallpaperChoiceJournal) throws {
        try Self.validateJournal(journal)
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
            try Self.validateJournal(decoded)
        }
    }

    private static func validateJournal(_ journal: WallpaperChoiceJournal) throws {
        guard journal.schemaVersion == 2,
              journal.records.count <= maximumNodes,
              Set(journal.records.map(\.path)).count == journal.records.count else {
            throw LockScreenCompatibilityError.unsupportedSchema("The WALI rollback journal is incompatible.")
        }
        switch journal.phase {
        case .prepared:
            guard journal.expectedIndexDigest?.count == SHA256.byteCount,
                  journal.targetIndexDigest?.count == SHA256.byteCount else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "An interrupted wallpaper transaction is missing its file identities."
                )
            }
        case .committed:
            guard journal.expectedIndexDigest == nil,
                  journal.targetIndexDigest == nil else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "A committed wallpaper journal contains transaction identities."
                )
            }
        }
        for record in journal.records {
            let managed = Set(record.managedAssetIDs)
            guard Self.isDisplayChoicePath(record.path),
                  !managed.isEmpty,
                  managed.count == record.managedAssetIDs.count,
                  managed.count <= maximumManagedIDsPerNode,
                  record.targetAssetID.map(managed.contains) ?? true else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "The rollback journal contains an invalid or unbounded display record."
                )
            }
            if journal.phase == .committed {
                guard let target = record.targetAssetID,
                      managed == [target] else {
                    throw LockScreenCompatibilityError.unsupportedSchema(
                        "A committed wallpaper journal has no single managed target."
                    )
                }
            }
            if let original = record.originalChoices {
                _ = try decodeChoices(original)
            }
            if record.createdDisplayNode {
                guard record.originalChoices == nil,
                      Self.topLevelDisplayUUID(inChoicePath: record.path) != nil else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A synthesized display record has invalid rollback ownership."
                    )
                }
            }
        }
    }

    private struct LoadedStore {
        let root: [String: Any]
        let format: PropertyListSerialization.PropertyListFormat
        let data: Data
    }

    private struct ReconciliationPlan {
        let loaded: LoadedStore
        let nextData: Data?
        let preparedJournal: WallpaperChoiceJournal?
        let committedJournal: WallpaperChoiceJournal
        let recoveredCommittedChange: Bool
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

    private static func isDisplayChoicePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.count == 5,
           components[0] == "Displays",
           Array(components[2...]) == ["Linked", "Content", "Choices"] {
            return canonicalUUID(components[1])
        }
        if components.count == 7,
           components[0] == "Spaces",
           components[2] == "Displays",
           Array(components[4...]) == ["Linked", "Content", "Choices"] {
            return canonicalUUID(components[1]) && canonicalUUID(components[3])
        }
        return false
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.uppercased() == value
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

    private static func pointsToAnyAsset(_ choices: [Any]?, assetIDs: Set<UUID>) -> Bool {
        aerialAssetID(in: choices).map(assetIDs.contains) ?? false
    }

    private static func aerialAssetID(in choices: [Any]?) -> UUID? {
        guard let choices,
              choices.count == 1,
              let choice = choices[0] as? [String: Any],
              choice["Provider"] as? String == provider,
              let configuration = choice["Configuration"] as? Data else {
            return nil
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let decoded = try? PropertyListSerialization.propertyList(
            from: configuration,
            options: [],
            format: &format
        ) as? [String: Any],
              format == .binary,
              let rawID = decoded["assetID"] as? String,
              let id = UUID(uuidString: rawID) else {
            return nil
        }
        return id
    }

    private static func currentChoices(in root: [String: Any], path: String) -> [Any]? {
        value(at: path.split(separator: "/").map(String.init), in: root) as? [Any]
    }

    private static func inheritedOriginalChoices(
        forNewPath path: String,
        managedAssetID: UUID,
        from records: [WallpaperChoiceJournalRecord]
    ) throws -> Data? {
        guard let displayID = displayUUID(inChoicePath: path) else {
            throw LockScreenCompatibilityError.unsafePath("A new display choice path is malformed.")
        }
        let displayPath = "Displays/\(displayID)/Linked/Content/Choices"
        // A newly-created Space can inherit WALI's current display choice.
        // The display node is the deterministic fallback; other Spaces may
        // legitimately have distinct originals and retain their own records.
        return records.first(where: {
            $0.path == displayPath && $0.targetAssetID == managedAssetID
        })?.originalChoices
    }

    private static func displayUUID(inChoicePath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        if components.count == 5, components[0] == "Displays" { return components[1] }
        if components.count == 7,
           components[0] == "Spaces",
           components[2] == "Displays" {
            return components[3]
        }
        return nil
    }

    private static func topLevelDisplayUUID(inChoicePath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 5,
              components[0] == "Displays",
              Array(components[2...]) == ["Linked", "Content", "Choices"],
              canonicalUUID(components[1]) else {
            return nil
        }
        return components[1]
    }

    private static func addingSynthesizedDisplayNode(
        choices: [Any],
        atChoicePath path: String,
        in root: [String: Any]
    ) throws -> [String: Any] {
        guard let displayID = topLevelDisplayUUID(inChoicePath: path),
              var displays = root["Displays"] as? [String: Any],
              displays[displayID] == nil else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A top-level display override could not be created safely."
            )
        }
        displays[displayID] = [
            "Linked": [
                "Content": [
                    "Choices": choices,
                ],
            ],
        ]
        var copy = root
        copy["Displays"] = displays
        return copy
    }

    private static func isExactSynthesizedDisplayNode(
        in root: [String: Any],
        choicePath path: String,
        assetID: UUID
    ) throws -> Bool {
        let choices = try wallpaperChoices(assetID: assetID)
        guard let displayID = topLevelDisplayUUID(inChoicePath: path),
              let displays = root["Displays"] as? [String: Any],
              let node = displays[displayID] as? [String: Any] else {
            return false
        }
        let expected: [String: Any] = [
            "Linked": [
                "Content": [
                    "Choices": choices,
                ],
            ],
        ]
        return NSDictionary(dictionary: node).isEqual(to: expected)
    }

    private static func removingSynthesizedDisplayNode(
        atChoicePath path: String,
        in root: [String: Any]
    ) throws -> [String: Any] {
        guard let displayID = topLevelDisplayUUID(inChoicePath: path),
              var displays = root["Displays"] as? [String: Any],
              displays.removeValue(forKey: displayID) != nil else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "A WALI-created display override could not be removed safely."
            )
        }
        var copy = root
        copy["Displays"] = displays
        return copy
    }

    private static func restoring(
        _ record: WallpaperChoiceJournalRecord,
        in root: [String: Any]
    ) throws -> [String: Any] {
        try settingChoices(
            record.originalChoices.map { try decodeChoices($0) },
            at: record.path,
            in: root
        )
    }

    private static func preparedTargetIsReflected(
        _ journal: WallpaperChoiceJournal,
        in root: [String: Any],
        existingPaths: Set<String>
    ) throws -> Bool {
        guard journal.phase == .prepared else { return false }
        var checkedExistingNode = false
        for record in journal.records where existingPaths.contains(record.path) {
            checkedExistingNode = true
            let current = currentChoices(in: root, path: record.path)
            if let target = record.targetAssetID {
                guard pointsToAnyAsset(current, assetIDs: [target]) else { return false }
            } else {
                guard try matchesRecordedOriginal(current, record: record) else { return false }
            }
        }
        return checkedExistingNode
    }

    private static func matchesRecordedOriginal(
        _ current: [Any]?,
        record: WallpaperChoiceJournalRecord
    ) throws -> Bool {
        guard let data = record.originalChoices else { return current == nil }
        guard let current else { return false }
        return propertyListsEqual(current, try decodeChoices(data))
    }

    private static func decodeChoices(_ data: Data) throws -> [Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let decoded = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [Any] else {
            throw LockScreenCompatibilityError.malformedStore("A rollback choice is invalid.")
        }
        return decoded
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

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

private struct WallpaperChoiceJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    let schemaVersion: Int
    let phase: Phase
    let expectedIndexDigest: Data?
    let targetIndexDigest: Data?
    let records: [WallpaperChoiceJournalRecord]

    init(
        phase: Phase,
        expectedIndexDigest: Data? = nil,
        targetIndexDigest: Data? = nil,
        records: [WallpaperChoiceJournalRecord]
    ) {
        schemaVersion = 2
        self.phase = phase
        self.expectedIndexDigest = expectedIndexDigest
        self.targetIndexDigest = targetIndexDigest
        self.records = records
    }
}

private struct WallpaperChoiceJournalRecord: Codable, Sendable {
    let path: String
    let originalChoices: Data?
    let managedAssetIDs: [UUID]
    let targetAssetID: UUID?
    let createdDisplayNode: Bool

    init(
        path: String,
        originalChoices: Data?,
        managedAssetIDs: [UUID],
        targetAssetID: UUID?,
        createdDisplayNode: Bool = false
    ) {
        self.path = path
        self.originalChoices = originalChoices
        self.managedAssetIDs = managedAssetIDs
        self.targetAssetID = targetAssetID
        self.createdDisplayNode = createdDisplayNode
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case originalChoices
        case managedAssetIDs
        case targetAssetID
        case createdDisplayNode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        originalChoices = try container.decodeIfPresent(Data.self, forKey: .originalChoices)
        managedAssetIDs = try container.decode([UUID].self, forKey: .managedAssetIDs)
        targetAssetID = try container.decodeIfPresent(UUID.self, forKey: .targetAssetID)
        createdDisplayNode = try container.decodeIfPresent(
            Bool.self,
            forKey: .createdDisplayNode
        ) ?? false
    }
}
