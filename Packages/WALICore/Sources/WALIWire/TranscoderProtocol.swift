import Foundation
import WALIModel

/// One durable, generation-scoped media conversion request from the agent.
public struct TranscoderRequest: Codable, Sendable, Hashable {
    public static let maximumSourceByteCount: UInt64 = 20 * 1_024 * 1_024 * 1_024
    public static let maximumSourceBookmarkBytes = 1_024 * 1_024
    public static let maximumStillSourceByteCount: UInt64 = 128 * 1_024 * 1_024

    public let protocolVersion: UInt16
    public let jobID: UUID
    public let attemptGeneration: UInt64
    public let sourceURL: URL
    public let sourceBookmark: Data
    public let stagingDirectoryURL: URL
    public let sourceByteLimit: UInt64
    public let mediaKind: WallpaperMediaKind

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptGeneration, sourceURL, sourceBookmark
        case stagingDirectoryURL, sourceByteLimit
        case mediaKind = "media_kind"
    }

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        jobID: UUID,
        attemptGeneration: UInt64,
        sourceBookmark: Data,
        sourceURL: URL,
        stagingDirectoryURL: URL,
        sourceByteLimit: UInt64? = nil,
        mediaKind: WallpaperMediaKind = .video
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptGeneration = attemptGeneration
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.stagingDirectoryURL = stagingDirectoryURL
        self.sourceByteLimit = sourceByteLimit ?? (mediaKind == .still
            ? Self.maximumStillSourceByteCount : Self.maximumSourceByteCount)
        self.mediaKind = mediaKind
    }
}

public enum TranscoderArtifactKind: String, Codable, Sendable, Hashable, CaseIterable {
    case masterVideo = "master_video"
    case previewVideo = "preview_video"
    case posterImage = "poster_image"
    case masterImage = "master_image"

    public static func required(for mediaKind: WallpaperMediaKind) -> Set<Self> {
        mediaKind == .video ? [.masterVideo, .previewVideo, .posterImage] : [.masterImage, .posterImage]
    }
}

/// Worker-derived media facts. The agent treats every value as an untrusted claim.
public struct TranscoderVideoMediaClaim: Codable, Sendable, Hashable {
    public let byteCount: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let duration: TimeInterval
    public let nominalFrameRate: Double
    public let hasAudio: Bool
    public let isHDR: Bool
    public let videoCodec: String

    public init(
        byteCount: UInt64,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        duration: TimeInterval,
        nominalFrameRate: Double,
        hasAudio: Bool,
        isHDR: Bool,
        videoCodec: String
    ) {
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.isHDR = isHDR
        self.videoCodec = videoCodec
    }
}

/// Image facts have no motion or audio fields. Source color/alpha facts remain
/// truthful; canonical artifact policy is checked separately at the boundary.
public struct TranscoderStillMediaClaim: Codable, Sendable, Hashable {
    public let byteCount: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let frameCount: UInt32
    public let bitsPerComponent: UInt16
    public let colorSpace: String
    public let hasAlpha: Bool

    public init(byteCount: UInt64, pixelWidth: UInt32, pixelHeight: UInt32,
                frameCount: UInt32, bitsPerComponent: UInt16, colorSpace: String, hasAlpha: Bool) {
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.bitsPerComponent = bitsPerComponent
        self.colorSpace = colorSpace
        self.hasAlpha = hasAlpha
    }
}

/// Strict tagged facts on the private worker wire; cross-kind fields reject.
public enum TranscoderMediaClaim: Codable, Sendable, Hashable {
    case video(TranscoderVideoMediaClaim)
    case still(TranscoderStillMediaClaim)

    public var mediaKind: WallpaperMediaKind {
        switch self { case .video: .video; case .still: .still }
    }
    public var byteCount: UInt64 {
        switch self { case .video(let value): value.byteCount; case .still(let value): value.byteCount }
    }
    public var pixelWidth: UInt32 {
        switch self { case .video(let value): value.pixelWidth; case .still(let value): value.pixelWidth }
    }
    public var pixelHeight: UInt32 {
        switch self { case .video(let value): value.pixelHeight; case .still(let value): value.pixelHeight }
    }

