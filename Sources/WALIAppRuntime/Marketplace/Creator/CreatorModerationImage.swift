import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CreatorReviewImageSource: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let byteCount: UInt64
}

public enum CreatorReviewMedia: Sendable, Equatable {
    case video(URL)
    case still(CreatorReviewImageSource)
}

/// Serial, bounded display decoding of an already length/digest-verified private
/// canonical artifact. This never decodes the creator's original upload.
actor CreatorModerationImageLoader {
    static let shared = CreatorModerationImageLoader()
    private let maximumBytes = 128 * 1_024 * 1_024
    enum Failure: Error { case invalidImage }

    func load(_ value: CreatorReviewImageSource) throws -> CGImage {
        try Task.checkCancellation()
        let url = value.url
        guard url.isFileURL, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              (1...7_680).contains(value.width), (1...7_680).contains(value.height),
              value.width * value.height <= 33_177_600,
              value.byteCount > 0, value.byteCount <= UInt64(maximumBytes)
        else { throw Failure.invalidImage }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidImage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, UInt64(info.st_size) == value.byteCount
        else { throw Failure.invalidImage }
        var bytes = Data(); bytes.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.invalidImage }
            if count == 0 { break }
            guard bytes.count <= Int(value.byteCount) - count else { throw Failure.invalidImage }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == Int(value.byteCount) else { throw Failure.invalidImage }
        try inspectCanonicalPNG(bytes, expected: value)
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == value.width,
              properties[kCGImagePropertyPixelHeight] as? Int == value.height,
              properties[kCGImagePropertyDepth] as? Int == 8,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary), image.width > 0, image.height > 0,
              image.width <= 2_048, image.height <= 2_048,
              image.bitsPerComponent == 8, image.bytesPerRow <= 16 * 1_024 * 1_024 / image.height,
              image.colorSpace?.name == CGColorSpace.sRGB,
              [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        else { throw Failure.invalidImage }
        try Task.checkCancellation()
        return image
    }

    private func inspectCanonicalPNG(_ bytes: Data, expected: CreatorReviewImageSource) throws {
        guard bytes.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw Failure.invalidImage }
        func word(_ offset: Int) -> Int { bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        var offset = 8, count = 0
        var header = false, color = false, pixels = false
        while offset < bytes.count {
            try Task.checkCancellation()
            count += 1
            guard count <= 16_384, bytes.count - offset >= 12 else { throw Failure.invalidImage }
            let length = word(offset)
            guard length <= bytes.count - offset - 12,
                  let kind = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
            else { throw Failure.invalidImage }
            switch kind {
            case "IHDR":
                guard offset == 8, !header, length == 13, word(offset + 8) == expected.width,
                      word(offset + 12) == expected.height,
                      Array(bytes[(offset + 16)..<(offset + 21)]) == [8,2,0,0,0]
                else { throw Failure.invalidImage }
                header = true
            case "sRGB":
                guard header, !pixels, !color, length == 1, bytes[offset + 8] <= 3 else { throw Failure.invalidImage }
                color = true
            case "IDAT":
                guard header, color else { throw Failure.invalidImage }
                pixels = pixels || length > 0
            case "IEND":
                guard header, color, pixels, length == 0, offset + 12 == bytes.count else { throw Failure.invalidImage }
                return
            default: throw Failure.invalidImage
            }
            offset += length + 12
        }
        throw Failure.invalidImage
    }
}
