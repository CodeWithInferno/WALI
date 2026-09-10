import Foundation
import WALIEngine

public enum EngineSnapshotStoreError: LocalizedError {
    case stateTooLarge
    case corruptState(String)

    public var errorDescription: String? {
        switch self {
        case .stateTooLarge:
            "WALI's local state exceeds its safety limit."
        case let .corruptState(detail):
            "WALI could not read its local state: \(detail)"
        }
    }
}

/// Atomic persistence for the engine's compact recovery snapshot.
public actor EngineSnapshotStore {
    private static let maximumStateBytes = 16 * 1_024 * 1_024
    public let rootURL: URL
    public let stateURL: URL

    public init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALIAgent"
    ) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        rootURL = applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        stateURL = rootURL
            .appendingPathComponent("Metadata", isDirectory: true)
            .appendingPathComponent("engine-state-v1.json", isDirectory: false)
    }

    public func load() throws -> EngineSnapshot {
        try bootstrap()
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return EngineSnapshot()
        }
        do {
            let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
            guard data.count <= Self.maximumStateBytes else {
                throw EngineSnapshotStoreError.stateTooLarge
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(EngineSnapshot.self, from: data)
        } catch let error as EngineSnapshotStoreError {
            throw error
        } catch {
            throw EngineSnapshotStoreError.corruptState(error.localizedDescription)
        }
    }

    public func save(_ snapshot: EngineSnapshot) throws {
        try bootstrap()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumStateBytes else {
            throw EngineSnapshotStoreError.stateTooLarge
        }
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    public func allocatedBytes() -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        var result: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]
            ), values.isRegularFile == true else {
                continue
            }
            result &+= UInt64(max(0, values.totalFileAllocatedSize ?? 0))
        }
        return result
    }

    private func bootstrap() throws {
        let metadata = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: metadata,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
