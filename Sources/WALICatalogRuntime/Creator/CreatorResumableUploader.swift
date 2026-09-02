import Foundation
import WALICatalog

public enum CreatorUploadError: String, Error, Sendable, Equatable {
    case accessDenied = "upload_file_access_denied"
    case sourceChanged = "upload_source_changed"
    case invalidRemoteOffset = "upload_offset_invalid"
    case invalidServerResponse = "upload_response_invalid"
    case sessionExpired = "upload_expired"
    case cancelled = "upload_cancelled"
    case unapprovedEndpoint = "upload_endpoint_unapproved"
}

public struct CreatorUploadProgress: Sendable, Hashable {
    public let uploadedByteCount: UInt64
    public let totalByteCount: UInt64

    public var fractionCompleted: Double {
        guard totalByteCount > 0 else { return 0 }
        return min(Double(uploadedByteCount) / Double(totalByteCount), 1)
    }

    public init(uploadedByteCount: UInt64, totalByteCount: UInt64) {
        self.uploadedByteCount = uploadedByteCount
        self.totalByteCount = totalByteCount
    }
}

public protocol CreatorUploadSource: Sendable {
    var byteCount: UInt64 { get async throws }
    func beginAccess() async throws
    func read(range: Range<UInt64>) async throws -> Data
    func endAccess() async
}

public protocol CreatorResumableUploadTransport: Sendable {
    func uploadOffset(for session: CreatorUploadSession) async throws -> UInt64
    func upload(
        _ chunk: Data,
        at offset: UInt64,
        in session: CreatorUploadSession
    ) async throws -> UInt64
    func cancel(_ session: CreatorUploadSession) async
}

public struct CreatorResumableUploader: Sendable {
    public let chunkSize: Int

    public init(chunkSize: Int = 4 * 1_024 * 1_024) {
        self.chunkSize = max(1, min(chunkSize, 16 * 1_024 * 1_024))
    }

    public func upload(
        session: CreatorUploadSession,
        source: any CreatorUploadSource,
        transport: any CreatorResumableUploadTransport
    ) async throws -> CreatorUploadProgress {
        try await upload(
            session: session,
            source: source,
            transport: transport,
            progress: { _ in }
        )
    }

    public func upload(
        session: CreatorUploadSession,
        source: any CreatorUploadSource,
        transport: any CreatorResumableUploadTransport,
        progress: @escaping @Sendable (CreatorUploadProgress) async -> Void
    ) async throws -> CreatorUploadProgress {
        guard session.expiresAt > .now else { throw CreatorUploadError.sessionExpired }
        try await source.beginAccess()

        do {
            let localByteCount = try await source.byteCount
            guard localByteCount == session.declaredByteCount else {
                throw CreatorUploadError.sourceChanged
            }
            var offset = try await transport.uploadOffset(for: session)
            guard offset <= session.declaredByteCount else {
                throw CreatorUploadError.invalidRemoteOffset
            }
            await progress(.init(
                uploadedByteCount: offset,
                totalByteCount: session.declaredByteCount
            ))

            while offset < session.declaredByteCount {
                try Task.checkCancellation()
                let upperBound = min(offset + UInt64(chunkSize), session.declaredByteCount)
                let chunk = try await source.read(range: offset..<upperBound)
                guard chunk.count == Int(upperBound - offset) else {
                    throw CreatorUploadError.sourceChanged
                }
                let nextOffset = try await transport.upload(chunk, at: offset, in: session)
                guard nextOffset == upperBound else {
                    throw CreatorUploadError.invalidRemoteOffset
                }
                offset = nextOffset
                await progress(.init(
                    uploadedByteCount: offset,
                    totalByteCount: session.declaredByteCount
                ))
            }

            await source.endAccess()
            return CreatorUploadProgress(
                uploadedByteCount: offset,
                totalByteCount: session.declaredByteCount
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                await transport.cancel(session)
                await source.endAccess()
                throw CreatorUploadError.cancelled
            }
            await source.endAccess()
            throw error
        }
    }
}

