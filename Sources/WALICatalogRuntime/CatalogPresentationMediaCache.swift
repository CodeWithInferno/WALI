import CryptoKit
import Darwin
import Foundation
import WALICatalog

public enum CatalogPresentationMediaCacheError: String, Error, Sendable, Equatable {
    case invalidRoot = "invalid_root"
    case capacityExceeded = "capacity_exceeded"
    case unsupportedArtifact = "unsupported_artifact"
    case invalidCachedArtifact = "invalid_cached_artifact"
}

/// Retain alongside the presentation that uses returned file URLs. A live lease
/// prevents eviction while an image or player can still read those files.
public final class CatalogMediaLease: Sendable {
    fileprivate let id = UUID()
    public init() {}
}

public protocol CatalogPresentationMediaCaching: Sendable {
    func localURL(for artifact: CatalogArtifact) async throws -> URL
    func localURL(for artifact: CreatorCanonicalArtifact) async throws -> URL
    func localURL(for artifact: CatalogArtifact, retaining lease: CatalogMediaLease) async throws -> URL
    func localURL(for artifact: CreatorCanonicalArtifact, retaining lease: CatalogMediaLease) async throws -> URL
}

public extension CatalogPresentationMediaCaching {
    func localURL(for artifact: CatalogArtifact, retaining lease: CatalogMediaLease) async throws -> URL {
        try await localURL(for: artifact)
    }
    func localURL(for artifact: CreatorCanonicalArtifact, retaining lease: CatalogMediaLease) async throws -> URL {
        try await localURL(for: artifact)
    }
}

