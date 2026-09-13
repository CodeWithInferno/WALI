import Darwin
import Foundation
import WALIWire

public enum StoreSharedDirectories {
    public static func root(fileManager: FileManager = .default,
                            bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
                            groupIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "WALIApplicationGroupIdentifier") as? String) throws -> URL {
        let expected: String
        if bundleIdentifier.hasPrefix("com.wali.store.development.") { expected = "group.com.wali.store.development.shared" }
        else if bundleIdentifier.hasPrefix("com.wali.store.") { expected = "group.com.wali.store.shared" }
        else { throw StorageError.invalidRoot }
        guard groupIdentifier == expected,
              let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: expected) else { throw StorageError.invalidRoot }
        try ContentStorage.requireDirectoryWithoutSymlink(root)
        return root
    }

    public static func quarantine(fileManager: FileManager = .default) throws -> URL {
        let directory = try root(fileManager: fileManager).appendingPathComponent("CatalogQuarantine", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try ContentStorage.requireDirectoryWithoutSymlink(directory)
        return directory
    }
}

/// Rebuildable presentation copies. No shared file is an input to installation.
/// Master videos never enter this directory. Keep one instance per agent.
public final class StorePresentationCache: @unchecked Sendable {
    private struct Fingerprint: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        init(_ info: stat) {
            inode = UInt64(info.st_ino); size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }
    private struct Entry {
        let name: String
        let source: URL
        let bytes: UInt64
    }
    private let paths: LibraryPaths
    private let directory: URL
    private let budgetBytes: UInt64
    private let lock = NSLock()
    private var fingerprints: [String: Fingerprint] = [:]
    private var sourcePaths: [String: String] = [:]
    private var demandedIDs: [UUID] = []

    public init(paths: LibraryPaths, groupRoot: URL? = nil, budgetBytes: UInt64 = 128 * 1_024 * 1_024) throws {
        self.paths = paths
        self.budgetBytes = min(budgetBytes, 128 * 1_024 * 1_024)
        let root = try groupRoot ?? StoreSharedDirectories.root()
        try ContentStorage.requireDirectoryWithoutSymlink(root)
        directory = root.appendingPathComponent("Presentation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try ContentStorage.requireDirectoryWithoutSymlink(directory)
    }

    public func project(_ snapshot: AgentSnapshot) throws -> AgentSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try projectLocked(snapshot)
    }

