import CryptoKit
import Darwin
import Foundation
import WALICatalog

public struct CatalogTransportDownload: @unchecked Sendable {
    public let temporaryFileURL: URL
    public let response: HTTPURLResponse

    public init(temporaryFileURL: URL, response: HTTPURLResponse) {
        self.temporaryFileURL = temporaryFileURL
        self.response = response
    }
}

public protocol CatalogDownloadTransport: Sendable {
    func download(_ url: URL) async throws -> CatalogTransportDownload
}

public protocol AccountExportDownloadTransport: Sendable {
    func download(_ url: URL, maximumByteCount: UInt64) async throws -> CatalogTransportDownload
}

public final class URLSessionAccountExportDownloadTransport:
    AccountExportDownloadTransport,
    @unchecked Sendable
{
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func download(_ url: URL, maximumByteCount: UInt64) async throws -> CatalogTransportDownload {
        guard maximumByteCount <= UInt64(Int64.max) else {
            throw AccountExportDownloadError.unexpectedLength
        }
        return try await BoundedDownloadOperation(
            configuration: configuration,
            expectedURL: url,
            maximumByteCount: Int64(maximumByteCount)
        ).run()
    }
}

private final class BoundedDownloadOperation:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let configuration: URLSessionConfiguration
    private let expectedURL: URL
    private let maximumByteCount: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CatalogTransportDownload, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    init(configuration: URLSessionConfiguration, expectedURL: URL, maximumByteCount: Int64) {
        self.configuration = configuration
        self.expectedURL = expectedURL
        self.maximumByteCount = maximumByteCount
    }

    func run() async throws -> CatalogTransportDownload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: URLRequest(url: expectedURL))
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumByteCount || totalBytesExpectedToWrite > maximumByteCount {
            downloadTask.cancel()
            finish(.failure(AccountExportDownloadError.unexpectedLength))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url == expectedURL
        else {
            finish(.failure(AccountExportDownloadError.invalidResponse))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appending(
            path: "wali-account-export-\(UUID().uuidString.lowercased()).download",
            directoryHint: .notDirectory
        )
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0,
                  Int64(size) <= maximumByteCount
            else { throw AccountExportDownloadError.unexpectedLength }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            finish(.success(.init(temporaryFileURL: destination, response: response)))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(AccountExportDownloadError.invalidResponse))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<CatalogTransportDownload, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        task?.cancel()
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

public final class URLSessionCatalogDownloadTransport: CatalogDownloadTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func download(_ url: URL) async throws -> CatalogTransportDownload {
        let delegate = RejectRedirectDelegate()
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporaryURL, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogDownloadError.invalidResponse
        }
        return CatalogTransportDownload(temporaryFileURL: temporaryURL, response: http)
    }
}

private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum CatalogDownloadError: String, Error, Sendable, Equatable {
    case invalidResponse = "invalid_response"
    case unapprovedHost = "unapproved_host"
    case unexpectedLength = "unexpected_length"
    case digestMismatch = "digest_mismatch"
    case destinationUnavailable = "destination_unavailable"
}

public enum AccountExportDownloadError: String, Error, Sendable, Equatable {
    case invalidResponse = "invalid_response"
    case unapprovedURL = "unapproved_url"
    case grantExpired = "grant_expired"
    case exportNotReady = "export_not_ready"
    case unexpectedLength = "unexpected_length"
    case digestMismatch = "digest_mismatch"
    case destinationUnavailable = "destination_unavailable"
}

public struct AccountExportDownloader: Sendable {
    private let transport: any AccountExportDownloadTransport
    private let remoteURLPolicy: CatalogRemoteURLPolicy

    public init(
        transport: any AccountExportDownloadTransport = URLSessionAccountExportDownloadTransport(),
        remoteURLPolicy: CatalogRemoteURLPolicy
    ) {
        self.transport = transport
        self.remoteURLPolicy = remoteURLPolicy
    }