    public init(byteCount: UInt64, pixelWidth: UInt32, pixelHeight: UInt32,
                duration: TimeInterval, nominalFrameRate: Double, hasAudio: Bool,
                isHDR: Bool, videoCodec: String) {
        self = .video(.init(byteCount: byteCount, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            duration: duration, nominalFrameRate: nominalFrameRate, hasAudio: hasAudio,
            isHDR: isHDR, videoCodec: videoCodec))
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let kind = try values.decode(WallpaperMediaKind.self, forKey: Key("kind"))
        let common: Set<String> = ["kind", "byte_count", "pixel_width", "pixel_height"]
        let expected = kind == .video
            ? common.union(["duration_seconds", "nominal_frame_rate", "has_audio", "is_hdr", "codec"])
            : common.union(["frame_count", "bits_per_component", "color_space", "has_alpha"])
        guard Set(values.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unexpected fields for the declared media kind."))
        }
        let bytes = try values.decode(UInt64.self, forKey: Key("byte_count"))
        let width = try values.decode(UInt32.self, forKey: Key("pixel_width"))
        let height = try values.decode(UInt32.self, forKey: Key("pixel_height"))
        switch kind {
        case .video:
            self = .video(.init(byteCount: bytes, pixelWidth: width, pixelHeight: height,
                duration: try values.decode(Double.self, forKey: Key("duration_seconds")),
                nominalFrameRate: try values.decode(Double.self, forKey: Key("nominal_frame_rate")),
                hasAudio: try values.decode(Bool.self, forKey: Key("has_audio")),
                isHDR: try values.decode(Bool.self, forKey: Key("is_hdr")),
                videoCodec: try values.decode(String.self, forKey: Key("codec"))))
        case .still:
            self = .still(.init(byteCount: bytes, pixelWidth: width, pixelHeight: height,
                frameCount: try values.decode(UInt32.self, forKey: Key("frame_count")),
                bitsPerComponent: try values.decode(UInt16.self, forKey: Key("bits_per_component")),
                colorSpace: try values.decode(String.self, forKey: Key("color_space")),
                hasAlpha: try values.decode(Bool.self, forKey: Key("has_alpha"))))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(mediaKind, forKey: Key("kind"))
        try values.encode(byteCount, forKey: Key("byte_count"))
        try values.encode(pixelWidth, forKey: Key("pixel_width"))
        try values.encode(pixelHeight, forKey: Key("pixel_height"))
        switch self {
        case .video(let value):
            try values.encode(value.duration, forKey: Key("duration_seconds"))
            try values.encode(value.nominalFrameRate, forKey: Key("nominal_frame_rate"))
            try values.encode(value.hasAudio, forKey: Key("has_audio"))
            try values.encode(value.isHDR, forKey: Key("is_hdr"))
            try values.encode(value.videoCodec, forKey: Key("codec"))
        case .still(let value):
            try values.encode(value.frameCount, forKey: Key("frame_count"))
            try values.encode(value.bitsPerComponent, forKey: Key("bits_per_component"))
            try values.encode(value.colorSpace, forKey: Key("color_space"))
            try values.encode(value.hasAlpha, forKey: Key("has_alpha"))
        }
    }
}

/// One immutable worker artifact claim; agent-side installation must verify it.
public struct TranscoderArtifactClaim: Codable, Sendable, Hashable {
    public let kind: TranscoderArtifactKind
    public let stagedURL: URL
    public let digest: String
    public let byteCount: UInt64
    public let media: TranscoderMediaClaim?

    public init(
        kind: TranscoderArtifactKind,
        stagedURL: URL,
        digest: String,
        byteCount: UInt64,
        media: TranscoderMediaClaim?
    ) {
        self.kind = kind
        self.stagedURL = stagedURL
        self.digest = digest
        self.byteCount = byteCount
        self.media = media
    }
}

public struct TranscoderOutput: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let jobID: UUID
    public let attemptGeneration: UInt64
    public let displayName: String
    public let completedAt: Date
    public let sourceDigest: String
    public let sourceMedia: TranscoderMediaClaim
    public let artifacts: [TranscoderArtifactClaim]
    public let mediaKind: WallpaperMediaKind

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, jobID, attemptGeneration, displayName, completedAt
        case sourceDigest, sourceMedia, artifacts
        case mediaKind = "media_kind"
    }

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        jobID: UUID,
        attemptGeneration: UInt64,
        displayName: String,
        completedAt: Date,
        sourceDigest: String,
        sourceMedia: TranscoderMediaClaim,
        artifacts: [TranscoderArtifactClaim]
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptGeneration = attemptGeneration
        self.displayName = displayName
        self.completedAt = completedAt
        self.sourceDigest = sourceDigest
        self.sourceMedia = sourceMedia
        self.artifacts = artifacts
        mediaKind = sourceMedia.mediaKind
    }
}

