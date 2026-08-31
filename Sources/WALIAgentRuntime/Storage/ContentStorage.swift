import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WALIModel

struct PreparedArtifact: Sendable {
    let url: URL
    let fileName: String
    let mediaKind: StoredArtifactMediaKind
    let digest: ContentDigest
    let byteCount: UInt64
}

struct VerifiedMedia: Sendable {
    let pixelSize: PixelSize
    let durationSeconds: Double?
}

enum ContentStorage {
    static let chunkSize = 1_048_576

    static func bootstrap(_ paths: LibraryPaths) throws {
        for directory in [paths.root, paths.metadata, paths.staging, paths.prepared, paths.objects] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try requireDirectoryWithoutSymlink(directory)
        }
    }

    static func requireDirectoryWithoutSymlink(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageError.symbolicLinkRejected
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageError.invalidRoot
        }
    }

    static func requireContainedRegularFile(_ url: URL, under root: URL) throws {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalURL.hasPrefix(canonicalRoot + "/") else {
            throw StorageError.pathEscapesStore
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageError.symbolicLinkRejected
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw StorageError.nonregularFile
        }
    }

    static func prepare(candidate: StagedArtifactCandidate, paths: LibraryPaths) throws -> PreparedArtifact {
        try requireContainedRegularFile(candidate.stagedURL, under: paths.staging)
        let fileName = "\(UUID().uuidString.lowercased()).\(candidate.mediaKind.fileExtension)"
        let destination = paths.prepared.appendingPathComponent(fileName, isDirectory: false)

        let input = open(candidate.stagedURL.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw StorageError.ioFailure(String(cString: strerror(errno))) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw StorageError.ioFailure(String(cString: strerror(errno))) }

        var shouldRemoveDestination = true
        defer {
            close(output)
            if shouldRemoveDestination { unlink(destination.path) }
        }

        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(input, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                throw StorageError.ioFailure(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = write(output, base.advanced(by: offset), count - offset)
                    guard written > 0 else {
                        throw StorageError.ioFailure(String(cString: strerror(errno)))
                    }
                    offset += written
                }
            }
            hasher.update(data: Data(buffer[0..<count]))
            total += UInt64(count)
        }
        guard total > 0 else { throw StorageError.nonregularFile }
        guard fsync(output) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let digest = try ContentDigest(algorithm: .sha256, value: value)
        if let claimed = candidate.claimedDigest, claimed != digest {
            throw StorageError.digestMismatch
        }
        if let claimed = candidate.claimedByteCount, claimed != total {
            throw StorageError.byteCountMismatch
        }
        shouldRemoveDestination = false
        try syncDirectory(paths.prepared)
        return PreparedArtifact(
            url: destination,
            fileName: fileName,
            mediaKind: candidate.mediaKind,
            digest: digest,
            byteCount: total
        )
    }

    static func sha256(of url: URL) throws -> ContentDigest {
        let input = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw StorageError.ioFailure(String(cString: strerror(errno))) }
        defer { close(input) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(input, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                throw StorageError.ioFailure(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return try ContentDigest(
            algorithm: .sha256,
            value: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    static func publish(_ prepared: PreparedArtifact, paths: LibraryPaths) throws -> URL {
        try requireContainedRegularFile(prepared.url, under: paths.prepared)
        let destination = try paths.objectURL(
            forSHA256: prepared.digest.value,
            mediaKind: prepared.mediaKind
        )
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try requireDirectoryWithoutSymlink(parent)

        guard chmod(prepared.url.path, 0o444) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        if renameatx_np(
            AT_FDCWD,
            prepared.url.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        ) == 0 {
            try syncFile(destination)
            try syncDirectory(parent)
            try syncDirectory(paths.prepared)
            return destination
        }
        guard errno == EEXIST else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        try requireContainedRegularFile(destination, under: paths.objects)
        guard try sha256(of: destination) == prepared.digest else {
            throw StorageError.digestMismatch
        }
        guard chmod(destination.path, 0o444) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        guard unlink(prepared.url.path) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        try syncDirectory(paths.prepared)
        return destination
    }

    static func verifyMedia(at url: URL, kind: StoredArtifactMediaKind) async throws -> VerifiedMedia {
        switch kind {
        case .hevcVideo:
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isReadable), try await asset.load(.isPlayable),
                  let track = try await asset.loadTracks(withMediaType: .video).first,
                  try await asset.loadTracks(withMediaType: .audio).isEmpty
            else {
                throw StorageError.unsupportedMedia
            }
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.contains(where: {
                let subtype = CMFormatDescriptionGetMediaSubType($0)
                return subtype == kCMVideoCodecType_HEVC
            }) else {
                throw StorageError.unsupportedMedia
            }
            let size = try await track.load(.naturalSize)
                .applying(try await track.load(.preferredTransform))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  abs(size.width) >= 1, abs(size.height) >= 1,
                  abs(size.width) <= 16_384, abs(size.height) <= 16_384
            else {
                throw StorageError.unsupportedMedia
            }
            return VerifiedMedia(
                pixelSize: try PixelSize(
                    width: UInt32(abs(size.width).rounded()),
                    height: UInt32(abs(size.height).rounded())
                ),
                durationSeconds: duration
            )
        case .heicImage:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source),
                  UTType(type as String)?.conforms(to: .heic) == true,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw StorageError.unsupportedMedia
            }
            return VerifiedMedia(
                pixelSize: try PixelSize(width: UInt32(image.width), height: UInt32(image.height)),
                durationSeconds: nil
            )
        }
    }

    static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageError.ioFailure(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageError.ioFailure(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
    }
}
