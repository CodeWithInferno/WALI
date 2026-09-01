import Foundation

/// One durable, generation-scoped media conversion request from the agent.
public struct TranscoderRequest: Codable, Sendable, Hashable {
    public static let maximumSourceByteCount: UInt64 = 20 * 1_024 * 1_024 * 1_024
    public static let maximumSourceBookmarkBytes = 1_024 * 1_024

    public let protocolVersion: UInt16
    public let jobID: UUID
    public let attemptGeneration: UInt64
    public let sourceURL: URL
    public let sourceBookmark: Data
    public let stagingDirectoryURL: URL
    public let sourceByteLimit: UInt64

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        jobID: UUID,
        attemptGeneration: UInt64,
        sourceBookmark: Data,
        sourceURL: URL,
        stagingDirectoryURL: URL,
        sourceByteLimit: UInt64 = Self.maximumSourceByteCount
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.attemptGeneration = attemptGeneration
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.stagingDirectoryURL = stagingDirectoryURL
        self.sourceByteLimit = sourceByteLimit
    }
}

public enum TranscoderArtifactKind: String, Codable, Sendable, Hashable, CaseIterable {
    case masterVideo = "master_video"
    case previewVideo = "preview_video"
    case posterImage = "poster_image"
}

/// Worker-derived media facts. The agent treats every value as an untrusted claim.
public struct TranscoderMediaClaim: Codable, Sendable, Hashable {
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
              request.sourceByteLimit <= TranscoderRequest.maximumSourceByteCount
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
              output.artifacts.count == TranscoderArtifactKind.allCases.count,
              Set(output.artifacts.map(\.kind)) == Set(TranscoderArtifactKind.allCases),
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
            if claim.kind == .posterImage {
                guard claim.media == nil else { throw TranscoderWireError.invalidOutput }
            } else {
                guard let media = claim.media, valid(media), !media.hasAudio else {
                    throw TranscoderWireError.invalidOutput
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
        media.byteCount > 0 &&
            media.pixelWidth > 0 && media.pixelWidth <= 16_384 &&
            media.pixelHeight > 0 && media.pixelHeight <= 16_384 &&
            media.duration.isFinite && media.duration > 0 && media.duration <= 86_400 &&
            media.nominalFrameRate.isFinite &&
            media.nominalFrameRate >= 0 && media.nominalFrameRate <= 240 &&
            !media.videoCodec.isEmpty && media.videoCodec.utf8.count <= 32
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
