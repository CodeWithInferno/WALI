import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WALITranscoderRuntime

final class StillMediaTranscoderTests: XCTestCase {
    func testPNGProducesOnlyOpaqueSRGBMasterAndBoundedPoster() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("original.png")
        try makeImage(at: input, type: .png, width: 12, height: 8, alpha: true)
        let original = try Data(contentsOf: input)
        let result = try await MediaTranscoder().transcode(request(input, root: root))
        XCTAssertEqual(Set(result.claims.map(\.kind)), [.masterImage, .posterImage])
        guard case .still(let source) = result.sourceInspection else { return XCTFail("Expected true still source facts") }
        XCTAssertTrue(source.hasAlpha)
        XCTAssertEqual(source.frameCount, 1)
        let master = try XCTUnwrap(result.claims.first { $0.kind == .masterImage })
        guard case .still(let prepared) = master.inspection else { return XCTFail("Expected typed image claim") }
        XCTAssertEqual(prepared.bitsPerComponent, 8)
        XCTAssertEqual(prepared.colorSpace, "srgb")
        XCTAssertFalse(prepared.hasAlpha)
        XCTAssertEqual(prepared.pixelSize.width, 12)
        XCTAssertEqual(prepared.pixelSize.height, 8)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(master.stagedURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.png.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
        let masterBytes = try Data(contentsOf: master.stagedURL)
        XCTAssertFalse(pngKinds(masterBytes).contains("eXIf"))
        XCTAssertFalse(pngKinds(masterBytes).contains("iTXt"))
        let poster = try XCTUnwrap(result.claims.first { $0.kind == .posterImage })
        let posterSource = try XCTUnwrap(CGImageSourceCreateWithURL(poster.stagedURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(posterSource) as String?, UTType.heic.identifier)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testUntaggedJPEGOrientationNormalizesWithoutUpscaling() async throws {
        for orientation in 1...8 {
            let root = try temporaryDirectory()
            let input = root.appendingPathComponent("oriented.jpg")
            try makeImage(at: input, type: .jpeg, width: 12, height: 8, alpha: false,
                orientation: orientation)
            try removingJPEGICC(try Data(contentsOf: input)).write(to: input)
            let result = try await MediaTranscoder().transcode(request(input, root: root))
            guard case .still(let source) = result.sourceInspection else { return XCTFail("Missing still source") }
            XCTAssertEqual(source.colorSpace, "srgb")
            let width: UInt32 = orientation >= 5 ? 8 : 12
            let height: UInt32 = orientation >= 5 ? 12 : 8
            XCTAssertEqual(source.pixelSize.width, width)
            XCTAssertEqual(source.pixelSize.height, height)
            for claim in result.claims {
                guard case .still(let value) = claim.inspection else { return XCTFail("Missing image facts") }
                XCTAssertEqual(value.colorSpace, "srgb")
                XCTAssertEqual(value.pixelSize.width, width)
                XCTAssertEqual(value.pixelSize.height, height)
            }
        }
    }

    func testEmbeddedICCAndConflictingGammaRequireSRGBConversion() async throws {
        let root = try temporaryDirectory()
        for type in [UTType.jpeg, .png] {
            let input = root.appendingPathComponent("profile.\(type.preferredFilenameExtension!)")
            try makeImage(at: input, type: type, width: 12, height: 8, alpha: false,
                spaceName: CGColorSpace.displayP3)
            do { _ = try await MediaTranscoder().transcode(request(input, root: root)); XCTFail("ICC input accepted") }
            catch let error as MediaPipelineError { XCTAssertEqual(error, .unsupportedStillImage) }
        }
        let png = root.appendingPathComponent("gamma.png")
        try makeImage(at: png, type: .png, width: 12, height: 8, alpha: false)
        let bytes = try Data(contentsOf: png)
        try (Data(bytes.prefix(33)) + chunk("gAMA", Data([0,0,39,16])) + bytes.dropFirst(33)).write(to: png)
        do { _ = try await MediaTranscoder().transcode(request(png, root: root)); XCTFail("Conflicting gamma accepted") }
        catch let error as MediaPipelineError { XCTAssertEqual(error, .unsupportedStillImage) }
    }

    func testCurrentAndLegacyHDRPNGChunksAreRejected() async throws {
        for marker in ["cICP", "mDCV", "cLLI", "mDCv", "cLLi"] {
            let root = try temporaryDirectory()
            let input = root.appendingPathComponent("hdr.png")
            try makeImage(at: input, type: .png, width: 12, height: 8, alpha: false)
            let bytes = try Data(contentsOf: input)
            try (Data(bytes.prefix(33)) + chunk(marker, Data(repeating: 0, count: 8)) + bytes.dropFirst(33)).write(to: input)
            do { _ = try await MediaTranscoder().transcode(request(input, root: root)); XCTFail("HDR marker accepted") }
            catch let error as MediaPipelineError { XCTAssertEqual(error, .unsupportedStillImage) }
        }
    }

    func testJPEGColorMarkersAfterScanCannotBypassPreflight() throws {
        // One bounded synthetic scan with a stuffed FF and restart marker;
        // metadata can occur between progressive scans or before EOI.
        let scan = Data([0xff,0xd8,0xff,0xda,0,2,0x11,0xff,0,0x22,0xff,0xd0,0x33])
        for protected in [Data("ICC_PROFILE\0".utf8), Data("MPF\0".utf8)] {
            var length = UInt16(protected.count + 2).bigEndian
            let segment = Data([0xff,0xe2]) + withUnsafeBytes(of: &length) { Data($0) } + protected
            XCTAssertThrowsError(try StillMediaPreparer().validateJPEGSource(scan + segment + Data([0xff,0xd9])))
        }
        XCTAssertNoThrow(try StillMediaPreparer().validateJPEGSource(scan + Data([0xff,0xd9])))
        XCTAssertThrowsError(try StillMediaPreparer().validateJPEGSource(scan))
    }

    func testConflictingExplicitEXIFColorSpaceIsRejected() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("uncalibrated.jpg")
        try makeImage(at: input, type: .jpeg, width: 12, height: 8, alpha: false)
        var bytes = removingJPEGICC(try Data(contentsOf: input))
        // ImageIO overwrites an explicit ColorSpace with1 while exporting, so
        // mutate its generated TIFF SHORT entry to an actual conflicting value.
        let bigEndian = Data([0xa0,1,0,3,0,0,0,1,0,1,0,0])
        let littleEndian = Data([1,0xa0,3,0,1,0,0,0,1,0,0,0])
        let entry = try XCTUnwrap(bytes.range(of: bigEndian) ?? bytes.range(of: littleEndian))
        bytes.replaceSubrange((entry.lowerBound + 8)..<(entry.lowerBound + 10), with: [0xff,0xff])
        try bytes.write(to: input)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace] as? Int, 65_535)
        do { _ = try await MediaTranscoder().transcode(request(input, root: root)); XCTFail("Conflicting EXIF color accepted") }
        catch let error as MediaPipelineError { XCTAssertEqual(error, .unsupportedStillImage) }
    }

    func testPosterShrinksTo1920AndTransparentPixelsFlattenOverBlack() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("wide.png")
        try makeImage(at: input, type: .png, width: 2_000, height: 8, alpha: true)
        let result = try await MediaTranscoder().transcode(request(input, root: root))
        let poster = try XCTUnwrap(result.claims.first { $0.kind == .posterImage })
        guard case .still(let value) = poster.inspection else { return XCTFail("Missing image facts") }
        XCTAssertEqual(value.pixelSize.width, 1_920)
        let master = try XCTUnwrap(result.claims.first { $0.kind == .masterImage })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(master.stagedURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(pixel[0]), 128, accuracy: 3)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], 0)
    }

    func testAnimatedTruncatedUnsupportedAndOversizedImagesFailBeforeArtifacts() async throws {
        let root = try temporaryDirectory()
        let valid = root.appendingPathComponent("valid.png")
        try makeImage(at: valid, type: .png, width: 12, height: 8, alpha: false)
        let original = try Data(contentsOf: valid)
        let animation = Data(original.prefix(33)) + chunk("acTL", Data([0,0,0,1,0,0,0,0])) + original.dropFirst(33)
        var oversized = original
        var header = Data(original[16..<29]); header.replaceSubrange(0..<4, with: [0,0,30,1]) //7681
        oversized.replaceSubrange(8..<33, with: chunk("IHDR", header))
        let cases = [animation, Data(original.dropLast(8)), Data("<svg/>".utf8), oversized]
        for (index, bytes) in cases.enumerated() {
            let input = root.appendingPathComponent("bad-\(index).png")
            try bytes.write(to: input)
            do { _ = try await MediaTranscoder().transcode(request(input, root: root)); XCTFail("Invalid image was accepted") }
            catch { XCTAssertEqual(try Data(contentsOf: input), bytes) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging").path))
    }

    func testSymlinkAndEncodedByteLimitDoNotReadOrDeleteOriginal() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("original.png")
        try makeImage(at: original, type: .png, width: 12, height: 8, alpha: false)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        do { _ = try await MediaTranscoder().transcode(request(link, root: root)); XCTFail("Symlink accepted") }
        catch let error as MediaPipelineError { XCTAssertEqual(error, .sourceIsSymbolicLink) }
        let tooLarge = root.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: tooLarge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tooLarge)
        try handle.truncate(atOffset: UInt64(128 * 1_024 * 1_024 + 1)); try handle.close()
        do { _ = try await MediaTranscoder().transcode(request(tooLarge, root: root)); XCTFail("Oversized source accepted") }
        catch let error as MediaPipelineError { XCTAssertEqual(error, .sourceTooLarge(limit: 128 * 1_024 * 1_024)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testCancelledPreparationKeepsOriginalAndCreatesNoCompletedResult() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("original.png")
        try makeImage(at: input, type: .png, width: 12, height: 8, alpha: false)
        let original = try Data(contentsOf: input)
        let request = try request(input, root: root)
        let task = Task {
            try await MediaTranscoder().transcode(request) { progress in
                if progress.phase == .hashingSource { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation returned success") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: input), original)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: request.stagingDirectoryURL.path)) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    private func request(_ source: URL, root: URL) throws -> MediaTranscodeRequest {
        try MediaTranscodeRequest(attempt: .init(jobID: .init(UUID().uuidString.lowercased()),
            generation: .init(1)), sourceURL: source,
            stagingDirectoryURL: root.appendingPathComponent("staging"), mediaKind: .still)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeImage(at url: URL, type: UTType, width: Int, height: Int,
                           alpha: Bool, orientation: Int = 1,
                           spaceName: CFString = CGColorSpace.sRGB) throws {
        let space = try XCTUnwrap(CGColorSpace(name: spaceName))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space,
            components: [1, 0, 0, alpha ? 0.5 : 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func pngKinds(_ bytes: Data) -> [String] {
        var offset = 8; var result: [String] = []
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            result.append(String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)!)
            offset += length + 12
        }
        return result
    }

    private func removingJPEGICC(_ bytes: Data) -> Data {
        var result = Data(bytes.prefix(2)); var offset = 2
        while offset + 4 <= bytes.count {
            let marker = bytes[offset + 1]
            if marker == 0xda { result.append(bytes.dropFirst(offset)); return result }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if marker != 0xe2 { result.append(bytes[offset..<(offset + length + 2)]) }
            offset += length + 2
        }
        return result
    }

    private func chunk(_ kind: String, _ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        let body = Data(kind.utf8) + data
        result.append(body)
        var crc: UInt32 = 0xffff_ffff
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        crc = (~crc).bigEndian
        result.append(withUnsafeBytes(of: &crc) { Data($0) })
        return result
    }
}
