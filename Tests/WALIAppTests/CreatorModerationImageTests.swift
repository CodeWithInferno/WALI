import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WALIAppRuntime
import XCTest

final class CreatorModerationImageTests: XCTestCase {
    func testCanonicalPNGDisplaysWithItsVerifiedDimensions() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.url) }
        let image = try await CreatorModerationImageLoader().load(file)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testClaimedDimensionChangeAndPrivateMetadataFailBeforeDisplay() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.url) }
        let loader = CreatorModerationImageLoader()
        do {
            _ = try await loader.load(.init(url: file.url, width: 9, height: 4, byteCount: file.byteCount))
            XCTFail("A mismatched image claim was displayed")
        } catch {}
        let metadata = try fixture(stripMetadata: false)
        defer { try? FileManager.default.removeItem(at: metadata.url) }
        do {
            _ = try await loader.load(metadata)
            XCTFail("Private PNG metadata was accepted")
        } catch {}
    }

    func testRemoteSymlinkAndOversizedClaimsNeverReachImageDisplay() async throws {
        let file = try fixture()
        let link = file.url.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: file.url); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
        let loader = CreatorModerationImageLoader()
        for value in [
            CreatorReviewImageSource(url: URL(string: "https://example.invalid/image.png")!, width: 8, height: 4, byteCount: file.byteCount),
            CreatorReviewImageSource(url: link, width: 8, height: 4, byteCount: file.byteCount),
            CreatorReviewImageSource(url: file.url, width: 7_681, height: 4, byteCount: file.byteCount),
            CreatorReviewImageSource(url: file.url, width: 8, height: 4, byteCount: 134_217_729),
        ] {
            do { _ = try await loader.load(value); XCTFail("Unsafe display claim was accepted") } catch {}
        }
    }

    private func fixture(stripMetadata: Bool = true) throws -> CreatorReviewImageSource {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let raw = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(raw, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private test metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = raw as Data
        var data = original
        if stripMetadata {
            data = original.prefix(8)
            var offset = 8
            while offset < original.count {
                let size = original[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                let name = String(data: original[(offset + 4)..<(offset + 8)], encoding: .ascii)!
                if ["IHDR", "sRGB", "IDAT", "IEND"].contains(name) {
                    data.append(original[offset..<(offset + size + 12)])
                }
                offset += size + 12
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try data.write(to: url, options: .atomic)
        return .init(url: url, width: 8, height: 4, byteCount: UInt64(data.count))
    }
}
