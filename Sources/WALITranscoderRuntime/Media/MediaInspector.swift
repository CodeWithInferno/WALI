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
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
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
        let codecs = Set(formatDescriptions.map {
            Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))
        })
        let codec = codecs.count == 1 ? codecs.first ?? "unknown" : "unknown"
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let isHDR = formatDescriptions.contains { description in
            guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
            else { return false }
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        }
        let isMain10 = !formatDescriptions.isEmpty
            && formatDescriptions.allSatisfy(Self.isAerialMain10)

        return MediaInspection(
            byteCount: byteCount,
            pixelSize: try PixelSize(width: UInt32(width), height: UInt32(height)),
            durationSeconds: duration,
            nominalFrameRate: frameRate,
            hasAudio: hasAudio,
            isHDR: isHDR,
            videoCodec: codec,
            bitDepth: isMain10 ? 10 : nil,
            hevcProfileIDC: isMain10 ? 2 : nil
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
}
