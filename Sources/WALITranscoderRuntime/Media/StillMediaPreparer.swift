import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WALIModel

/// Serial private-worker raster preparation. Original bytes are decoded only
/// here; the agent later verifies these immutable output claims independently.
struct StillMediaPreparer {
    static let maximumDimension = 7_680
    static let maximumPixels = 33_177_600
    static let maximumBytes = 128 * 1_024 * 1_024
    private let inspector = MediaInspector()

    func prepare(_ request: MediaTranscodeRequest,
                 progress: @Sendable (MediaPipelineProgress) -> Void) throws -> MediaTranscodeResult {
        try Task.checkCancellation()
        progress(.init(phase: .inspecting, fractionCompleted: 0))
        let bytes = try readSource(request.sourceURL, limit: request.sourceByteLimit)
        let source = try inspectSource(bytes)
        progress(.init(phase: .inspecting, fractionCompleted: 1))
        progress(.init(phase: .hashingSource, fractionCompleted: 0))
        let digest = try ContentDigest(algorithm: .sha256,
            value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        progress(.init(phase: .hashingSource, fractionCompleted: 1))
        let directory = try MediaTranscoder().makeAttemptDirectory(for: request)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        try requireStorage(at: directory)
        try Task.checkCancellation()
        progress(.init(phase: .transcodingMaster, fractionCompleted: 0))
        let master = try opaqueSRGB(source.image, width: source.image.width, height: source.image.height)
        let masterURL = directory.appendingPathComponent("master.png")
        try write(master, to: masterURL, type: .png)
        try stripPNGMetadata(at: masterURL)
        progress(.init(phase: .transcodingMaster, fractionCompleted: 1))
        try Task.checkCancellation()
        progress(.init(phase: .generatingPoster, fractionCompleted: 0))
        let scale = min(1, 1_920 / Double(max(master.width, master.height)))
        let poster = try opaqueSRGB(master, width: max(1, Int((Double(master.width) * scale).rounded())),
            height: max(1, Int((Double(master.height) * scale).rounded())))
        let posterURL = directory.appendingPathComponent("poster.heic")
        try write(poster, to: posterURL, type: .heic)
        progress(.init(phase: .generatingPoster, fractionCompleted: 1))
        try Task.checkCancellation()
        progress(.init(phase: .verifyingOutputs, fractionCompleted: 0))
        let masterClaim = try canonicalClaim(at: masterURL, kind: .masterImage, type: .png)
        let posterClaim = try canonicalClaim(at: posterURL, kind: .posterImage, type: .heic)
        progress(.init(phase: .verifyingOutputs, fractionCompleted: 1))
        let result = try MediaTranscodeResult(attempt: request.attempt,
            suggestedDisplayName: request.sourceURL.deletingPathExtension().lastPathComponent,
            sourceDigest: digest, sourceInspection: .still(source.inspection),
            claims: [masterClaim, posterClaim])
        try Task.checkCancellation()
        complete = true
        progress(.init(phase: .complete, fractionCompleted: 1))
        return result
    }

    private struct Source {
        let image: CGImage
        let inspection: StillMediaInspection
    }

    private func readSource(_ url: URL, limit: UInt64) throws -> Data {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost"
        else { throw MediaPipelineError.invalidFileURL }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? MediaPipelineError.sourceIsSymbolicLink : .sourceMissing
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw MediaPipelineError.sourceNotRegular
        }
        guard info.st_size > 0 else { throw MediaPipelineError.unsupportedStillImage }
        let bound = min(limit, UInt64(Self.maximumBytes))
        guard UInt64(info.st_size) <= bound else { throw MediaPipelineError.sourceTooLarge(limit: bound) }
        var bytes = Data(); bytes.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw MediaPipelineError.unsupportedStillImage }
            if count == 0 { break }
            guard bytes.count <= Int(bound) - count else { throw MediaPipelineError.sourceTooLarge(limit: bound) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == Int(info.st_size) else { throw MediaPipelineError.unsupportedStillImage }
        return bytes
    }