    /// A bounded foreground hint can rebuild only existing committed items.
    /// It cannot supply a path, change the Engine, or request a master copy.
    public func prepare(_ itemIDs: [UUID], snapshot: AgentSnapshot) throws -> AgentSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !itemIDs.isEmpty, itemIDs.count <= 32, Set(itemIDs).count == itemIDs.count,
              Set(itemIDs).isSubset(of: Set(snapshot.items.map(\.id))) else { throw StorageError.invalidCandidate }
        let requested = Set(itemIDs)
        demandedIDs = Array((itemIDs + demandedIDs.filter { !requested.contains($0) }).prefix(32))
        let result = try projectLocked(snapshot)
        for item in result.items where requested.contains(item.id) {
            let required: [URL]
            switch item.mediaContent {
            case let .video(_, previewURL, _): required = [previewURL, item.posterURL]
            case .still: required = [item.posterURL]
            }
            guard required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw StorageError.ioFailure("The presentation cache cannot fit this preview within the available storage budget.")
            }
        }
        return result
    }

    private func projectLocked(_ snapshot: AgentSnapshot) throws -> AgentSnapshot {
        try ContentStorage.requireDirectoryWithoutSymlink(directory)
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var remaining = budgetBytes
        if let limit = snapshot.resourceUsage.storageLimitBytes {
            remaining = min(remaining, limit > snapshot.resourceUsage.storageUsedBytes ? limit - snapshot.resourceUsage.storageUsedBytes : 0)
        }
        let available = Set(snapshot.items.map(\.id))
        demandedIDs.removeAll { !available.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: demandedIDs.enumerated().map { ($0.element, $0.offset) })
        let active = Set(snapshot.displays.compactMap(\.assignedItemID))
        let ordered = snapshot.items.sorted {
            let lhs = ranks[$0.id] ?? (active.contains($0.id) ? 32 : 33)
            let rhs = ranks[$1.id] ?? (active.contains($1.id) ? 32 : 33)
            if lhs != rhs { return lhs < rhs }
            return $0.createdAt > $1.createdAt
        }
        var entries: [Entry] = []
        // Bound both metadata work and cache population for large libraries.
        for (index, item) in ordered.prefix(512).enumerated() {
            var mediaFiles = [("poster.heic", item.posterURL, UInt64(4 * 1_024 * 1_024))]
            if case let .video(_, previewURL, _) = item.mediaContent {
                mediaFiles.append(("preview.mov", previewURL, budgetBytes))
            }
            for (kind, source, perFileLimit) in mediaFiles {
                if kind == "preview.mov" && ranks[item.id] == nil && !active.contains(item.id) && index >= 8 { continue }
                guard let bytes = try? sourceBytes(source), bytes > 0, bytes <= perFileLimit, bytes <= remaining else { continue }
                entries.append(Entry(name: item.id.uuidString.lowercased() + "-" + kind, source: source, bytes: bytes))
                remaining -= bytes
            }
        }
        let retained = Set(entries.map(\.name))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 4_096 else { throw StorageError.invalidRoot }
        for name in names where !retained.contains(name) {
            // unlinkat never follows a hostile symlink or recursively traverses a directory.
            guard unlinkat(descriptor, name, 0) == 0 else { throw StorageError.invalidRoot }
            fingerprints.removeValue(forKey: name)
            sourcePaths.removeValue(forKey: name)
        }
        var cachedBytes: UInt64 = 0
        for entry in entries {
            var existing = stat()
            let matches = fstatat(descriptor, entry.name, &existing, AT_SYMLINK_NOFOLLOW) == 0 &&
                (existing.st_mode & S_IFMT) == S_IFREG && existing.st_size == Int64(entry.bytes) &&
                fingerprints[entry.name] == Fingerprint(existing) && sourcePaths[entry.name] == entry.source.path
            if !matches { try copy(entry, into: descriptor) }
            var written = stat()
            guard fstatat(descriptor, entry.name, &written, AT_SYMLINK_NOFOLLOW) == 0,
                  (written.st_mode & S_IFMT) == S_IFREG, written.st_size == Int64(entry.bytes) else { throw StorageError.invalidCandidate }
            fingerprints[entry.name] = Fingerprint(written)
            sourcePaths[entry.name] = entry.source.path
            cachedBytes += entry.bytes
        }
        let projected = snapshot.items.map { item in
            let name = item.id.uuidString.lowercased()
            let preview = directory.appendingPathComponent(name + "-preview.mov")
            let poster = directory.appendingPathComponent(name + "-poster.heic")
            let media: AgentWallpaperMediaContent
            switch item.mediaContent {
            case let .video(_, _, duration): media = .video(masterURL: preview, previewURL: preview, duration: duration)
            case .still: media = .still(imageURL: poster)
            }
            return AgentLibraryItem(id: item.id, name: item.name, createdAt: item.createdAt,
                mediaContent: media, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                posterURL: poster, contentDigest: item.contentDigest,
                byteCount: item.byteCount, isFavorite: item.isFavorite)
        }
        let usage = snapshot.resourceUsage
        let sum = usage.storageUsedBytes.addingReportingOverflow(cachedBytes)
        return AgentSnapshot(revision: snapshot.revision, connection: snapshot.connection,
            playback: snapshot.playback, items: projected, displays: snapshot.displays,
            imports: snapshot.imports, preferences: snapshot.preferences,
            resourceUsage: AgentResourceUsage(activePlayers: usage.activePlayers, cpuPercent: usage.cpuPercent,
                residentMemoryBytes: usage.residentMemoryBytes, isLowPowerModeEnabled: usage.isLowPowerModeEnabled,
                thermalState: usage.thermalState, storageUsedBytes: sum.overflow ? UInt64.max : sum.partialValue,
                storageLimitBytes: usage.storageLimitBytes), notice: snapshot.notice)
    }

    private func sourceBytes(_ source: URL) throws -> UInt64 {
        try ContentStorage.requireContainedRegularFile(source, under: paths.objects)
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_size > 0 else { throw StorageError.invalidCandidate }
        return UInt64(info.st_size)
    }

    private func copy(_ entry: Entry, into directoryDescriptor: Int32) throws {
        try ContentStorage.requireContainedRegularFile(entry.source, under: paths.objects)
        let input = Darwin.open(entry.source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw StorageError.invalidCandidate }
        defer { Darwin.close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == Int64(entry.bytes) else { throw StorageError.invalidCandidate }
        let temporary = ".copy-" + UUID().uuidString.lowercased()
        let output = openat(directoryDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw StorageError.invalidCandidate }
        defer { Darwin.close(output); unlinkat(directoryDescriptor, temporary, 0) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: UInt64 = 0
        while total < entry.bytes {
            let count = Darwin.read(input, &buffer, min(buffer.count, Int(entry.bytes - total)))
            guard count > 0 else { throw StorageError.invalidCandidate }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written) }
                guard amount > 0 else { throw StorageError.invalidCandidate }
                written += amount
            }
            total += UInt64(count)
        }
        guard fsync(output) == 0, renameat(directoryDescriptor, temporary, directoryDescriptor, entry.name) == 0 else { throw StorageError.invalidCandidate }
    }
}
