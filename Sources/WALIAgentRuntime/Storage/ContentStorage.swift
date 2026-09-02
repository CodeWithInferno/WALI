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

    /// Copies catalog bytes from an already-open quarantine directory into a
    /// fresh agent-owned directory while hashing the exact descriptor bytes.
    /// The caller only ever bookmarks and transcodes the returned copy.
    static func adoptCatalogQuarantine(
        _ url: URL,
        under root: URL,
        into destinationDirectory: URL,
        expectedDigest: ContentDigest,
        expectedByteCount: UInt64
    ) throws -> URL {
        try requireDirectoryWithoutSymlink(root)
        try requireDirectoryWithoutSymlink(destinationDirectory)
        guard url.standardizedFileURL.deletingLastPathComponent() == root.standardizedFileURL,
              !url.lastPathComponent.isEmpty,
              !url.lastPathComponent.contains("/")
        else { throw StorageError.pathEscapesStore }

        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        defer { close(rootDescriptor) }
        var preflight = stat()
        guard fstatat(
            rootDescriptor,
            url.lastPathComponent,
            &preflight,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        guard (preflight.st_mode & S_IFMT) == S_IFREG else {
            if (preflight.st_mode & S_IFMT) == S_IFLNK {
                throw StorageError.symbolicLinkRejected
            }
            throw StorageError.nonregularFile
        }
        let input = openat(
            rootDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard input >= 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              UInt64(info.st_size) == expectedByteCount,
              UInt64(info.st_blocks) * 512 >= expectedByteCount
        else {
            throw StorageError.invalidCandidate
        }

        let destinationDescriptor = open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDescriptor >= 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        defer { close(destinationDescriptor) }
        let fileName = "catalog-source.mp4"
        let destination = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
        let output = openat(
            destinationDescriptor,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard output >= 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        var keepDestination = false
        defer {
            close(output)
            if !keepDestination { unlinkat(destinationDescriptor, fileName, 0) }
        }

        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(input, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                throw StorageError.ioFailure(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            total += UInt64(count)
            guard total <= expectedByteCount else { throw StorageError.byteCountMismatch }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
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
        }
        guard total == expectedByteCount else { throw StorageError.byteCountMismatch }
        let digest = try ContentDigest(
            algorithm: .sha256,
            value: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
        guard digest == expectedDigest else { throw StorageError.digestMismatch }
        guard fsync(output) == 0, fchmod(output, 0o400) == 0 else {
            throw StorageError.ioFailure(String(cString: strerror(errno)))
        }
        keepDestination = true
        try syncDirectory(destinationDirectory)
        return destination
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
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard try await asset.load(.isReadable), try await asset.load(.isPlayable),
                  videoTracks.count == 1,
                  let track = videoTracks.first,
                  try await asset.loadTracks(withMediaType: .audio).isEmpty
            else {
                throw StorageError.unsupportedMedia
            }
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy(Self.isAerialMain10) else {
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

    private static func isAerialMain10(_ description: CMFormatDescription) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        guard subtype == kCMVideoCodecType_HEVC || subtype == FourCharCode(0x6865_7631),
              let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let atoms = extensions[
                  kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
              ] as? [String: Any],
              let configuration = atoms["hvcC"] as? Data
        else { return false }

        let bitsKey = kCMFormatDescriptionExtension_BitsPerComponent as String
        let bitsPerComponent: UInt16?
        if let rawBits = extensions[bitsKey] {
            guard let number = rawBits as? NSNumber,
                  number.intValue >= 0,
                  number.intValue <= Int(UInt16.max)
            else { return false }
            bitsPerComponent = number.uint16Value
        } else {
            bitsPerComponent = nil
        }
        return isAerialMain10(
            configuration: configuration,
            bitsPerComponent: bitsPerComponent
        ) && isAerialSDRBT709(
            colorPrimaries: extensions[
                kCMFormatDescriptionExtension_ColorPrimaries as String
            ] as? String,
            transferFunction: extensions[
                kCMFormatDescriptionExtension_TransferFunction as String
            ] as? String,
            yCbCrMatrix: extensions[
                kCMFormatDescriptionExtension_YCbCrMatrix as String
            ] as? String
        )
    }

    static func isAerialMain10(
        configuration: Data,
        bitsPerComponent: UInt16?
    ) -> Bool {
        guard configuration.count >= 23,
              configuration[0] == 1,
              configuration[1] & 0x1f == 2,
              configuration[13] & 0xf0 == 0xf0,
              configuration[15] & 0xfc == 0xfc,
              configuration[16] & 0xfc == 0xfc,
              configuration[16] & 0x03 == 1,
              configuration[17] & 0xf8 == 0xf8,
              configuration[18] & 0xf8 == 0xf8,
              configuration[17] & 0x07 == 2,
              configuration[18] & 0x07 == 2,
              bitsPerComponent == nil || bitsPerComponent == 10,
              isStructurallyValidHEVCConfiguration(configuration)
        else { return false }
        return true
    }

    static func isAerialSDRBT709(
        colorPrimaries: String?,
        transferFunction: String?,
        yCbCrMatrix: String?
    ) -> Bool {
        colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            && transferFunction == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            && yCbCrMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    private static func isStructurallyValidHEVCConfiguration(_ configuration: Data) -> Bool {
        var cursor = 23
        for _ in 0..<configuration[22] {
            guard cursor + 3 <= configuration.count else { return false }
            cursor += 1
            let unitCount = Int(configuration[cursor]) << 8
                | Int(configuration[cursor + 1])
            cursor += 2
            for _ in 0..<unitCount {
                guard cursor + 2 <= configuration.count else { return false }
                let unitLength = Int(configuration[cursor]) << 8
                    | Int(configuration[cursor + 1])
                cursor += 2
                guard unitLength > 0, cursor + unitLength <= configuration.count else {
                    return false
                }
                cursor += unitLength
            }
        }
        return cursor == configuration.count
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
