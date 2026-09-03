import CryptoKit
import Foundation
import WALICatalog
@testable import WALICatalogRuntime
import XCTest

final class ManifestDownloadTests: XCTestCase {
    func testModeratorPresentationMediaCacheVerifiesSignedCanonicalBytes() async throws {
        let bytes = Data("verified moderator poster".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let signedURL = try XCTUnwrap(URL(string: "https://project.supabase.co/storage/v1/object/sign/processing-private/sha256/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)/poster.jpg?token=moderator-safe-token"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: signedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.example.test"]
        )
        let artifact = try CreatorCanonicalArtifact(
            role: .poster,
            url: signedURL,
            sha256: digest,
            byteCount: UInt64(bytes.count),
            mediaType: "image/jpeg",
            width: 1,
            height: 1,
            durationMilliseconds: 0,
            remoteURLPolicy: policy
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["project.supabase.co"]
        )
        let cache = try CatalogPresentationMediaCache(root: cacheRoot, downloader: downloader)

        let output = try await cache.localURL(for: artifact)

        XCTAssertTrue(output.isFileURL)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testPresentationMediaCachePublishesOnlyDigestVerifiedLocalBytes() async throws {
        let bytes = Data("verified presentation media".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let remoteURL = try XCTUnwrap(URL(string: "https://catalog.wali.example/poster.jpg"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: remoteURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .poster,
            url: remoteURL,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count),
            mediaType: "image/jpeg",
            width: 1,
            height: 1,
            durationMilliseconds: 0
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )
        let cache = try CatalogPresentationMediaCache(root: cacheRoot, downloader: downloader)

        let output = try await cache.localURL(for: artifact)

        XCTAssertTrue(output.isFileURL)
        XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL, cacheRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o400
        )
    }

    func testPresentationMediaCacheAcceptsCanonicalPlaybackArtifact() async throws {
        let bytes = Data("verified canonical playback".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let remoteURL = try XCTUnwrap(URL(string: "https://catalog.wali.example/video-default.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: remoteURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .videoDefault,
            url: remoteURL,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count),
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )
        let cache = try CatalogPresentationMediaCache(root: cacheRoot, downloader: downloader)

        let output = try await cache.localURL(for: artifact)

        XCTAssertTrue(output.isFileURL)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testPresentationMediaCacheRejectsOptionalLadderPlaybackRole() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try CatalogArtifact(
            role: .video2160p,
            url: try XCTUnwrap(URL(string: "https://catalog.wali.example/video-2160p.mp4")),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1
        )
        let downloader = try CatalogDownloader(
            transport: FailingDownloadTransport(),
            approvedHosts: ["catalog.wali.example"]
        )
        let cache = try CatalogPresentationMediaCache(root: root, downloader: downloader)

        do {
            _ = try await cache.localURL(for: artifact)
            XCTFail("Expected an unsupported presentation role")
        } catch let error as CatalogPresentationMediaCacheError {
            XCTAssertEqual(error, .unsupportedArtifact)
        }
    }

    func testVerifiedDownloadWritesOpaqueQuarantineFile() async throws {
        let bytes = Data("safe canonical bytes".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let url = try XCTUnwrap(URL(string: "https://catalog.wali.example/poster.jpg"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .poster,
            url: url,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count),
            mediaType: "image/jpeg",
            width: 1,
            height: 1,
            durationMilliseconds: 0
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )
        let output = try await downloader.download(
            artifact: artifact,
            quarantineDirectory: destination
        )
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(output.lastPathComponent.hasSuffix(".wali-quarantine.jpg"))
        XCTAssertFalse(output.lastPathComponent.contains("poster"))
    }

    func testVideoDownloadUsesAVFoundationRecognizableMP4Extension() async throws {
        let bytes = Data("safe canonical video bytes".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let url = try XCTUnwrap(URL(string: "https://catalog.wali.example/video.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .videoDefault,
            url: url,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count),
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )

        let output = try await downloader.download(
            artifact: artifact,
            quarantineDirectory: destination
        )

        XCTAssertTrue(output.lastPathComponent.hasSuffix(".wali-quarantine.mp4"))
    }

    func testDigestMismatchRemovesPartialDestination() async throws {
        let bytes = Data("tampered".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let url = try XCTUnwrap(URL(string: "https://catalog.wali.example/video.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .videoDefault,
            url: url,
            sha256: String(repeating: "0", count: 64),
            byteCount: UInt64(bytes.count),
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )
        do {
            _ = try await downloader.download(artifact: artifact, quarantineDirectory: destination)
            XCTFail("Expected digest mismatch")
        } catch let error as CatalogDownloadError {
            XCTAssertEqual(error, .digestMismatch)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path),
            []
        )
    }

    func testSameHostRedirectSubstitutionIsRejected() async throws {
        let bytes = Data("safe canonical bytes".utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let signedURL = try XCTUnwrap(URL(string: "https://catalog.wali.example/signed.mp4"))
        let substitutedURL = try XCTUnwrap(URL(string: "https://catalog.wali.example/other.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: substitutedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)"]
        ))
        let artifact = try CatalogArtifact(
            role: .videoDefault,
            url: signedURL,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count),
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1
        )
        let downloader = try CatalogDownloader(
            transport: FakeDownloadTransport(file: source, response: response),
            approvedHosts: ["catalog.wali.example"]
        )

        do {
            _ = try await downloader.download(artifact: artifact, quarantineDirectory: destination)
            XCTFail("Expected redirect substitution to fail")
        } catch let error as CatalogDownloadError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testAccountExportIsVerifiedBeforeAtomicSave() async throws {
        let bytes = Data(#"{"schema":"wali.account-export.v1"}"#.utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = directory.appending(path: "WALI Account Export.json")
        try bytes.write(to: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        let exportID = "11111111-1111-4111-8111-111111111111"
        let userID = "22222222-2222-4222-8222-222222222222"
        let url = try XCTUnwrap(URL(string:
            "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/\(userID)/\(exportID)/account.json?token=signed"
        ))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(bytes.count)", "Content-Type": "application/json"]
        ))
        let snapshot = try AccountExportSnapshot(
            id: exportID,
            subjectID: userID,
            status: .ready,
            expiresAt: .now.addingTimeInterval(3_600),
            completedAt: .now,
            byteCount: UInt64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            downloadURL: url,
            downloadExpiresAt: .now.addingTimeInterval(300)
        )
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let downloader = AccountExportDownloader(
            transport: FakeAccountExportTransport(file: source, response: response),
            remoteURLPolicy: policy
        )

        try await downloader.save(snapshot, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testAccountExportDigestMismatchLeavesDestinationUntouched() async throws {
        let original = Data("existing user file".utf8)
        let received = Data(#"{"tampered":true}"#.utf8)
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = directory.appending(path: "WALI Account Export.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try original.write(to: destination)
        try received.write(to: source)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        let exportID = "11111111-1111-4111-8111-111111111111"
        let userID = "22222222-2222-4222-8222-222222222222"
        let url = try XCTUnwrap(URL(string:
            "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/\(userID)/\(exportID)/account.json?token=signed"
        ))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(received.count)", "Content-Type": "application/json"]
        ))
        let snapshot = try AccountExportSnapshot(
            id: exportID,
            subjectID: userID,
            status: .ready,
            expiresAt: .now.addingTimeInterval(3_600),
            completedAt: .now,
            byteCount: UInt64(received.count),
            sha256: String(repeating: "0", count: 64),
            downloadURL: url,
            downloadExpiresAt: .now.addingTimeInterval(300)
        )
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let downloader = AccountExportDownloader(
            transport: FakeAccountExportTransport(file: source, response: response),
            remoteURLPolicy: policy
        )

        do {
            try await downloader.save(snapshot, to: destination)
            XCTFail("Expected export digest mismatch")
        } catch let error as AccountExportDownloadError {
            XCTAssertEqual(error, .digestMismatch)
        }

        XCTAssertEqual(try Data(contentsOf: destination), original)
    }
}

private struct FakeDownloadTransport: CatalogDownloadTransport {
    let file: URL
    let response: HTTPURLResponse

    func download(_ url: URL) async throws -> CatalogTransportDownload {
        CatalogTransportDownload(temporaryFileURL: file, response: response)
    }
}

private struct FailingDownloadTransport: CatalogDownloadTransport {
    func download(_ url: URL) async throws -> CatalogTransportDownload {
        throw CatalogDownloadError.invalidResponse
    }
}

private struct FakeAccountExportTransport: AccountExportDownloadTransport {
    let file: URL
    let response: HTTPURLResponse

    func download(_ url: URL, maximumByteCount: UInt64) async throws -> CatalogTransportDownload {
        CatalogTransportDownload(temporaryFileURL: file, response: response)
    }
}
