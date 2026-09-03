import CryptoKit
import Darwin
import Foundation
import WALICatalog

public enum CatalogPresentationMediaCacheError: String, Error, Sendable, Equatable {
    case invalidRoot = "invalid_root"
    case unsupportedArtifact = "unsupported_artifact"
    case invalidCachedArtifact = "invalid_cached_artifact"
}

public protocol CatalogPresentationMediaCaching: Sendable {
    func localURL(for artifact: CatalogArtifact) async throws -> URL
    func localURL(for artifact: CreatorCanonicalArtifact) async throws -> URL
}

/// Owns the only path from catalog media claims to image/video decoders.
/// Remote bytes are length- and digest-verified by `CatalogDownloader`, moved
/// into a private content-addressed cache, made read-only, then verified again.
public actor CatalogPresentationMediaCache: CatalogPresentationMediaCaching {
    private static let posterByteLimit: UInt64 = 25 * 1_024 * 1_024
    private static let previewByteLimit: UInt64 = 128 * 1_024 * 1_024
    private static let playbackByteLimit: UInt64 = 512 * 1_024 * 1_024

    private let root: URL
    private let incoming: URL
    private let downloader: CatalogDownloader

    public init(root: URL, downloader: CatalogDownloader) throws {
        guard root.isFileURL else { throw CatalogPresentationMediaCacheError.invalidRoot }
        self.root = root.standardizedFileURL
        incoming = root.standardizedFileURL.appending(path: ".incoming", directoryHint: .isDirectory)
        self.downloader = downloader
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
        try validatePresentationArtifact(artifact)
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(incoming)
        let destination = root.appending(
            path: "\(artifact.sha256).\(fileExtension(for: artifact))",
            directoryHint: .notDirectory
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            if try verify(destination, artifact: artifact) { return destination }
            try FileManager.default.removeItem(at: destination)
        }

        let downloaded = try await downloader.download(
            artifact: artifact,
            quarantineDirectory: incoming
        )
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard renamex_np(downloaded.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST, try verify(destination, artifact: artifact) { return destination }
            throw CatalogPresentationMediaCacheError.invalidCachedArtifact
        }
        do {
            guard chmod(destination.path, 0o400) == 0,
                  try verify(destination, artifact: artifact)
            else {
                throw CatalogPresentationMediaCacheError.invalidCachedArtifact
            }
            try synchronizeDirectory(root)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func localURL(for artifact: CreatorCanonicalArtifact) async throws -> URL {
        try validatePresentationArtifact(artifact)
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(incoming)
        let destination = root.appending(
            path: "\(artifact.sha256).\(fileExtension(for: artifact.mediaType))",
            directoryHint: .notDirectory
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            if try verify(
                destination,
                sha256: artifact.sha256,
                byteCount: artifact.byteCount
            ) { return destination }
            try FileManager.default.removeItem(at: destination)
        }
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
                return destination
            }
            throw CatalogPresentationMediaCacheError.invalidCachedArtifact
        }
        do {
            guard chmod(destination.path, 0o400) == 0,
                  try verify(destination, sha256: artifact.sha256, byteCount: artifact.byteCount)
            else { throw CatalogPresentationMediaCacheError.invalidCachedArtifact }
            try synchronizeDirectory(root)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
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
