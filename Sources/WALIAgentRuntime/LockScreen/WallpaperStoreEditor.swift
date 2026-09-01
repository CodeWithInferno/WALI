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

/// Transactional editor for the verified macOS 26 current-user global linked
/// wallpaper selection. Its authority is limited to four exact top-level
/// values; every other Index.plist value is carried through untouched.
public struct WallpaperStoreEditor: Sendable {
    public static let provider = "com.apple.wallpaper.choice.aerials"

    private static let maximumStoreBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumJournalBytes: UInt64 = 4 * 1_024 * 1_024
    private static let maximumNodes = 512
    private static let maximumManagedIDs = 8
    private static let managedKeys = [
        "AllSpacesAndDisplays",
        "SystemDefault",
        "Displays",
        "Spaces",
    ]

    public let indexURL: URL
    public let journalURL: URL
    private let now: @Sendable () -> Date

    public init(indexURL: URL, journalURL: URL) {
        self.init(indexURL: indexURL, journalURL: journalURL, now: { Date() })
    }

    public init(
        indexURL: URL,
        journalURL: URL,
        now: @escaping @Sendable () -> Date
    ) {
        self.indexURL = indexURL
        self.journalURL = journalURL
        self.now = now
    }

    /// Runs complete schema, scope, ownership and rollback validation without
    /// writing either the Apple store or WALI's journal.
    @discardableResult
    public func preflight(
        assignments: [WallpaperStoreAssignment],
        knownOwnedAssetIDs: Set<UUID> = []
    ) throws -> WallpaperStoreEditResult {
        let plan = try makePlan(
            assignments: assignments,
            knownOwnedAssetIDs: knownOwnedAssetIDs
        )
        return Self.editResult(for: plan, includeRecoveredCommit: false)
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
        return Self.editResult(for: plan, includeRecoveredCommit: true)
    }

    public func validate() throws {
        _ = try loadStore()
        _ = try loadJournal()
    }

    private static func editResult(
        for plan: ReconciliationPlan,
        includeRecoveredCommit: Bool
    ) -> WallpaperStoreEditResult {
        .init(
            changed: plan.nextData != nil
                || (includeRecoveredCommit && plan.recoveredCommittedChange),
            patchedNodeCount: plan.targetAssetID == nil ? 0 : managedKeys.count
        )
    }