/// Owns the only path from catalog media claims to image/video decoders.
/// Remote bytes are length- and digest-verified by `CatalogDownloader`, moved
/// into a private content-addressed cache, made read-only, then verified again.
public actor CatalogPresentationMediaCache: CatalogPresentationMediaCaching {
    private static let posterByteLimit: UInt64 = 25 * 1_024 * 1_024
    private static let previewByteLimit: UInt64 = 128 * 1_024 * 1_024
    private static let playbackByteLimit = CatalogArtifact.maximumByteCount

    private let root: URL
    private let incoming: URL
    private let downloader: CatalogDownloader
    private let maximumByteCount: UInt64
    private let maximumFileCount: Int
    private let unscopedLease = CatalogMediaLease()
    private var leases: [UUID: WeakLease] = [:]
    private var pins: [String: Set<UUID>] = [:]
    private var reservedBytes: UInt64 = 0
    private var reservedFiles = 0
    private var preparedDirectories = false

    private final class WeakLease {
        weak var value: CatalogMediaLease?
        init(_ value: CatalogMediaLease) { self.value = value }
    }

    public init(
        root: URL, downloader: CatalogDownloader,
        maximumByteCount: UInt64 = 3 * 1_024 * 1_024 * 1_024,
        maximumFileCount: Int = 512
    ) throws {
        guard root.isFileURL, maximumByteCount > 0, maximumFileCount > 0 else {
            throw CatalogPresentationMediaCacheError.invalidRoot
        }
        self.root = root.standardizedFileURL
        incoming = root.standardizedFileURL.appending(path: ".incoming", directoryHint: .isDirectory)
        self.downloader = downloader
        self.maximumByteCount = maximumByteCount
        self.maximumFileCount = maximumFileCount
    }

    public init(environment: CatalogEnvironment, bundleIdentifier: String) throws {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CatalogPresentationMediaCacheError.invalidRoot
        }
        let root = caches
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "VerifiedCatalogMedia", directoryHint: .isDirectory)
        try self.init(
            root: root,
            downloader: CatalogDownloader(
                approvedHosts: environment.approvedCDNHosts.union([environment.supabaseURL.host].compactMap { $0 })
            )
        )
    }

    public func localURL(for artifact: CatalogArtifact) async throws -> URL {
        try await localURL(for: artifact, retaining: unscopedLease)
    }

    public func localURL(for artifact: CatalogArtifact, retaining lease: CatalogMediaLease) async throws -> URL {
        try validatePresentationArtifact(artifact)
        try prepareDirectories()
        let destination = root.appending(
            path: "\(artifact.sha256).\(fileExtension(for: artifact))",
            directoryHint: .notDirectory
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            if try verify(destination, artifact: artifact) { return protect(destination, retaining: lease) }
            try FileManager.default.removeItem(at: destination)
        }

        try reserve(byteCount: artifact.byteCount)
        defer { reservedBytes -= artifact.byteCount; reservedFiles -= 1 }
        let downloaded = try await downloader.download(
            artifact: artifact,
            quarantineDirectory: incoming
        )
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard renamex_np(downloaded.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST, try verify(destination, artifact: artifact) { return protect(destination, retaining: lease) }
            throw CatalogPresentationMediaCacheError.invalidCachedArtifact
        }
        do {
            guard chmod(destination.path, 0o400) == 0,
                  try verify(destination, artifact: artifact)
            else {
                throw CatalogPresentationMediaCacheError.invalidCachedArtifact
            }
            try synchronizeDirectory(root)
            return protect(destination, retaining: lease)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func localURL(for artifact: CreatorCanonicalArtifact) async throws -> URL {
        try await localURL(for: artifact, retaining: unscopedLease)
    }

    public func localURL(for artifact: CreatorCanonicalArtifact, retaining lease: CatalogMediaLease) async throws -> URL {
        try validatePresentationArtifact(artifact)
        try prepareDirectories()
        let destination = root.appending(
            path: "\(artifact.sha256).\(fileExtension(for: artifact.mediaType))",
            directoryHint: .notDirectory
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            if try verify(
                destination,
                sha256: artifact.sha256,
                byteCount: artifact.byteCount
            ) { return protect(destination, retaining: lease) }
            try FileManager.default.removeItem(at: destination)
        }
        try reserve(byteCount: artifact.byteCount)
        defer { reservedBytes -= artifact.byteCount; reservedFiles -= 1 }
        let downloaded = try await downloader.downloadVerified(
            url: artifact.url,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            mediaType: artifact.mediaType,
            quarantineDirectory: incoming
        )
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard renamex_np(downloaded.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST,
               try verify(destination, sha256: artifact.sha256, byteCount: artifact.byteCount) {
                return protect(destination, retaining: lease)
            }
            throw CatalogPresentationMediaCacheError.invalidCachedArtifact
        }
        do {
            guard chmod(destination.path, 0o400) == 0,
                  try verify(destination, sha256: artifact.sha256, byteCount: artifact.byteCount)
            else { throw CatalogPresentationMediaCacheError.invalidCachedArtifact }
            try synchronizeDirectory(root)
            return protect(destination, retaining: lease)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func protect(_ url: URL, retaining lease: CatalogMediaLease) -> URL {
        leases[lease.id] = WeakLease(lease)
        pins[url.lastPathComponent, default: []].insert(lease.id)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    private func prepareDirectories() throws {
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(incoming)
        guard !preparedDirectories else { return }
        // This actor is the single owner of this app's presentation cache.
        // Remove only recognized quarantine files left by a previous process.
        for url in try FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.count > 36, UUID(uuidString: String(name.prefix(36))) != nil,
                  name.dropFirst(36).hasPrefix(".wali-quarantine.") else { continue }
            try FileManager.default.removeItem(at: url)
        }
        try reserve(byteCount: 0)
        reservedFiles -= 1
        preparedDirectories = true
    }

    private func reserve(byteCount: UInt64) throws {
        guard byteCount <= maximumByteCount, reservedBytes <= maximumByteCount - byteCount else {
            throw CatalogPresentationMediaCacheError.capacityExceeded
        }
        leases = leases.filter { $0.value.value != nil }
        pins = pins.compactMapValues { ids in
            let live = ids.filter { leases[$0] != nil }
            return live.isEmpty ? nil : live
        }
        var entries: [(url: URL, size: UInt64, date: Date)] = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count == 64, stem.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  ["jpg", "png", "avif", "mp4"].contains(url.pathExtension) else { continue }
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
                  attributes.st_nlink == 1, attributes.st_size >= 0 else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            entries.append((url, UInt64(attributes.st_size), date))
        }
        var used = entries.reduce(UInt64(0)) { $0 + $1.size }
        var count = entries.count
        let allowed = maximumByteCount - reservedBytes - byteCount
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard used > allowed || count + reservedFiles >= maximumFileCount else { break }
            guard pins[entry.url.lastPathComponent] == nil else { continue }
            try FileManager.default.removeItem(at: entry.url)
            used -= entry.size
            count -= 1
        }
        guard used <= allowed, count + reservedFiles < maximumFileCount else {
            throw CatalogPresentationMediaCacheError.capacityExceeded
        }
        reservedBytes += byteCount
        reservedFiles += 1
    }

    private func validatePresentationArtifact(_ artifact: CatalogArtifact) throws {
        switch (artifact.role, artifact.mediaType) {
        case (.poster, "image/jpeg"), (.poster, "image/png"), (.poster, "image/avif"):
            guard artifact.byteCount <= Self.posterByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        case (.preview, "video/mp4"):
            guard artifact.byteCount <= Self.previewByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        case (.videoDefault, "video/mp4"):
            guard artifact.byteCount <= Self.playbackByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        default:
            throw CatalogPresentationMediaCacheError.unsupportedArtifact
        }
    }

    private func validatePresentationArtifact(_ artifact: CreatorCanonicalArtifact) throws {
        switch (artifact.role, artifact.mediaType) {
        case (.poster, "image/jpeg"), (.poster, "image/png"):
            guard artifact.byteCount <= Self.posterByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        case (.preview, "video/mp4"):
            guard artifact.byteCount <= Self.previewByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        case (.videoDefault, "video/mp4"):
            guard artifact.byteCount <= Self.playbackByteLimit else {
                throw CatalogPresentationMediaCacheError.unsupportedArtifact
            }
        default:
            throw CatalogPresentationMediaCacheError.unsupportedArtifact
        }
    }

    private func fileExtension(for artifact: CatalogArtifact) -> String {
        fileExtension(for: artifact.mediaType)
    }

    private func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/avif": "avif"
        case "video/mp4": "mp4"
        default: "bin"
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR,
              (value.st_mode & S_IFMT) != S_IFLNK
        else { throw CatalogPresentationMediaCacheError.invalidRoot }
    }

    private func verify(_ url: URL, artifact: CatalogArtifact) throws -> Bool {
        try verify(url, sha256: artifact.sha256, byteCount: artifact.byteCount)
    }

    private func verify(_ url: URL, sha256: String, byteCount: UInt64) throws -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_nlink == 1,
              value.st_size > 0,
              UInt64(value.st_size) == byteCount
        else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { return false }
            if count == 0 { break }
            total += UInt64(count)
            guard total <= byteCount else { return false }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return total == byteCount && digest == sha256
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CatalogPresentationMediaCacheError.invalidRoot }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CatalogPresentationMediaCacheError.invalidCachedArtifact
        }
    }
}
