import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WALIAgentRuntime

@MainActor
final class StaticWallpaperImageLoaderTests: XCTestCase {
    func testCanonicalOpaqueSRGBPNGDecodesAtOriginalPixelSize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeImage(in: directory, type: .png)
        let result = try await StaticWallpaperImageLoader.shared.load(url)
        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.bitsPerComponent, 8)
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testRenamedVideoJPEGAndTruncatedPNGAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try writeImage(in: directory, type: .jpeg)
        await assertRejected(jpeg)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: invalid)
        await assertRejected(invalid)
        let valid = try writeImage(in: directory, type: .png)
        let bytes = try Data(contentsOf: valid)
        try bytes.prefix(30).write(to: invalid)
        await assertRejected(invalid)
    }

    func testAlphaAndOversizedDimensionsAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await assertRejected(try writeImage(in: directory, type: .png, alpha: true))
        await assertRejected(try writeImage(in: directory, type: .png, width: 7_681, height: 1))
    }

    func testNonFileDirectorySymlinkAndExcessEncodedBytesAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await assertRejected(try XCTUnwrap(URL(string: "https://example.invalid/image.png")))
        await assertRejected(directory)
        let image = try writeImage(in: directory, type: .png)
        let link = directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        await assertRejected(link)
        let tooLarge = directory.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: tooLarge.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: tooLarge)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024 + 1)
        try handle.close()
        await assertRejected(tooLarge)
    }

    func testValidPNGWithPrivateTextMetadataIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(in: directory, type: .png)
        var bytes = try Data(contentsOf: image)
        bytes.insert(contentsOf: pngChunk("tEXt", payload: Data("Comment\0private source location".utf8)), at: 33)
        try bytes.write(to: image)
        await assertRejected(image)
    }

    func testSingleFrameAPNGIsRejectedRatherThanTreatedAsAStill() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(in: directory, type: .png)
        var bytes = try Data(contentsOf: image)
        let animation = pngChunk("acTL", payload: be32(1) + be32(0))
        let frame = pngChunk("fcTL", payload: be32(0) + be32(8) + be32(4) + be32(0) + be32(0)
            + Data([0, 1, 0, 10, 0, 0]))
        bytes.insert(contentsOf: animation + frame, at: 33)
        try bytes.write(to: image)
        await assertRejected(image)
    }

    func testImageIOGeneratedEXIFIsAlsoRemovedByCanonicalization() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(in: directory, type: .png, stripMetadata: false)
        await assertRejected(image)
    }

    func testTrailingDataAfterThePNGEndIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(in: directory, type: .png)
        var bytes = try Data(contentsOf: image)
        bytes.append(pngChunk("tEXt", payload: Data("Comment\0private".utf8)))
        try bytes.write(to: image)
        await assertRejected(image)
    }

    private func be32(_ number: UInt32) -> Data {
        Data([UInt8((number >> 24) & 255), UInt8((number >> 16) & 255),
              UInt8((number >> 8) & 255), UInt8(number & 255)])
    }

    private func pngChunk(_ name: String, payload: Data) -> Data {
        let body = Data(name.utf8) + payload
        var crc: UInt32 = 0xffff_ffff
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return be32(UInt32(payload.count)) + body + be32(crc ^ 0xffff_ffff)
    }

    private func assertRejected(_ url: URL, file: StaticString = #filePath,
                                line: UInt = #line) async {
        do {
            _ = try await StaticWallpaperImageLoader.shared.load(url)
            XCTFail("Unsupported installed image was accepted", file: file, line: line)
        } catch { XCTAssertEqual(error as? StaticImageWallpaperError, .invalidImage, file: file, line: line) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(in directory: URL, type: UTType, alpha: Bool = false,
                            width: Int = 8, height: Int = 4,
                            stripMetadata: Bool = true) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        if type == .png, stripMetadata {
            // ImageIO generates eXIf dimensions even with nil source metadata.
            // A canonical fixture removes it, exactly as the encoder must.
            let bytes = try Data(contentsOf: url)
            var canonical = Data(bytes.prefix(8))
            var offset = 8
            while offset < bytes.count {
                let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                let end = offset + length + 12
                if String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) != "eXIf" {
                    canonical.append(bytes[offset..<end])
                }
                offset = end
            }
            try canonical.write(to: url)
        }
        return url
    }
}