public actor FileCreatorUploadSource: CreatorUploadSource {
    public let fileURL: URL
    private let requiresSecurityScope: Bool
    private var fileHandle: FileHandle?
    private var accessStarted = false
    private var observedByteCount: UInt64?

    public init(fileURL: URL, requiresSecurityScope: Bool = true) {
        self.fileURL = fileURL
        self.requiresSecurityScope = requiresSecurityScope
    }

    public var byteCount: UInt64 {
        get async throws {
            if let observedByteCount { return observedByteCount }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw CreatorUploadError.accessDenied
            }
            let result = UInt64(size)
            observedByteCount = result
            return result
        }
    }

    public func beginAccess() async throws {
        guard fileHandle == nil else { return }
        if requiresSecurityScope {
            guard fileURL.startAccessingSecurityScopedResource() else {
                throw CreatorUploadError.accessDenied
            }
            accessStarted = true
        }
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
            _ = try await byteCount
        } catch {
            if accessStarted {
                fileURL.stopAccessingSecurityScopedResource()
                accessStarted = false
            }
            throw CreatorUploadError.accessDenied
        }
    }

    public func read(range: Range<UInt64>) async throws -> Data {
        guard let fileHandle, range.lowerBound <= range.upperBound else {
            throw CreatorUploadError.accessDenied
        }
        do {
            try fileHandle.seek(toOffset: range.lowerBound)
            return try fileHandle.read(upToCount: Int(range.count)) ?? Data()
        } catch {
            throw CreatorUploadError.accessDenied
        }
    }

    public func endAccess() async {
        try? fileHandle?.close()
        fileHandle = nil
        if accessStarted {
            fileURL.stopAccessingSecurityScopedResource()
            accessStarted = false
        }
    }
}

public actor URLSessionCreatorUploadTransport: CreatorResumableUploadTransport {
    private let urlSession: URLSession
    private let approvedHosts: Set<String>

    public init(approvedHosts: Set<String>) throws {
        guard !approvedHosts.isEmpty,
              approvedHosts.allSatisfy(validateCatalogPublicHostname)
        else {
            throw CatalogRequestError.invalidConfiguration
        }
        self.approvedHosts = approvedHosts
        urlSession = CatalogURLSessionFactory.redirectRejecting()
    }

    public func uploadOffset(for session: CreatorUploadSession) async throws -> UInt64 {
        var request = try request(for: session, method: "HEAD")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await urlSession.data(for: request)
        return try validatedOffset(response, expectedStatus: [200, 204])
    }

    public func upload(
        _ chunk: Data,
        at offset: UInt64,
        in session: CreatorUploadSession
    ) async throws -> UInt64 {
        var request = try request(for: session, method: "PATCH")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.httpBody = chunk
        let (_, response) = try await urlSession.data(for: request)
        return try validatedOffset(response, expectedStatus: [200, 204])
    }

    public func cancel(_ session: CreatorUploadSession) async {
        // URLSession's async task is cancelled with its parent task. The upload grant remains
        // resumable until server expiry; no destructive remote delete is inferred here.
    }

    private func request(for session: CreatorUploadSession, method: String) throws -> URLRequest {
        guard session.expiresAt > .now else { throw CreatorUploadError.sessionExpired }
        guard CatalogRemoteURLPolicy.isCanonicalHTTPS(session.endpoint),
              session.endpoint.host.map({ approvedHosts.contains($0.lowercased()) }) == true
        else {
            throw CreatorUploadError.unapprovedEndpoint
        }
        var request = URLRequest(url: session.endpoint)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in session.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            request.setValue("Bearer \(session.scopedUploadToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validatedOffset(_ response: URLResponse, expectedStatus: Set<Int>) throws -> UInt64 {
        guard let response = response as? HTTPURLResponse,
              expectedStatus.contains(response.statusCode),
              let responseURL = response.url,
              CatalogRemoteURLPolicy.isCanonicalHTTPS(responseURL),
              responseURL.host.map({ approvedHosts.contains($0.lowercased()) }) == true,
              let rawOffset = response.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = UInt64(rawOffset)
        else {
            throw CreatorUploadError.invalidServerResponse
        }
        return offset
    }
}

extension CreatorUploadSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "CreatorUploadSession(id: \(id), credentials: <redacted>)" }
    public var debugDescription: String { description }
}