    private func inspectSource(_ bytes: Data) throws -> Source {
        // Inspect color/animation markers before ImageIO interprets profiles.
        if bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) {
            try validatePNGSource(bytes)
        } else { try validateJPEGSource(bytes) }
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let rawType = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.png.identifier].contains(rawType as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int,
              depth == 8, validDimensions(width, height)
        else { throw MediaPipelineError.unsupportedStillImage }
        let rawOrientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(rawOrientation),
              let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawOrientation))
        else { throw MediaPipelineError.unsupportedStillImage }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let declaredColor = exif[kCGImagePropertyExifColorSpace] {
            guard declaredColor as? Int == 1 else { throw MediaPipelineError.unsupportedStillImage }
        }
        let swapsAxes = [.leftMirrored, .right, .rightMirrored, .left].contains(orientation)
        let orientedWidth = swapsAxes ? height : width
        let orientedHeight = swapsAxes ? width : height
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), image.width == orientedWidth, image.height == orientedHeight,
            image.bitsPerComponent <= 8, image.bitsPerPixel <= 32,
            image.bytesPerRow <= Self.maximumBytes / image.height,
            let color = image.colorSpace,
            color.model == .rgb,
            !CGColorSpaceUsesExtendedRange(color), !color.isHDR()
        else { throw MediaPipelineError.unsupportedStillImage }
        // The admitted source is tagged sRGB or untagged RGB explicitly
        // interpreted as sRGB by the shared initial hosted/native policy.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let interpreted = image.copy(colorSpace: srgb) else { throw MediaPipelineError.unsupportedStillImage }
        try Task.checkCancellation()
        return Source(image: interpreted, inspection: StillMediaInspection(byteCount: UInt64(bytes.count),
            pixelSize: try PixelSize(width: UInt32(orientedWidth), height: UInt32(orientedHeight)),
            bitsPerComponent: UInt16(depth), colorSpace: "srgb",
            hasAlpha: ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)))
    }

    private func validDimensions(_ width: Int, _ height: Int) -> Bool {
        (1...Self.maximumDimension).contains(width) && (1...Self.maximumDimension).contains(height) &&
            width * height <= Self.maximumPixels && width * height * 4 <= Self.maximumBytes
    }

    private func opaqueSRGB(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard validDimensions(width, height), let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw MediaPipelineError.unsupportedStillImage }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw MediaPipelineError.unsupportedStillImage }
        return result
    }

    private func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                  type.identifier as CFString, 1, nil) else { throw MediaPipelineError.unsupportedStillImage }
        let properties = type == .heic
            ? [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw MediaPipelineError.unsupportedStillImage }
        try Task.checkCancellation()
    }

    /// ImageIO can generate eXIf even from a metadata-free CGImage. Retain only
    /// raster/color structure in the newly encoded master, never source chunks.
    private func stripPNGMetadata(at url: URL) throws {
        let bytes = try readSource(url, limit: UInt64(Self.maximumBytes))
        let chunks = try pngChunks(bytes)
        let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "cHRM", "gAMA", "iCCP", "sRGB", "sBIT", "pHYs"]
        var result = Data(bytes.prefix(8))
        for (kind, range) in chunks where allowed.contains(kind) { result.append(bytes[range]) }
        try result.write(to: url, options: .atomic)
    }

    private func validatePNGSource(_ bytes: Data) throws {
        let chunks = try pngChunks(bytes)
        guard !chunks.contains(where: { ["acTL", "fcTL", "fdAT", "iCCP", "cICP", "mDCV", "cLLI", "mDCv", "cLLi"].contains($0.0) })
        else { throw MediaPipelineError.unsupportedStillImage }
        for (kind, range) in chunks {
            let body = bytes[(range.lowerBound + 8)..<(range.upperBound - 4)]
            switch kind {
            case "gAMA":
                guard body.count == 4, body.reduce(0, { ($0 << 8) | Int($1) }) == 45_455
                else { throw MediaPipelineError.unsupportedStillImage }
            case "cHRM":
                let expected: [UInt32] = [31_270,32_900,64_000,33_000,30_000,60_000,15_000,6_000]
                guard body.count == 32 else { throw MediaPipelineError.unsupportedStillImage }
                for (index, wanted) in expected.enumerated() {
                    let start = body.startIndex + index * 4
                    guard body[start..<(start + 4)].reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == wanted
                    else { throw MediaPipelineError.unsupportedStillImage }
                }
            case "sRGB":
                guard body.count == 1, body.first! <= 3 else { throw MediaPipelineError.unsupportedStillImage }
            default: break
            }
        }
    }

    func validateJPEGSource(_ bytes: Data) throws {
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw MediaPipelineError.unsupportedStillImage
        }
        var offset = 2
        var segments = 0
        var inScan = false
        var hadScan = false
        while offset < bytes.count {
            try Task.checkCancellation()
            if inScan {
                // JPEG entropy escapes literal FF as FF00; restart markers do
                // not finish the scan. Other markers can introduce another
                // progressive scan or metadata that must still be inspected.
                while offset < bytes.count {
                    if bytes[offset] != 0xff { offset += 1; continue }
                    guard offset + 1 < bytes.count else { throw MediaPipelineError.unsupportedStillImage }
                    let next = bytes[offset + 1]
                    if next == 0 || (0xd0...0xd7).contains(next) { offset += 2; continue }
                    if next == 0xff { offset += 1; continue }
                    break
                }
            }
            segments += 1
            guard segments <= 16_384, offset < bytes.count, bytes[offset] == 0xff else { throw MediaPipelineError.unsupportedStillImage }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw MediaPipelineError.unsupportedStillImage }
            let marker = bytes[offset]; offset += 1
            if marker == 0xd9 {
                guard hadScan, offset == bytes.count else { throw MediaPipelineError.unsupportedStillImage }
                return
            }
            guard marker != 0xd8, offset + 2 <= bytes.count else { throw MediaPipelineError.unsupportedStillImage }
            let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard count >= 2, count <= bytes.count - offset else { throw MediaPipelineError.unsupportedStillImage }
            if marker == 0xe2 {
                let payload = bytes[(offset + 2)..<(offset + count)]
                guard !payload.starts(with: Data("ICC_PROFILE\0".utf8)), !payload.starts(with: Data("MPF\0".utf8))
                else { throw MediaPipelineError.unsupportedStillImage }
            }
            offset += count
            inScan = marker == 0xda || (inScan && marker == 0xdc)
            hadScan = hadScan || marker == 0xda
        }
        throw MediaPipelineError.unsupportedStillImage
    }

    private func pngChunks(_ bytes: Data) throws -> [(String, Range<Int>)] {
        guard bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw MediaPipelineError.unsupportedStillImage
        }
        var offset = 8
        var chunks: [(String, Range<Int>)] = []
        while offset < bytes.count {
            try Task.checkCancellation()
            guard chunks.count < 16_384, bytes.count - offset >= 12 else { throw MediaPipelineError.unsupportedStillImage }
            let count = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            guard count <= bytes.count - offset - 12,
                  let kind = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
            else { throw MediaPipelineError.unsupportedStillImage }
            chunks.append((kind, offset..<(offset + count + 12)))
            offset += count + 12
            if kind == "IEND" {
                guard count == 0, offset == bytes.count else { throw MediaPipelineError.unsupportedStillImage }
                return chunks
            }
        }
        throw MediaPipelineError.unsupportedStillImage
    }

    private func canonicalClaim(at url: URL, kind: MediaArtifactKind, type: UTType) throws -> MediaArtifactClaim {
        let bytes = try readSource(url, limit: UInt64(Self.maximumBytes))
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == type.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              validDimensions(width, height), kind != .posterImage || max(width, height) <= 1_920,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              image.bytesPerRow <= Self.maximumBytes / height,
              image.bitsPerComponent == 8, image.colorSpace?.name == CGColorSpace.sRGB,
              [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        else { throw MediaPipelineError.outputVerificationFailed(kind) }
        let facts = StillMediaInspection(byteCount: UInt64(bytes.count),
            pixelSize: try PixelSize(width: UInt32(width), height: UInt32(height)),
            bitsPerComponent: 8, colorSpace: "srgb", hasAlpha: false)
        return MediaArtifactClaim(kind: kind, stagedURL: url, digest: try inspector.sha256(of: url),
            byteCount: facts.byteCount, inspection: .still(facts))
    }

    private func requireStorage(at directory: URL) throws {
        let required: UInt64 = 512 * 1_024 * 1_024
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ??
            Int64(values.volumeAvailableCapacity ?? 0)))
        guard available >= required else {
            throw MediaPipelineError.insufficientStorage(requiredBytes: required, availableBytes: available)
        }
    }
}
