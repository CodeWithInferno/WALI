import Foundation
@testable import WALICatalogRuntime
import XCTest

final class CreatorUploadCoordinatorTests: XCTestCase {
    func testUploadResumesFromServerOffsetWithoutReadingThePrefixAgain() async throws {
        let session = try makeSession(declaredByteCount: 10)
        let source = RecordingUploadSource(bytes: Data("0123456789".utf8))
        let transport = RecordingResumableTransport(offset: 4)
        let uploader = CreatorResumableUploader(chunkSize: 3)

        let result = try await uploader.upload(session: session, source: source, transport: transport)

        XCTAssertEqual(result.uploadedByteCount, 10)
        let requestedRanges = await source.requestedRanges()
        let receivedOffsets = await transport.receivedOffsets()
        let accessCounts = await source.accessCounts()
        XCTAssertEqual(requestedRanges, [4..<7, 7..<10])
        XCTAssertEqual(receivedOffsets, [4, 7])
        XCTAssertEqual(accessCounts, .init(begins: 1, ends: 1))
    }

    func testUploadRejectsServerOffsetBeyondDeclaredSizeAndClosesAccess() async throws {
        let session = try makeSession(declaredByteCount: 10)
        let source = RecordingUploadSource(bytes: Data("0123456789".utf8))
        let transport = RecordingResumableTransport(offset: 11)
        let uploader = CreatorResumableUploader(chunkSize: 3)

        await XCTAssertThrowsErrorAsync {
            _ = try await uploader.upload(session: session, source: source, transport: transport)
        } verify: { error in
            XCTAssertEqual(error as? CreatorUploadError, .invalidRemoteOffset)
        }
        let accessCounts = await source.accessCounts()
        let requestedRanges = await source.requestedRanges()
        XCTAssertEqual(accessCounts, .init(begins: 1, ends: 1))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testTaskCancellationCancelsTransportAndClosesAccess() async throws {
        let session = try makeSession(declaredByteCount: 10)
        let source = RecordingUploadSource(bytes: Data("0123456789".utf8))
        let transport = RecordingResumableTransport(offset: 0, uploadDelay: .seconds(5))
        let uploader = CreatorResumableUploader(chunkSize: 3)
        let task = Task {
            try await uploader.upload(session: session, source: source, transport: transport)
        }

        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = try? await task.value

        let cancelledSessionIDs = await transport.cancelledSessionIDs()
        let accessCounts = await source.accessCounts()
        XCTAssertEqual(cancelledSessionIDs, [session.id])
        XCTAssertEqual(accessCounts, .init(begins: 1, ends: 1))
    }

    func testURLSessionTransportRejectsUnapprovedEndpointBeforeSendingCredentials() async throws {
        let session = try makeSession(declaredByteCount: 10)
        let transport = try URLSessionCreatorUploadTransport(
            approvedHosts: ["approved.example.test"]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transport.uploadOffset(for: session)
        } verify: { error in
            XCTAssertEqual(error as? CreatorUploadError, .unapprovedEndpoint)
        }
    }

    private func makeSession(declaredByteCount: UInt64) throws -> CreatorUploadSession {
        try CreatorUploadSession(
            id: UUID(),
            revision: 1,
            endpoint: XCTUnwrap(URL(string: "https://uploads.example.test/session")),
            requiredHeaders: ["Tus-Resumable": "1.0.0"],
            scopedUploadToken: "scoped-test-token",
            expiresAt: Date().addingTimeInterval(3_600),
            declaredByteCount: declaredByteCount
        )
    }
}

private actor RecordingUploadSource: CreatorUploadSource {
    struct AccessCounts: Equatable { let begins: Int; let ends: Int }

    let byteCount: UInt64
    private let bytes: Data
    private var reads: [Range<UInt64>] = []
    private var beginCount = 0
    private var endCount = 0

    init(bytes: Data) {
        self.bytes = bytes
        byteCount = UInt64(bytes.count)
    }

    func beginAccess() async throws { beginCount += 1 }
    func endAccess() async { endCount += 1 }

    func read(range: Range<UInt64>) async throws -> Data {
        reads.append(range)
        return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    func requestedRanges() -> [Range<UInt64>] { reads }
    func accessCounts() -> AccessCounts { .init(begins: beginCount, ends: endCount) }
}

private actor RecordingResumableTransport: CreatorResumableUploadTransport {
    private let initialOffset: UInt64
    private let uploadDelay: Duration?
    private var offsets: [UInt64] = []
    private var cancellations: [UUID] = []

    init(offset: UInt64, uploadDelay: Duration? = nil) {
        initialOffset = offset
        self.uploadDelay = uploadDelay
    }

    func uploadOffset(for session: CreatorUploadSession) async throws -> UInt64 { initialOffset }

    func upload(
        _ chunk: Data,
        at offset: UInt64,
        in session: CreatorUploadSession
    ) async throws -> UInt64 {
        offsets.append(offset)
        if let uploadDelay { try await Task.sleep(for: uploadDelay) }
        return offset + UInt64(chunk.count)
    }

    func cancel(_ session: CreatorUploadSession) async {
        cancellations.append(session.id)
    }

    func receivedOffsets() -> [UInt64] { offsets }
    func cancelledSessionIDs() -> [UUID] { cancellations }
}

private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
