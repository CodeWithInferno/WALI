import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import WALIModel

public enum MediaPipelinePhase: String, Codable, Sendable, Hashable {
    case inspecting
    case hashingSource = "hashing_source"
    case transcodingMaster = "transcoding_master"
    case transcodingPreview = "transcoding_preview"
    case generatingPoster = "generating_poster"
    case verifyingOutputs = "verifying_outputs"
    case complete
}

/// Monotonic progress within one pipeline phase.
public struct MediaPipelineProgress: Codable, Sendable, Hashable {
    public let phase: MediaPipelinePhase
    public let fractionCompleted: Double

    public init(phase: MediaPipelinePhase, fractionCompleted: Double) {
        self.phase = phase
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }
}

/// Deterministic video-first conversion using Apple media frameworks.
public struct MediaTranscoder: Sendable {
    private let inspector = MediaInspector()

    public init() {}

    public func transcode(
        _ request: MediaTranscodeRequest,
        progress: @escaping @Sendable (MediaPipelineProgress) -> () = { _ in }
    ) async throws -> MediaTranscodeResult {
        try Task.checkCancellation()
        progress(.init(phase: .inspecting, fractionCompleted: 0))
        let sourceInspection = try await inspector.inspectVideo(
            at: request.sourceURL,
            byteLimit: request.sourceByteLimit
        )
        try requireAvailableStorage(
            for: sourceInspection,
            stagingDirectoryURL: request.stagingDirectoryURL
        )
        progress(.init(phase: .inspecting, fractionCompleted: 1))

        progress(.init(phase: .hashingSource, fractionCompleted: 0))
        let sourceDigest = try inspector.sha256(of: request.sourceURL)
        progress(.init(phase: .hashingSource, fractionCompleted: 1))

        let attemptDirectory = try makeAttemptDirectory(for: request)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: attemptDirectory)
            }
        }

        let masterURL = attemptDirectory.appendingPathComponent("master.mov", isDirectory: false)
        let previewURL = attemptDirectory.appendingPathComponent("preview.mov", isDirectory: false)
        let posterURL = attemptDirectory.appendingPathComponent("poster.heic", isDirectory: false)

        try await exportVideo(
            sourceURL: request.sourceURL,
            outputURL: masterURL,
            preview: false,
            phase: .transcodingMaster,
            progress: progress
        )
        try Task.checkCancellation()
        try await exportVideo(
            sourceURL: request.sourceURL,
            outputURL: previewURL,
            preview: true,
            phase: .transcodingPreview,
            progress: progress
        )
        try Task.checkCancellation()

        progress(.init(phase: .generatingPoster, fractionCompleted: 0))
        try await generatePoster(sourceURL: request.sourceURL, outputURL: posterURL)
        progress(.init(phase: .generatingPoster, fractionCompleted: 1))

        progress(.init(phase: .verifyingOutputs, fractionCompleted: 0))
        let masterClaim = try await videoClaim(kind: .masterVideo, url: masterURL)
        progress(.init(phase: .verifyingOutputs, fractionCompleted: 0.4))
        let previewClaim = try await videoClaim(kind: .previewVideo, url: previewURL)
        progress(.init(phase: .verifyingOutputs, fractionCompleted: 0.8))
        let posterClaim = try imageClaim(url: posterURL)
        progress(.init(phase: .verifyingOutputs, fractionCompleted: 1))

        let result = try MediaTranscodeResult(
            attempt: request.attempt,
            suggestedDisplayName: request.sourceURL.deletingPathExtension().lastPathComponent,
            sourceDigest: sourceDigest,
            sourceInspection: sourceInspection,
            claims: [masterClaim, previewClaim, posterClaim]
        )
        completed = true
        progress(.init(phase: .complete, fractionCompleted: 1))
        return result
    }

    private func requireAvailableStorage(
        for inspection: MediaInspection,
        stagingDirectoryURL: URL
    ) throws {
        // Master and preview are capped at 40 and 3 Mbps. Staged output and
        // the agent-owned verification copy coexist briefly during install.
        let estimatedOutput = inspection.durationSeconds * 43_000_000 / 8
        let workingSet = estimatedOutput * 2 + Double(512 * 1_024 * 1_024)
        guard workingSet.isFinite, workingSet > 0, workingSet < Double(UInt64.max) else {
            throw MediaPipelineError.insufficientStorage(requiredBytes: .max, availableBytes: 0)
        }
        let required = UInt64(workingSet.rounded(.up))
        let values = try stagingDirectoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        guard available >= required else {
            throw MediaPipelineError.insufficientStorage(
                requiredBytes: required,
                availableBytes: available
            )
        }
    }

    private func makeAttemptDirectory(for request: MediaTranscodeRequest) throws -> URL {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: request.stagingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try request.stagingDirectoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MediaPipelineError.cannotCreateStagingDirectory
            }
            let component = [
                request.attempt.jobID.rawValue,
                String(request.attempt.generation.rawValue),
                UUID().uuidString.lowercased(),
            ].joined(separator: "-")
            let result = request.stagingDirectoryURL.appendingPathComponent(component, isDirectory: true)
            try manager.createDirectory(
                at: result,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return result
        } catch let error as MediaPipelineError {
            throw error
        } catch {
            throw MediaPipelineError.cannotCreateStagingDirectory
        }
    }

    func exportVideo(
        sourceURL: URL,
        outputURL: URL,
        preview: Bool,
        phase: MediaPipelinePhase,
        progress: @escaping @Sendable (MediaPipelineProgress) -> ()
    ) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let duration = try await sourceAsset.load(.duration)
        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw MediaPipelineError.missingVideoTrack
        }
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let sourceTransform = try await sourceTrack.load(.preferredTransform)
        let frameRate = max(1, min(Double(try await sourceTrack.load(.nominalFrameRate)), 60))
        let plan = conversionPlan(
            naturalSize: naturalSize,
            sourceTransform: sourceTransform,
            frameRate: frameRate,
            preview: preview
        )
        let videoComposition = makeVideoComposition(
            track: sourceTrack,
            sourceTransform: sourceTransform,
            duration: duration,
            plan: plan
        )
        let reader = try AVAssetReader(asset: sourceAsset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ]
        )
        output.alwaysCopiesSampleData = false
        output.videoComposition = videoComposition
        guard reader.canAdd(output) else { throw MediaPipelineError.cannotCreateExporter }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.metadata = []
        writer.shouldOptimizeForNetworkUse = false
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(plan: plan)
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MediaPipelineError.unsupportedHEVCExport }
        writer.add(input)
        progress(.init(phase: phase, fractionCompleted: 0))

        let conversion = ReaderWriterBox(reader: reader, output: output, writer: writer, input: input)
        do {
            try await withTaskCancellationHandler {
                try await conversion.run(duration: duration) { fraction in
                    progress(.init(phase: phase, fractionCompleted: fraction))
                }
            } onCancel: {
                conversion.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaPipelineError.exportFailed(error.localizedDescription)
        }
        progress(.init(phase: phase, fractionCompleted: 1))
    }

    private struct ConversionPlan {
        let renderSize: CGSize
        let scale: CGFloat
        let sourceBounds: CGRect
        let frameRate: Double
        let bitRate: Int
    }

    private func conversionPlan(
        naturalSize: CGSize,
        sourceTransform: CGAffineTransform,
        frameRate: Double,
        preview: Bool
    ) -> ConversionPlan {
        let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(sourceTransform)
        let orientedSize = CGSize(width: abs(sourceBounds.width), height: abs(sourceBounds.height))
        let maximumEdge: CGFloat = preview ? 960 : 8_192
        let scale = min(1, maximumEdge / max(orientedSize.width, orientedSize.height))
        let width = max(2, floor(orientedSize.width * scale / 2) * 2)
        let height = max(2, floor(orientedSize.height * scale / 2) * 2)
        let pixelsPerSecond = width * height * frameRate
        let rawBitRate = Int(pixelsPerSecond * (preview ? 0.10 : 0.12))
        let bitRate = preview
            ? min(max(rawBitRate, 450_000), 3_000_000)
            : min(max(rawBitRate, 2_000_000), 120_000_000)
        return ConversionPlan(
            renderSize: CGSize(width: width, height: height),
            scale: scale,
            sourceBounds: sourceBounds,
            frameRate: frameRate,
            bitRate: bitRate
        )
    }

    private func makeVideoComposition(
        track: AVAssetTrack,
        sourceTransform: CGAffineTransform,
        duration: CMTime,
        plan: ConversionPlan
    ) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = plan.renderSize
        composition.frameDuration = CMTime(
            value: 1_000,
            timescale: CMTimeScale((plan.frameRate * 1_000).rounded())
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let normalize = CGAffineTransform(
            translationX: -plan.sourceBounds.minX,
            y: -plan.sourceBounds.minY
        )
        layer.setTransform(
            sourceTransform
                .concatenating(normalize)
                .concatenating(CGAffineTransform(scaleX: plan.scale, y: plan.scale)),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private func videoOutputSettings(plan: ConversionPlan) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(plan.renderSize.width),
            AVVideoHeightKey: Int(plan.renderSize.height),
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(plan.frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(plan.frameRate.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
        ]
    }

    private func generatePoster(sourceURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let (image, _) = try await generator.image(at: .zero)
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                throw MediaPipelineError.posterGenerationFailed("Unable to create HEIC output")
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw MediaPipelineError.posterGenerationFailed("ImageIO could not finalize HEIC")
            }
        } catch let error as MediaPipelineError {
            throw error
        } catch {
            throw MediaPipelineError.posterGenerationFailed(error.localizedDescription)
        }
    }

    func videoClaim(kind: MediaArtifactKind, url: URL) async throws -> MediaArtifactClaim {
        let inspection = try await inspector.inspectVideo(at: url)
        guard !inspection.hasAudio,
              !inspection.isHDR,
              inspection.videoCodec == "hvc1" || inspection.videoCodec == "hev1",
              inspection.bitDepth == 10,
              inspection.hevcProfileIDC == 2
        else {
            throw MediaPipelineError.outputVerificationFailed(kind)
        }
        return MediaArtifactClaim(
            kind: kind,
            stagedURL: url,
            digest: try inspector.sha256(of: url),
            byteCount: inspection.byteCount,
            inspection: inspection
        )
    }

    private func imageClaim(url: URL) throws -> MediaArtifactClaim {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .heic) == true,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw MediaPipelineError.outputVerificationFailed(.posterImage)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = UInt64(values.fileSize ?? 0)
        guard byteCount > 0 else {
            throw MediaPipelineError.outputVerificationFailed(.posterImage)
        }
        return MediaArtifactClaim(
            kind: .posterImage,
            stagedURL: url,
            digest: try inspector.sha256(of: url),
            byteCount: byteCount,
            inspection: nil
        )
    }
}

/// One task owns these AVFoundation objects; cancellation only invokes their
/// documented thread-safe cancellation operations from the task handler.
private final class ReaderWriterBox: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    func run(
        duration: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard writer.startWriting(), reader.startReading() else {
            throw MediaPipelineError.exportFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Unable to start"
            )
        }
        writer.startSession(atSourceTime: .zero)
        while reader.status == .reading {
            try Task.checkCancellation()
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard input.append(sample) else {
                throw MediaPipelineError.exportFailed(
                    writer.error?.localizedDescription ?? "Unable to append video frame"
                )
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time.isFinite, duration.seconds > 0 {
                progress(time / duration.seconds)
            }
        }
        guard reader.status == .completed else {
            throw MediaPipelineError.exportFailed(
                reader.error?.localizedDescription ?? "Unable to finish reading video"
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaPipelineError.exportFailed(
                writer.error?.localizedDescription ?? "Unable to finish writing video"
            )
        }
    }

    func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
    }
}
