import Darwin
import Foundation
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class LocalImportMediaKindTests: XCTestCase {
    func testImageSignaturesSelectStillRegardlessOfFilename() throws {
        let root = try directory()
        for bytes in [Data([137,80,78,71,13,10,26,10]), Data([255,216,255,224,0,16,0,0])] {
            let source = root.appendingPathComponent(UUID().uuidString + ".mp4")
            try bytes.write(to: source)
            let request = try request(source)
            XCTAssertEqual(request.mediaKind, .still)
            XCTAssertEqual(request.sourceByteLimit, TranscoderRequest.maximumStillSourceByteCount)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testMovieAndFalseImageExtensionRetainVideoValidation() throws {
        let root = try directory()
        let source = root.appendingPathComponent("misnamed.png")
        try Data([0,0,0,32,102,116,121,112,105,115,111,109]).write(to: source)
        let request = try request(source)
        XCTAssertEqual(request.mediaKind, .video)
        XCTAssertEqual(request.sourceByteLimit, TranscoderRequest.maximumSourceByteCount)
    }

    func testNonregularAndSymlinkSourcesAreRejectedWithoutFollowingOrBlocking() throws {
        let root = try directory()
        let target = root.appendingPathComponent("original.png")
        let bytes = Data([137,80,78,71,13,10,26,10])
        try bytes.write(to: target)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try request(link))
        XCTAssertThrowsError(try request(root))
        let fifo = root.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try request(fifo))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    private func request(_ source: URL) throws -> TranscoderRequest {
        try LocalImportTranscoderRequestFactory.make(jobID: UUID(), attemptGeneration: 1,
            sourceBookmark: Data([1]), sourceURL: source,
            stagingDirectoryURL: source.deletingLastPathComponent().appendingPathComponent("staging"))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
