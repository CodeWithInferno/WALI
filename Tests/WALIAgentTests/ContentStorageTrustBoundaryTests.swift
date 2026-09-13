import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Darwin
import WALIEngine
import XCTest
#if !WALI_APP_STORE
import WALILockScreenWire
#endif
@testable import WALIAgentRuntime

final class ContentStorageTrustBoundaryTests: XCTestCase {
    func testAgentAcceptsExistingFourKVideoPoster() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAgentPoster(to: url, width: 3_840, height: 2_160)
        let media = try await ContentStorage.verifyMedia(at: url, kind: .heicImage)
        XCTAssertEqual(media.pixelSize.width, 3_840)
        XCTAssertEqual(media.pixelSize.height, 2_160)
        XCTAssertNil(media.durationSeconds)
    }

    func testOversizedVideoPosterIsRejectedBeforeRasterDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAgentPoster(to: url, width: 8_192, height: 4_096)
        var decodeAttempted = false
        XCTAssertThrowsError(try ContentStorage.verifyHEICImage(at: url) { _ in
            decodeAttempted = true
            return nil
        }) { error in
            XCTAssertEqual(error as? StorageError, .unsupportedMedia)
        }
        XCTAssertFalse(decodeAttempted, "Pixel bounds must reject the header before ImageIO raster allocation")
    }

    func testAgentRejectsUntrustedMalformedMain10Metadata() {
        let valid = makeAgentMain10Configuration()
        XCTAssertTrue(ContentStorage.isAerialMain10(
            configuration: valid,
            bitsPerComponent: nil
        ))
        XCTAssertTrue(ContentStorage.isAerialMain10(
            configuration: valid,
            bitsPerComponent: 10
        ))

        XCTAssertFalse(ContentStorage.isAerialMain10(
            configuration: Data(valid.prefix(22)),
            bitsPerComponent: nil
        ))

        var malformed = valid
        malformed[26] = 0xff
        XCTAssertFalse(ContentStorage.isAerialMain10(
            configuration: malformed,
            bitsPerComponent: nil
        ))

        var wrongVersion = valid
        wrongVersion[0] = 2
        XCTAssertFalse(ContentStorage.isAerialMain10(
            configuration: wrongVersion,
            bitsPerComponent: nil
        ))

        var wrongProfile = valid
        wrongProfile[1] = 1
        XCTAssertFalse(ContentStorage.isAerialMain10(
            configuration: wrongProfile,
            bitsPerComponent: nil
        ))

        for index in [17, 18] {
            var mismatchedComponent = valid
            mismatchedComponent[index] = 0xf9
            XCTAssertFalse(ContentStorage.isAerialMain10(
                configuration: mismatchedComponent,
                bitsPerComponent: nil
            ))
        }

        XCTAssertFalse(ContentStorage.isAerialMain10(
            configuration: valid,
            bitsPerComponent: 8
        ))
    }

    func testLegacyCommittedRecordRetainsPersistedBitDepth() throws {
        let itemID = UUID()
        let storedArtifacts = try [
            decodeStoredArtifact(
                role: "master_video",
                mediaKind: "hevc_video",
                digestCharacter: "a",
                byteCount: 3,
                fileName: "master.mov",
                durationSeconds: 3
            ),
            decodeStoredArtifact(
                role: "preview_video",
                mediaKind: "hevc_video",
                digestCharacter: "b",
                byteCount: 2,
                fileName: "preview.mov",
                durationSeconds: 3
            ),
            decodeStoredArtifact(
                role: "poster_image",
                mediaKind: "heic_image",
                digestCharacter: "c",
                byteCount: 1,
                fileName: "poster.heic",
                durationSeconds: nil
            ),
        ]
        let record = try LibraryRecordFactory.makeRecord(
            itemID: itemID,
            displayName: "Legacy",
            sourceFileName: "legacy.mov",
            sourceDigest: storedArtifacts[0].digest,
            artifacts: storedArtifacts
        )
        let encoded = try JSONEncoder().encode(record)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var release = try XCTUnwrap(root["release"] as? [String: Any])
        var artifacts = try XCTUnwrap(release["artifacts"] as? [[String: Any]])
        for index in artifacts.indices {
            var characteristics = try XCTUnwrap(
                artifacts[index]["characteristics"] as? [String: Any]
            )
            if characteristics["bitDepth"] != nil {
                characteristics["bitDepth"] = 8
                artifacts[index]["characteristics"] = characteristics
            }
        }
        release["artifacts"] = artifacts
        root["release"] = release

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(CommittedLibraryRecord.self, from: legacyData)
        XCTAssertEqual(
            decoded.release.artifacts.compactMap { $0.characteristics.bitDepth },
            [8, 8]
        )
        #if !WALI_APP_STORE
        let engineItem = try LibraryRecordFactory.makeEngineItem(from: decoded)
        let displayID = UUID()
        let assignments = WALIAgentController.lockScreenAssignments(
            from: EngineSnapshot(
                items: [engineItem],
                displays: [.init(
                    id: "uuid:\(displayID.uuidString)",
                    name: "Main",
                    pixelWidth: 1_920,
                    pixelHeight: 1_080,
                    isMain: true,
                    assignedItemID: itemID
                )]
            ),
            durable: RuntimeSnapshot(library: [decoded])
        )
        XCTAssertEqual(assignments.first?.masterBitDepth, 8)
        XCTAssertEqual(
            assignments.first?.masterArtifactSHA256,
            decoded.artifacts.first(where: { $0.role == .masterVideo })?.digest.value
        )
        XCTAssertEqual(
            assignments.first?.posterArtifactSHA256,
            decoded.artifacts.first(where: { $0.role == .posterImage })?.digest.value
        )
        #endif
    }

    func testAgentVerificationRejectsClaimedHEVCWithUntrustedTrackLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wali-agent-media-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for videoTrackCount in [1, 2] {
            let url = root.appendingPathComponent("untrusted-\(videoTrackCount).mov")
            try await makeH264Video(at: url, videoTrackCount: videoTrackCount)
            do {
                _ = try await ContentStorage.verifyMedia(at: url, kind: .hevcVideo)
                XCTFail("An untrusted HEVC claim must not bypass byte verification")
            } catch let error as StorageError {
                XCTAssertEqual(error, .unsupportedMedia)
            }
        }
    }

    private func makeH264Video(at url: URL, videoTrackCount: Int) async throws {
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

        for index in 0..<2 {
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
                    memset(address, Int32(index), CVPixelBufferGetDataSize(pixelBuffer))
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                XCTAssertTrue(adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTime(value: Int64(index), timescale: 2)
                ))
            }
        }
        inputs.forEach { $0.0.markAsFinished() }
        await writer.finishWriting()
        XCTAssertEqual(
            writer.status,
            .completed,
            writer.error?.localizedDescription ?? "Synthetic video encode failed"
        )
    }

    func testAgentRequiresExactSDRBT709ColorMetadata() {
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        XCTAssertTrue(ContentStorage.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(ContentStorage.isAerialSDRBT709(
            colorPrimaries: nil,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(ContentStorage.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ))
        XCTAssertFalse(ContentStorage.isAerialSDRBT709(
            colorPrimaries: bt709,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        ))
    }

    private func decodeStoredArtifact(
        role: String,
        mediaKind: String,
        digestCharacter: String,
        byteCount: UInt64,
        fileName: String,
        durationSeconds: Double?
    ) throws -> StoredArtifact {
        var object: [String: Any] = [
            "role": role,
            "mediaKind": mediaKind,
            "digest": [
                "algorithm": "sha256",
                "value": String(repeating: digestCharacter, count: 64),
            ],
            "byteCount": byteCount,
            "objectURL": URL(fileURLWithPath: "/tmp/\(fileName)").absoluteString,
            "pixelSize": ["width": 1_920, "height": 1_080],
        ]
        if let durationSeconds { object["durationSeconds"] = durationSeconds }
        return try JSONDecoder().decode(
            StoredArtifact.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

private func makeAgentMain10Configuration() -> Data {
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

private func writeAgentPoster(to url: URL, width: Int, height: Int) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
