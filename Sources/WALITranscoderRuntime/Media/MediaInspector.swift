import AVFoundation
import CryptoKit
import Foundation
import WALIModel

/// Bounded AVFoundation inspection and streaming content identity.
public struct MediaInspector: Sendable {
    public static let maximumDurationSeconds: Double = 30 * 60
    public static let maximumDimension: Double = 16_384
    public static let maximumFrameRate: Double = 240

    public init() {}

    public func inspectVideo(
        at url: URL,
        byteLimit: UInt64 = MediaTranscodeRequest.maximumSourceByteCount
    ) async throws -> MediaInspection {
        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw MediaPipelineError.sourceMissing
        }
        guard resourceValues.isSymbolicLink != true else {
            throw MediaPipelineError.sourceIsSymbolicLink
        }
        guard resourceValues.isRegularFile == true else {
            throw MediaPipelineError.sourceNotRegular
        }
        let byteCount = UInt64(resourceValues.fileSize ?? 0)
        guard byteCount > 0 else { throw MediaPipelineError.unreadableAsset }
        guard byteCount <= byteLimit else {
            throw MediaPipelineError.sourceTooLarge(limit: byteLimit)
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard try await asset.load(.isReadable), try await asset.load(.isPlayable) else {
            throw MediaPipelineError.unreadableAsset
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= Self.maximumDurationSeconds else {
            throw MediaPipelineError.invalidDuration
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaPipelineError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = abs(transformed.width).rounded()
        let height = abs(transformed.height).rounded()
        guard width >= 1, height >= 1,
              width <= Self.maximumDimension, height <= Self.maximumDimension,
              width <= Double(UInt32.max), height <= Double(UInt32.max)
        else {
            throw MediaPipelineError.unsupportedDimensions
        }

        let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        guard frameRate.isFinite, frameRate >= 0, frameRate <= Self.maximumFrameRate else {
            throw MediaPipelineError.unsupportedFrameRate
        }
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let codec = formatDescriptions.first.map {
            Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))
        } ?? "unknown"
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let isHDR = formatDescriptions.contains { description in
            guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
            else { return false }
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        }

        return MediaInspection(
            byteCount: byteCount,
            pixelSize: try PixelSize(width: UInt32(width), height: UInt32(height)),
            durationSeconds: duration,
            nominalFrameRate: frameRate,
            hasAudio: hasAudio,
            isHDR: isHDR,
            videoCodec: codec
        )
    }

    public func sha256(of url: URL) throws -> ContentDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return try ContentDigest(algorithm: .sha256, value: value)
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