public enum TranscoderProgressPhase: String, Codable, Sendable, Hashable {
    case queued
    case inspecting
    case hashingSource = "hashing_source"
    case transcodingMaster = "transcoding_master"
    case transcodingPreview = "transcoding_preview"
    case generatingPoster = "generating_poster"
    case verifyingOutputs = "verifying_outputs"
    case complete
}

/// Latest phase-local progress for one exact worker attempt.
public struct TranscoderProgress: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let jobID: UUID
    public let attemptGeneration: UInt64
    public let phase: TranscoderProgressPhase
    public let fractionCompleted: Double

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        jobID: UUID,
        attemptGeneration: UInt64,
        phase: TranscoderProgressPhase,
        fractionCompleted: Double
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptGeneration = attemptGeneration
        self.phase = phase
        self.fractionCompleted = fractionCompleted
    }
}

public enum TranscoderWireError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidOutput
    case incompatibleProtocol(received: UInt16, supported: UInt16)
}

extension TranscoderWireError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The transcoder request is invalid."
        case .invalidOutput: "The transcoder response is invalid."
        case let .incompatibleProtocol(received, supported):
            "Transcoder protocol \(received) is incompatible with \(supported)."
        }
    }
}

/// Size-checked serialization for the private agent-to-worker channel.
public enum TranscoderWireCodec {
    public static func encodeRequest(_ request: TranscoderRequest) throws -> Data {
        try validate(request)
        return try WireCodec.encode(request)
    }

    public static func decodeRequest(from data: Data) throws -> TranscoderRequest {
        guard data.count <= WALIProtocol.maximumMessageBytes else {
            throw WireCodecError.messageTooLarge(
                actual: data.count,
                maximum: WALIProtocol.maximumMessageBytes
            )
        }
        let request = try WireCodec.decode(TranscoderRequest.self, from: data)
        try validate(request)
        return request
    }

    public static func encodeOutput(_ output: TranscoderOutput) throws -> Data {
        try validate(output)
        return try WireCodec.encode(output)
    }

    public static func decodeOutput(from data: Data) throws -> TranscoderOutput {
        guard data.count <= WALIProtocol.maximumMessageBytes else {
            throw WireCodecError.messageTooLarge(
                actual: data.count,
                maximum: WALIProtocol.maximumMessageBytes
            )
        }
        let output = try WireCodec.decode(TranscoderOutput.self, from: data)
        try validate(output)
        return output
    }

    public static func encodeProgress(_ progress: TranscoderProgress) throws -> Data {
        try validate(progress)
        return try WireCodec.encode(progress)
    }

    public static func decodeProgress(from data: Data) throws -> TranscoderProgress {
        guard data.count <= WALIProtocol.maximumMessageBytes else {
            throw WireCodecError.messageTooLarge(
                actual: data.count,
                maximum: WALIProtocol.maximumMessageBytes
            )
        }
        let progress = try WireCodec.decode(TranscoderProgress.self, from: data)
        try validate(progress)
        return progress
    }