    public func save(_ export: AccountExportSnapshot, to destination: URL) async throws {
        guard export.status == .ready,
              let expectedByteCount = export.byteCount,
              let expectedDigest = export.sha256,
              let downloadURL = export.downloadURL,
              let downloadExpiresAt = export.downloadExpiresAt
        else { throw AccountExportDownloadError.exportNotReady }
        guard export.expiresAt > .now, downloadExpiresAt > .now else {
            throw AccountExportDownloadError.grantExpired
        }
        guard remoteURLPolicy.allowsSignedAccountExport(
            downloadURL,
            subjectID: export.subjectID,
            exportID: export.id
        ) else {
            throw AccountExportDownloadError.unapprovedURL
        }
        guard destination.isFileURL,
              !destination.hasDirectoryPath,
              expectedByteCount <= 104_857_600
        else { throw AccountExportDownloadError.destinationUnavailable }

        let transfer = try await transport.download(downloadURL, maximumByteCount: expectedByteCount)
        defer { try? FileManager.default.removeItem(at: transfer.temporaryFileURL) }
        guard transfer.response.statusCode == 200,
              transfer.response.url == downloadURL,
              transfer.response.expectedContentLength == -1
                || transfer.response.expectedContentLength == Int64(expectedByteCount),
              transfer.response.mimeType == "application/json"
        else { throw AccountExportDownloadError.invalidResponse }

        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw AccountExportDownloadError.destinationUnavailable
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let destinationValues = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard destinationValues.isSymbolicLink != true else {
                throw AccountExportDownloadError.destinationUnavailable
            }
        }

        let temporaryDestination = parent.appending(
            path: ".wali-account-export-\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory
        )
        guard let output = createExclusiveAccountExportFile(at: temporaryDestination) else {
            throw AccountExportDownloadError.destinationUnavailable
        }
        do {
            let input = try FileHandle(forReadingFrom: transfer.temporaryFileURL)
            defer { try? input.close() }
            defer { try? output.close() }
            var hash = SHA256()
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                total += UInt64(chunk.count)
                guard total <= expectedByteCount else {
                    throw AccountExportDownloadError.unexpectedLength
                }
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard total == expectedByteCount else {
                throw AccountExportDownloadError.unexpectedLength
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedDigest else { throw AccountExportDownloadError.digestMismatch }
            try output.synchronize()
            try output.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryDestination)
            } else {
                try FileManager.default.moveItem(at: temporaryDestination, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryDestination)
            throw error
        }
    }
}

private func createExclusiveAccountExportFile(at url: URL) -> FileHandle? {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
    }
    guard descriptor >= 0 else { return nil }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

public struct CatalogDownloader: Sendable {
    private let transport: any CatalogDownloadTransport
    private let approvedHosts: Set<String>

    public init(
        transport: any CatalogDownloadTransport = URLSessionCatalogDownloadTransport(),
        approvedHosts: Set<String>
    ) throws {
        guard !approvedHosts.isEmpty,
              approvedHosts.allSatisfy(validateCatalogPublicHostname)
        else {
            throw CatalogRequestError.invalidConfiguration
        }
        self.transport = transport
        self.approvedHosts = approvedHosts
    }

    public func download(
        artifact: CatalogArtifact,
        quarantineDirectory: URL
    ) async throws -> URL {
        try await downloadVerified(
            url: artifact.url,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            mediaType: artifact.mediaType,
            quarantineDirectory: quarantineDirectory
        )
    }

    public func downloadVerified(
        url: URL,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        quarantineDirectory: URL
    ) async throws -> URL {
        guard url.host.map({ approvedHosts.contains($0.lowercased()) }) == true else {
            throw CatalogDownloadError.unapprovedHost
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...CatalogArtifact.maximumByteCount).contains(byteCount),
              ["video/mp4", "image/avif", "image/jpeg", "image/png"].contains(mediaType)
        else { throw CatalogDownloadError.invalidResponse }
        let transfer = try await transport.download(url)
        let destination = quarantineDirectory.appending(
            path: "\(UUID().uuidString.lowercased()).wali-quarantine.\(fileExtension(for: mediaType))",
            directoryHint: .notDirectory
        )
        do {
            guard transfer.response.statusCode == 200,
                  transfer.response.url == url
            else {
                throw CatalogDownloadError.invalidResponse
            }
            guard transfer.response.expectedContentLength == Int64(byteCount) else {
                throw CatalogDownloadError.unexpectedLength
            }
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let directoryValues = try quarantineDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  let output = createExclusiveFile(at: destination)
            else {
                throw CatalogDownloadError.destinationUnavailable
            }
            let source = try FileHandle(forReadingFrom: transfer.temporaryFileURL)
            defer {
                try? source.close()
                try? output.close()
            }
            var hash = SHA256()
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try source.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                total += UInt64(chunk.count)
                guard total <= byteCount else {
                    throw CatalogDownloadError.unexpectedLength
                }
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard total == byteCount else {
                throw CatalogDownloadError.unexpectedLength
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                throw CatalogDownloadError.digestMismatch
            }
            try output.synchronize()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func createExclusiveFile(at url: URL) -> FileHandle? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "video/mp4": "mp4"
        case "image/avif": "avif"
        case "image/jpeg": "jpg"
        case "image/png": "png"
        default:
            // CatalogArtifact rejects every other media type before this point.
            preconditionFailure("Unsupported validated catalog media type")
        }
    }
}