    private func makePlan(
        assignments: [WallpaperStoreAssignment],
        knownOwnedAssetIDs: Set<UUID>
    ) throws -> ReconciliationPlan {
        guard assignments.count <= 1 else {
            throw LockScreenCompatibilityError.assetRejected(
                "The verified Lock Screen store accepts only the main display wallpaper."
            )
        }
        let desiredAssetID = assignments.first?.assetID
        let loaded = try loadStore()
        let journal = try loadJournal()

        let originals: [WallpaperRootValue]
        let currentValues: [WallpaperRootValue]
        let currentAssetID: UUID?
        let matchedPreparedTarget: Bool
        if journal.originalValues.isEmpty {
            guard journal == .empty else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "The global wallpaper rollback journal is incomplete."
                )
            }
            guard desiredAssetID != nil else {
                return .init(
                    loaded: loaded,
                    nextData: nil,
                    preparedJournal: nil,
                    committedJournal: .empty,
                    recoveredCommittedChange: false,
                    targetAssetID: nil
                )
            }
            let referenced = Self.referencedAerialAssetIDs(in: loaded.root)
            guard referenced.isDisjoint(with: knownOwnedAssetIDs) else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "The store already references a WALI-owned asset without rollback metadata."
                )
            }
            originals = try Self.snapshotManagedValues(in: loaded.root)
            currentValues = originals
            currentAssetID = nil
            matchedPreparedTarget = false
        } else {
            originals = journal.originalValues
            let current = try Self.snapshotManagedValues(in: loaded.root)
            currentValues = current
            switch journal.phase {
            case .committed:
                guard Self.managedStateMatchesAllowingDaemonDates(
                    current,
                    journal.targetValues
                ) else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "A managed global wallpaper value changed outside WALI; it was preserved."
                    )
                }
                currentAssetID = journal.targetAssetID
                matchedPreparedTarget = false
            case .prepared:
                if Self.managedStateMatchesAllowingDaemonDates(
                    current,
                    journal.targetValues
                ) {
                    currentAssetID = journal.targetAssetID
                    matchedPreparedTarget = true
                } else if Self.managedStateMatchesAllowingDaemonDates(
                    current,
                    journal.sourceValues
                ) {
                    currentAssetID = journal.sourceAssetID
                    matchedPreparedTarget = false
                } else {
                    throw LockScreenCompatibilityError.ownershipConflict(
                        "An interrupted global wallpaper transaction no longer matches its source or target."
                    )
                }
            }
        }

        let desiredValues: [WallpaperRootValue]
        if desiredAssetID == currentAssetID {
            desiredValues = currentValues
        } else if journal.phase == .prepared,
                  desiredAssetID == journal.targetAssetID {
            desiredValues = journal.targetValues
        } else if let desiredAssetID {
            desiredValues = try Self.activeValues(
                from: originals,
                assetID: desiredAssetID,
                timestamp: now()
            )
        } else {
            desiredValues = originals
        }
        let nextRoot = try Self.applying(desiredValues, to: loaded.root)
        let committedJournal: WallpaperGlobalJournal = if let desiredAssetID {
            .init(
                phase: .committed,
                originalValues: originals,
                sourceValues: [],
                targetValues: desiredValues,
                managedAssetIDs: [desiredAssetID],
                targetAssetID: desiredAssetID
            )
        } else {
            .empty
        }
        try Self.validateJournal(committedJournal)
        _ = try Self.encodedJournal(committedJournal)

        guard !Self.rootValuesEqual(currentValues, desiredValues) else {
            return .init(
                loaded: loaded,
                nextData: nil,
                preparedJournal: nil,
                committedJournal: committedJournal,
                recoveredCommittedChange: journal.phase == .prepared && matchedPreparedTarget,
                targetAssetID: desiredAssetID
            )
        }

        let nextData = try PropertyListSerialization.data(
            fromPropertyList: nextRoot,
            format: loaded.format,
            options: 0
        )
        _ = try Self.decodeAndValidateStore(nextData)
        let managedIDs = Set(journal.managedAssetIDs)
            .union(currentAssetID.map { [$0] } ?? [])
            .union(desiredAssetID.map { [$0] } ?? [])
        guard !managedIDs.isEmpty,
              managedIDs.count <= Self.maximumManagedIDs else {
            throw LockScreenCompatibilityError.ownershipConflict(
                "The global wallpaper transition exceeds WALI's ownership bound."
            )
        }
        let preparedJournal = WallpaperGlobalJournal(
            phase: .prepared,
            expectedIndexDigest: Self.digest(loaded.data),
            targetIndexDigest: Self.digest(nextData),
            originalValues: originals,
            sourceValues: currentValues,
            targetValues: desiredValues,
            managedAssetIDs: managedIDs.sorted { $0.uuidString < $1.uuidString },
            sourceAssetID: currentAssetID,
            targetAssetID: desiredAssetID
        )
        try Self.validateJournal(preparedJournal)
        _ = try Self.encodedJournal(preparedJournal)
        return .init(
            loaded: loaded,
            nextData: nextData,
            preparedJournal: preparedJournal,
            committedJournal: committedJournal,
            recoveredCommittedChange: matchedPreparedTarget,
            targetAssetID: desiredAssetID
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
            throw LockScreenCompatibilityError.malformedStore(
                "Index.plist is not a valid property list."
            )
        }
        guard let root = object as? [String: Any],
              root.keys.count <= maximumNodes else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "Expected the verified global linked Index.plist layout."
            )
        }
        try validateManagedRootShape(root)
        return (root, format)
    }

    private static func validateManagedRootShape(_ root: [String: Any]) throws {
        guard let displays = root["Displays"] as? [String: Any],
              let spaces = root["Spaces"] as? [String: Any],
              displays.count <= maximumNodes,
              spaces.count <= maximumNodes,
              displays.values.allSatisfy({ $0 is [String: Any] }),
              spaces.values.allSatisfy({ $0 is [String: Any] }) else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "The global display or Space maps are missing or malformed."
            )
        }
        try validateGlobalLinkedNode(root["AllSpacesAndDisplays"], key: "AllSpacesAndDisplays")
        try validateGlobalLinkedNode(root["SystemDefault"], key: "SystemDefault")
    }

    private static func validateGlobalLinkedNode(_ value: Any?, key: String) throws {
        guard let node = value as? [String: Any],
              node["Type"] as? String == "linked",
              let linked = node["Linked"] as? [String: Any],
              linked["LastSet"] is Date,
              linked["LastUse"] is Date,
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [Any],
              choices.count == 1,
              content["EncodedOptionValues"] is Data,
              content["Shuffle"] as? String == "$null",
              let choice = choices.first as? [String: Any],
              choice["Provider"] is String,
              choice["Configuration"] is Data,
              choice["Files"] is [Any] else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "The verified \(key) linked node is missing or structurally different."
            )
        }
    }

    private func loadJournal() throws -> WallpaperGlobalJournal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return .empty }
        try LockScreenFileIO.requireRegularFile(
            journalURL,
            maximumBytes: Self.maximumJournalBytes
        )
        do {
            let journal = try JSONDecoder().decode(
                WallpaperGlobalJournal.self,
                from: Data(contentsOf: journalURL)
            )
            try Self.validateJournal(journal)
            return journal
        } catch let error as LockScreenCompatibilityError {
            throw error
        } catch {
            throw LockScreenCompatibilityError.malformedStore(
                "The WALI global rollback journal is invalid."
            )
        }
    }

    private func saveJournal(_ journal: WallpaperGlobalJournal) throws {
        try Self.validateJournal(journal)
        try LockScreenFileIO.requireDirectory(journalURL.deletingLastPathComponent())
        let data = try Self.encodedJournal(journal)
        try LockScreenFileIO.atomicWrite(data, to: journalURL) { staged in
            let decoded = try JSONDecoder().decode(
                WallpaperGlobalJournal.self,
                from: Data(contentsOf: staged)
            )
            try Self.validateJournal(decoded)
        }
    }

    private static func encodedJournal(_ journal: WallpaperGlobalJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw LockScreenCompatibilityError.malformedStore(
                "The WALI global rollback journal exceeds its safety limit."
            )
        }
        return data
    }

    private static func validateJournal(_ journal: WallpaperGlobalJournal) throws {
        let managed = Set(journal.managedAssetIDs)
        guard journal.schemaVersion == 3,
              managed.count == journal.managedAssetIDs.count,
              managed.count <= maximumManagedIDs,
              journal.targetAssetID.map(managed.contains) ?? true,
              journal.sourceAssetID.map(managed.contains) ?? true else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "The WALI global rollback journal is incompatible."
            )
        }
        switch journal.phase {
        case .prepared:
            guard journal.expectedIndexDigest?.count == SHA256.byteCount,
                  journal.targetIndexDigest?.count == SHA256.byteCount,
                  !journal.originalValues.isEmpty,
                  !journal.sourceValues.isEmpty,
                  !journal.targetValues.isEmpty,
                  !managed.isEmpty else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "An interrupted global wallpaper transaction is incomplete."
                )
            }
        case .committed:
            guard journal.expectedIndexDigest == nil,
                  journal.targetIndexDigest == nil,
                  journal.sourceAssetID == nil,
                  journal.sourceValues.isEmpty else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "A committed global wallpaper journal contains transaction state."
                )
            }
            if let target = journal.targetAssetID {
                guard journal.managedAssetIDs == [target],
                      !journal.originalValues.isEmpty,
                      !journal.targetValues.isEmpty else {
                    throw LockScreenCompatibilityError.unsupportedSchema(
                        "A committed global wallpaper journal has invalid ownership."
                    )
                }
            } else {
                guard managed.isEmpty,
                      journal.originalValues.isEmpty,
                      journal.targetValues.isEmpty else {
                    throw LockScreenCompatibilityError.unsupportedSchema(
                        "An inactive global wallpaper journal retained ownership."
                    )
                }
            }
        }
        for values in [journal.originalValues, journal.sourceValues, journal.targetValues]
        where !values.isEmpty {
            try validateRootValues(values)
        }
        if !journal.originalValues.isEmpty {
            if journal.sourceAssetID == nil, !journal.sourceValues.isEmpty,
               !rootValuesEqual(journal.sourceValues, journal.originalValues) {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A recorded global source does not match the original selection."
                )
            }
            if journal.targetAssetID == nil, !journal.targetValues.isEmpty,
               !rootValuesEqual(journal.targetValues, journal.originalValues) {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A recorded global rollback target does not match the original selection."
                )
            }
            try validateActiveValues(journal.sourceValues, assetID: journal.sourceAssetID)
            try validateActiveValues(journal.targetValues, assetID: journal.targetAssetID)
        }
    }

    private static func validateRootValues(_ values: [WallpaperRootValue]) throws {
        guard values.map(\.key) == managedKeys else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "The global wallpaper rollback roots are incomplete or reordered."
            )
        }
        var root: [String: Any] = [:]
        for value in values { root[value.key] = try decodePlistValue(value.value) }
        try validateManagedRootShape(root)
    }

    private static func validateActiveValues(
        _ values: [WallpaperRootValue],
        assetID: UUID?
    ) throws {
        guard !values.isEmpty else { return }
        if let assetID {
            let root = try applying(values, to: [:])
            guard let displays = root["Displays"] as? [String: Any], displays.isEmpty,
                  let spaces = root["Spaces"] as? [String: Any], spaces.isEmpty,
                  globalAssetID(in: root, key: "AllSpacesAndDisplays") == assetID,
                  globalAssetID(in: root, key: "SystemDefault") == assetID else {
                throw LockScreenCompatibilityError.ownershipConflict(
                    "A recorded global target does not match its managed WALI asset."
                )
            }
        }
    }

    private static func snapshotManagedValues(
        in root: [String: Any]
    ) throws -> [WallpaperRootValue] {
        try managedKeys.map { key in
            guard let value = root[key] else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "The managed global wallpaper roots are incomplete."
                )
            }
            return WallpaperRootValue(key: key, value: try encodePlistValue(value))
        }
    }

    private static func activeValues(
        from originals: [WallpaperRootValue],
        assetID: UUID,
        timestamp: Date
    ) throws -> [WallpaperRootValue] {
        var root = try applying(originals, to: [:])
        let choices = try wallpaperChoices(assetID: assetID)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard var node = root[key] as? [String: Any],
                  var linked = node["Linked"] as? [String: Any],
                  var content = linked["Content"] as? [String: Any] else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "A recorded global linked wallpaper node is malformed."
                )
            }
            content["Choices"] = choices
            linked["Content"] = content
            linked["LastSet"] = timestamp
            linked["LastUse"] = timestamp
            node["Linked"] = linked
            root[key] = node
        }
        root["Displays"] = [String: Any]()
        root["Spaces"] = [String: Any]()
        try validateManagedRootShape(root)
        return try snapshotManagedValues(in: root)
    }

    private static func applying(
        _ values: [WallpaperRootValue],
        to base: [String: Any]
    ) throws -> [String: Any] {
        guard values.map(\.key) == managedKeys else {
            throw LockScreenCompatibilityError.unsupportedSchema(
                "The global wallpaper rollback roots are incomplete."
            )
        }
        var root = base
        for value in values { root[value.key] = try decodePlistValue(value.value) }
        try validateManagedRootShape(root)
        return root
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

    private static func globalAssetID(in root: [String: Any], key: String) -> UUID? {
        guard let node = root[key] as? [String: Any],
              let linked = node["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [Any],
              choices.count == 1,
              let choice = choices[0] as? [String: Any],
              choice["Provider"] as? String == provider,
              let configuration = choice["Configuration"] as? Data else { return nil }
        return aerialAssetID(in: configuration)
    }

    private static func referencedAerialAssetIDs(in root: [String: Any]) -> Set<UUID> {
        var result: Set<UUID> = []
        for key in managedKeys { collectAerialAssetIDs(in: root[key], into: &result) }
        return result
    }

    private static func collectAerialAssetIDs(in value: Any?, into result: inout Set<UUID>) {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String == provider,
               let configuration = dictionary["Configuration"] as? Data,
               let assetID = aerialAssetID(in: configuration) {
                result.insert(assetID)
            }
            for nested in dictionary.values { collectAerialAssetIDs(in: nested, into: &result) }
        } else if let array = value as? [Any] {
            for nested in array { collectAerialAssetIDs(in: nested, into: &result) }
        }
    }

    private static func aerialAssetID(in configuration: Data) -> UUID? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let decoded = try? PropertyListSerialization.propertyList(
            from: configuration,
            options: [],
            format: &format
        ) as? [String: Any],
              format == .binary,
              let rawID = decoded["assetID"] as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    private static func rootValuesEqual(
        _ lhs: [WallpaperRootValue],
        _ rhs: [WallpaperRootValue]
    ) -> Bool {
        guard lhs.map(\.key) == rhs.map(\.key) else { return false }
        do {
            return try zip(lhs, rhs).allSatisfy { left, right in
                propertyListsEqual(
                    try decodePlistValue(left.value),
                    try decodePlistValue(right.value)
                )
            }
        } catch {
            return false
        }
    }

    /// WallpaperAgent legitimately advances these timestamps after WALI has
    /// committed a linked selection. No other managed-field drift is accepted.
    private static func managedStateMatchesAllowingDaemonDates(
        _ current: [WallpaperRootValue],
        _ recorded: [WallpaperRootValue]
    ) -> Bool {
        guard current.map(\.key) == managedKeys,
              recorded.map(\.key) == managedKeys else { return false }
        do {
            let currentRoot = try normalizedManagedState(current)
            let recordedRoot = try normalizedManagedState(recorded)
            return propertyListsEqual(currentRoot, recordedRoot)
        } catch {
            return false
        }
    }

    private static func normalizedManagedState(
        _ values: [WallpaperRootValue]
    ) throws -> [String: Any] {
        var root = try applying(values, to: [:])
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard var node = root[key] as? [String: Any],
                  var linked = node["Linked"] as? [String: Any],
                  linked["LastSet"] is Date,
                  linked["LastUse"] is Date else {
                throw LockScreenCompatibilityError.unsupportedSchema(
                    "A recorded global linked wallpaper node is malformed."
                )
            }
            linked.removeValue(forKey: "LastSet")
            linked.removeValue(forKey: "LastUse")
            node["Linked"] = linked
            root[key] = node
        }
        return root
    }

    private static func propertyListsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
    }

    private static func encodePlistValue(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private static func decodePlistValue(_ data: Data) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: nil
            )
        } catch {
            throw LockScreenCompatibilityError.malformedStore(
                "A recorded global wallpaper value is invalid."
            )
        }
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
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
    let preparedJournal: WallpaperGlobalJournal?
    let committedJournal: WallpaperGlobalJournal
    let recoveredCommittedChange: Bool
    let targetAssetID: UUID?
}