    private static func validate(_ request: TranscoderRequest) throws {
        guard request.protocolVersion == WALIProtocol.currentVersion else {
            throw TranscoderWireError.incompatibleProtocol(
                received: request.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        guard request.attemptGeneration > 0,
              request.sourceURL.isFileURL,
              request.stagingDirectoryURL.isFileURL,
              request.sourceURL.path.utf8.count <= 4_096,
              request.stagingDirectoryURL.path.utf8.count <= 4_096,
              request.sourceURL.standardizedFileURL != request.stagingDirectoryURL.standardizedFileURL,
              !request.sourceBookmark.isEmpty,
              request.sourceBookmark.count <= TranscoderRequest.maximumSourceBookmarkBytes,
              request.sourceByteLimit > 0,
              request.sourceByteLimit <= (request.mediaKind == .still
                ? TranscoderRequest.maximumStillSourceByteCount : TranscoderRequest.maximumSourceByteCount)
        else {
            throw TranscoderWireError.invalidRequest
        }
    }

    private static func validate(_ output: TranscoderOutput) throws {
        guard output.protocolVersion == WALIProtocol.currentVersion else {
            throw TranscoderWireError.incompatibleProtocol(
                received: output.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        guard output.attemptGeneration > 0,
              !output.displayName.isEmpty,
              output.displayName.utf8.count <= 480,
              isDigest(output.sourceDigest),
              output.sourceMedia.mediaKind == output.mediaKind,
              output.artifacts.count == TranscoderArtifactKind.required(for: output.mediaKind).count,
              Set(output.artifacts.map(\.kind)) == TranscoderArtifactKind.required(for: output.mediaKind),
              output.artifacts.allSatisfy({ claim in
                  claim.stagedURL.isFileURL &&
                      claim.stagedURL.path.utf8.count <= 4_096 &&
                      claim.byteCount > 0 &&
                      isDigest(claim.digest)
              }),
              valid(output.sourceMedia)
        else {
            throw TranscoderWireError.invalidOutput
        }
        for claim in output.artifacts {
            if output.mediaKind == .video && claim.kind == .posterImage {
                guard claim.media == nil else { throw TranscoderWireError.invalidOutput }
            } else {
                guard let media = claim.media, media.mediaKind == output.mediaKind,
                      media.byteCount == claim.byteCount, valid(media) else {
                    throw TranscoderWireError.invalidOutput
                }
                switch media {
                case .video(let value):
                    guard !value.hasAudio else { throw TranscoderWireError.invalidOutput }
                case .still(let value):
                    guard value.bitsPerComponent == 8, value.colorSpace == "srgb", !value.hasAlpha,
                          claim.kind != .posterImage || max(value.pixelWidth, value.pixelHeight) <= 1_920
                    else { throw TranscoderWireError.invalidOutput }
                }
            }
        }
    }

    private static func validate(_ progress: TranscoderProgress) throws {
        guard progress.protocolVersion == WALIProtocol.currentVersion else {
            throw TranscoderWireError.incompatibleProtocol(
                received: progress.protocolVersion,
                supported: WALIProtocol.currentVersion
            )
        }
        guard progress.attemptGeneration > 0,
              progress.fractionCompleted.isFinite,
              (0...1).contains(progress.fractionCompleted) else {
            throw TranscoderWireError.invalidOutput
        }
    }

    private static func valid(_ media: TranscoderMediaClaim) -> Bool {
        guard media.byteCount > 0, media.pixelWidth > 0, media.pixelHeight > 0 else { return false }
        switch media {
        case .video(let value):
            return value.pixelWidth <= 16_384 && value.pixelHeight <= 16_384 &&
                value.duration.isFinite && value.duration > 0 && value.duration <= 86_400 &&
                value.nominalFrameRate.isFinite && value.nominalFrameRate >= 0 && value.nominalFrameRate <= 240 &&
                !value.videoCodec.isEmpty && value.videoCodec.utf8.count <= 32
        case .still(let value):
            return value.byteCount <= TranscoderRequest.maximumStillSourceByteCount &&
                value.pixelWidth <= 7_680 && value.pixelHeight <= 7_680 &&
                UInt64(value.pixelWidth) * UInt64(value.pixelHeight) <= 33_177_600 &&
                value.frameCount == 1 && (1...8).contains(value.bitsPerComponent) &&
                !value.colorSpace.isEmpty && value.colorSpace.utf8.count <= 128
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

@objc public protocol WALITranscoderXPCProtocol {
    func transcode(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func progress(
        _ jobID: UUID,
        attemptGeneration: UInt64,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func cancel(
        _ jobID: UUID,
        attemptGeneration: UInt64,
        withReply reply: @escaping (NSError?) -> Void
    )
}
