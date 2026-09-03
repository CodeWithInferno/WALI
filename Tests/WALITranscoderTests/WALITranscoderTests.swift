import AVFoundation
import CoreVideo
import XCTest
@testable import WALITranscoderRuntime

final class WALITranscoderTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnXPCServiceHost() {
        XCTAssertEqual(
            String(describing: WALITranscoderServiceRunner.self),
            "WALITranscoderServiceRunner"
        )
    }

    func testMasterExportPreservesHighFrameRateUpToSixty() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("source-120fps.mov")
        try await makeSourceVideo(at: sourceURL, timescale: 120, frameCount: 120)
        let outputURL = root.appendingPathComponent("master.mov")
        try await MediaTranscoder().exportVideo(
            sourceURL: sourceURL,
            outputURL: outputURL,
            preview: false,
            phase: .transcodingMaster,
            progress: { _ in }
        )

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = Double(try await track.load(.nominalFrameRate))
        XCTAssertEqual(frameRate, 60, accuracy: 0.6)
    }

    func testExportsAerialCompatibleMain10VideoForMasterAndPreview() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("source.mov")
        try await makeSourceVideo(at: sourceURL)

        for preview in [false, true] {
            let outputURL = root.appendingPathComponent(preview ? "preview.mov" : "master.mov")
            try await MediaTranscoder().exportVideo(
                sourceURL: sourceURL,
                outputURL: outputURL,
                preview: preview,
                phase: preview ? .transcodingPreview : .transcodingMaster,
                progress: { _ in }
            )

            let characteristics = try await encodedCharacteristics(at: outputURL)
            let claim = try await MediaTranscoder().videoClaim(
                kind: preview ? .previewVideo : .masterVideo,
                url: outputURL
            )
            XCTAssertEqual(characteristics.bitDepth, 10, "Expected Main10 output at \(outputURL.lastPathComponent)")
            XCTAssertEqual(claim.inspection?.bitDepth, 10)
            XCTAssertEqual(characteristics.hevcProfileIDC, 2)
            XCTAssertEqual(claim.inspection?.hevcProfileIDC, 2)
            XCTAssertEqual(
                characteristics.colorPrimaries,
                kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            )
            XCTAssertEqual(
                characteristics.transferFunction,
                kCVImageBufferTransferFunction_ITU_R_709_2 as String
            )
            XCTAssertEqual(
                characteristics.yCbCrMatrix,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
            )
            XCTAssertFalse(claim.inspection?.isHDR ?? true)
            XCTAssertFalse(
                characteristics.hasFrameReordering,
                "Expected no B-frame reordering at \(outputURL.lastPathComponent)"
            )
            XCTAssertGreaterThanOrEqual(characteristics.keyFrameTimes.count, 2)
            for interval in zip(
                characteristics.keyFrameTimes.dropFirst(),
                characteristics.keyFrameTimes
            ).map({ $0.0 - $0.1 }) {
                XCTAssertLessThanOrEqual(interval, 1.05)
            }
        }
    }

    func testMain10ConfigurationParserRejectsMalformedMetadata() {
        let valid = makeMain10Configuration()
        XCTAssertTrue(MediaInspector.isAerialMain10(
            configuration: valid,
            bitsPerComponent: nil
        ))
        XCTAssertTrue(MediaInspector.isAerialMain10(
            configuration: valid,
            bitsPerComponent: 10
        ))

        XCTAssertFalse(MediaInspector.isAerialMain10(
            configuration: Data(valid.prefix(22)),
            bitsPerComponent: nil
        ))

        var malformed = valid
        malformed[26] = 0xff
        XCTAssertFalse(MediaInspector.isAerialMain10(
            configuration: malformed,
            bitsPerComponent: nil
        ))

        var wrongVersion = valid
        wrongVersion[0] = 2
        XCTAssertFalse(MediaInspector.isAerialMain10(
            configuration: wrongVersion,
            bitsPerComponent: nil
        ))

        var wrongProfile = valid
        wrongProfile[1] = 1
        XCTAssertFalse(MediaInspector.isAerialMain10(
            configuration: wrongProfile,
            bitsPerComponent: nil
        ))

        for index in [17, 18] {
            var mismatchedComponent = valid
            mismatchedComponent[index] = 0xf9
            XCTAssertFalse(MediaInspector.isAerialMain10(
                configuration: mismatchedComponent,
                bitsPerComponent: nil
            ))
        }

        XCTAssertFalse(MediaInspector.isAerialMain10(
            configuration: valid,
            bitsPerComponent: 8
        ))
    }

    func testInspectorRejectsMultipleVideoTracks() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("multiple-video-tracks.mov")
        try await makeSourceVideo(at: sourceURL, videoTrackCount: 2)

        do {
            _ = try await MediaInspector().inspectVideo(at: sourceURL)
            XCTFail("Assets with multiple video tracks must be rejected")
        } catch let error as MediaPipelineError {
            XCTAssertEqual(error, .missingVideoTrack)
        }
    }

    func testAerialColorMetadataRequiresExactSDRBT709Triplet() {
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        XCTAssertTrue(MediaInspector.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(MediaInspector.isAerialSDRBT709(
            colorPrimaries: nil,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(MediaInspector.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(MediaInspector.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        ))
    }

    private func makeSourceVideo(
        at url: URL,
        videoTrackCount: Int = 1,
        timescale: CMTimeScale = 4,
        frameCount: Int = 12
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let inputs = (0..<videoTrackCount).map { _ in
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 64,
                    AVVideoHeightKey: 64,
                ]
            )
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 64,
                    kCVPixelBufferHeightKey as String: 64,
                ]
            )
            XCTAssertTrue(writer.canAdd(input))
            writer.add(input)
            return (input, adaptor)
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            for (input, adaptor) in inputs {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(1))
                }
                let pool = try XCTUnwrap(adaptor.pixelBufferPool)
                var buffer: CVPixelBuffer?
                XCTAssertEqual(
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer),
                    kCVReturnSuccess
                )
                let pixelBuffer = try XCTUnwrap(buffer)
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    memset(address, Int32(index * 12), CVPixelBufferGetDataSize(pixelBuffer))
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                XCTAssertTrue(adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTime(value: Int64(index), timescale: timescale)
                ))
            }
        }

        inputs.forEach { input, _ in input.markAsFinished() }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Source encode failed")
    }

    private func encodedCharacteristics(at url: URL) async throws -> EncodedCharacteristics {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(description)) as NSDictionary
        let bitDepth = (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
        let atoms = try XCTUnwrap(
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data]
        )
        let configuration = try XCTUnwrap(atoms["hvcC"])
        let hevcProfileIDC = configuration[1] & 0x1f
        let colorPrimaries = extensions[
            kCMFormatDescriptionExtension_ColorPrimaries
        ] as? String
        let transferFunction = extensions[
            kCMFormatDescriptionExtension_TransferFunction
        ] as? String
        let yCbCrMatrix = extensions[
            kCMFormatDescriptionExtension_YCbCrMatrix
        ] as? String

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var hasFrameReordering = false
        var keyFrameTimes: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
            guard presentationTime.isNumeric else { continue }
            if decodeTime.isNumeric, presentationTime != decodeTime {
                hasFrameReordering = true
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !isNotSync {
                keyFrameTimes.append(presentationTime.seconds)
            }
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Output read failed")
        return EncodedCharacteristics(
            bitDepth: bitDepth,
            hevcProfileIDC: hevcProfileIDC,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            hasFrameReordering: hasFrameReordering,
            keyFrameTimes: keyFrameTimes
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wali-transcoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private func makeMain10Configuration() -> Data {
    var configuration = Data(repeating: 0, count: 30)
    configuration[0] = 1
    configuration[1] = 2
    configuration[13] = 0xf0
    configuration[15] = 0xfc
    configuration[16] = 0xfd
    configuration[17] = 0xfa
    configuration[18] = 0xfa
    configuration[21] = 0x03
    configuration[22] = 1
    configuration[23] = 0xa0
    configuration[25] = 1
    configuration[27] = 2
    configuration[28] = 1
    configuration[29] = 2
    return configuration
}

private struct EncodedCharacteristics {
    let bitDepth: Int?
    let hevcProfileIDC: UInt8
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let hasFrameReordering: Bool
    let keyFrameTimes: [Double]
}