private struct WallpaperRootValue: Codable, Sendable, Equatable {
    let key: String
    let value: Data
}

private struct WallpaperGlobalJournal: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    static let empty = WallpaperGlobalJournal(
        phase: .committed,
        originalValues: [],
        sourceValues: [],
        targetValues: [],
        managedAssetIDs: [],
        targetAssetID: nil
    )

    let schemaVersion: Int
    let phase: Phase
    let expectedIndexDigest: Data?
    let targetIndexDigest: Data?
    let originalValues: [WallpaperRootValue]
    let sourceValues: [WallpaperRootValue]
    let targetValues: [WallpaperRootValue]
    let managedAssetIDs: [UUID]
    let sourceAssetID: UUID?
    let targetAssetID: UUID?

    init(
        phase: Phase,
        expectedIndexDigest: Data? = nil,
        targetIndexDigest: Data? = nil,
        originalValues: [WallpaperRootValue],
        sourceValues: [WallpaperRootValue],
        targetValues: [WallpaperRootValue],
        managedAssetIDs: [UUID],
        sourceAssetID: UUID? = nil,
        targetAssetID: UUID?
    ) {
        schemaVersion = 3
        self.phase = phase
        self.expectedIndexDigest = expectedIndexDigest
        self.targetIndexDigest = targetIndexDigest
        self.originalValues = originalValues
        self.sourceValues = sourceValues
        self.targetValues = targetValues
        self.managedAssetIDs = managedAssetIDs
        self.sourceAssetID = sourceAssetID
        self.targetAssetID = targetAssetID
    }
}
