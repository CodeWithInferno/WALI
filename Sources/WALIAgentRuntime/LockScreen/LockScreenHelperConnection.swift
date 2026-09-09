import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WALILockScreenWire

public enum LockScreenHelperConnectionError: LocalizedError, Equatable, Sendable {
    case unavailable
    case permissionRequired
    case unsupportedBuild
    case invalidResponse
    case sourceRejected

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The separate WALI Lock Screen Helper is unavailable."
        case .permissionRequired:
            "Allow WALI Lock Screen Helper in Full Disk Access; WALI Agent does not need that permission."
        case .unsupportedBuild:
            "This macOS build has not been verified for authenticated-session Lock Screen continuity."
        case .invalidResponse:
            "The WALI Lock Screen Helper returned an invalid response."
        case .sourceRejected:
            "The verified wallpaper could not be prepared for Lock Screen continuity."
        }
    }
}

public struct LockScreenHelperReleaseIntent: Sendable, Hashable {
    public let releaseID: UUID
    public let assetID: UUID
    public let title: String
    public let masterSHA256: String
    public let posterURL: URL

    public init(
        releaseID: UUID,
        assetID: UUID,
        title: String,
        masterSHA256: String,
        posterURL: URL
    ) {
        self.releaseID = releaseID
        self.assetID = assetID
        self.title = title
        self.masterSHA256 = masterSHA256
        self.posterURL = posterURL
    }
}

public protocol LockScreenHelperTransport: Sendable {
    func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data
}

public enum LockScreenOperationName: String, Sendable {
    case status
    case activateVerifiedRelease
    case deactivate
    case restore
}

private protocol LockScreenHeaderProviding {
    var header: LockScreenHelperRequestHeader { get }
}

extension LockScreenHelperStatusRequest: LockScreenHeaderProviding {}
extension LockScreenHelperActivationRequest: LockScreenHeaderProviding {}
extension LockScreenHelperMutationRequest: LockScreenHeaderProviding {}

private final class LockScreenOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Data, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private final class LockScreenConnectionEndHandler: @unchecked Sendable {
    private weak var owner: LockScreenHelperXPCTransport?
    private let identifier: UUID

    init(owner: LockScreenHelperXPCTransport, identifier: UUID) {
        self.owner = owner
        self.identifier = identifier
    }

    func notify() {
        guard let owner else { return }
        Task { await owner.connectionEnded(identifier) }
    }
}

public actor LockScreenHelperXPCTransport: LockScreenHelperTransport {
    private let serviceName: String
    private var connection: NSXPCConnection?
    private var connectionID: UUID?

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    public func send(_ operation: LockScreenOperationName, request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = LockScreenOneShot(continuation)
            guard let proxy = activeConnection().remoteObjectProxyWithErrorHandler({ _ in
                oneShot.resume(with: .failure(LockScreenHelperConnectionError.unavailable))
            }) as? WALILockScreenHelperXPCProtocol else {
                oneShot.resume(with: .failure(LockScreenHelperConnectionError.unavailable))
                return
            }
            let reply: (Data?, NSError?) -> Void = { data, error in
                if let data {
                    oneShot.resume(with: .success(data))
                } else {
                    oneShot.resume(
                        with: .failure(
                            error ?? LockScreenHelperConnectionError.invalidResponse as NSError
                        )
                    )
                }
            }
            switch operation {
            case .status: proxy.status(request, withReply: reply)
            case .activateVerifiedRelease: proxy.activateVerifiedRelease(request, withReply: reply)
            case .deactivate: proxy.deactivate(request, withReply: reply)
            case .restore: proxy.restore(request, withReply: reply)
            }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
        connectionID = nil
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let identifier = UUID()
        let created = NSXPCConnection(machServiceName: serviceName)
        let endHandler = LockScreenConnectionEndHandler(owner: self, identifier: identifier)
        created.remoteObjectInterface = NSXPCInterface(with: WALILockScreenHelperXPCProtocol.self)
        created.interruptionHandler = { endHandler.notify() }
        created.invalidationHandler = { endHandler.notify() }
        created.resume()
        connection = created
        connectionID = identifier
        return created
    }

    fileprivate func connectionEnded(_ identifier: UUID) {
        guard connectionID == identifier else { return }
        connection = nil
        connectionID = nil
    }
}

public actor LockScreenHelperConnection {
    private let transport: any LockScreenHelperTransport
    private let preparedThumbnailRoot: URL
    private var revision: UInt64?

    public init(
        transport: any LockScreenHelperTransport,
        preparedThumbnailRoot: URL
    ) {
        self.transport = transport
        self.preparedThumbnailRoot = preparedThumbnailRoot.standardizedFileURL
    }

    public static func live(libraryPaths: LibraryPaths) -> LockScreenHelperConnection {
        let serviceName = Bundle.main.object(
            forInfoDictionaryKey: "WALILockScreenHelperServiceName"
        ) as? String ?? "com.wali.WALILockScreenHelper.control"
        return LockScreenHelperConnection(
            transport: LockScreenHelperXPCTransport(serviceName: serviceName),
            preparedThumbnailRoot: libraryPaths.metadata
                .appendingPathComponent("LockScreenPrepared", isDirectory: true)
        )
    }

    @discardableResult
    public func status() async throws -> LockScreenHelperStatus {
        let header = LockScreenHelperRequestHeader(
            expectedRevision: revision ?? 0,
            payloadLength: 0
        )
        let response = try await perform(
            .status,
            request: LockScreenHelperStatusRequest(header: header)
        )
        try requireAvailable(response.status)
        revision = response.revision
        return response.status
    }

    public func activate(
        _ intent: LockScreenHelperReleaseIntent,
        restartPlayback: Bool
    ) async throws {
        let thumbnailDigest = try prepareThumbnail(from: intent.posterURL)
        if revision == nil { _ = try await status() }
        let release = LockScreenVerifiedRelease(
            releaseID: intent.releaseID,
            assetID: intent.assetID,
            title: intent.title,
            masterSHA256: intent.masterSHA256,
            thumbnailSHA256: thumbnailDigest,
            compatibilityRevision: 1
        )
        let payloadLength = try LockScreenHelperWire.canonicalPayloadLength(release)
        let header = LockScreenHelperRequestHeader(
            expectedRevision: revision ?? 0,
            payloadLength: payloadLength
        )
        let response = try await perform(
            .activateVerifiedRelease,
            request: LockScreenHelperActivationRequest(
                header: header,
                release: release,
                restartPlayback: restartPlayback
            )
        )
        try requireAvailable(response.status)
        revision = response.revision
    }

    public func deactivate() async throws {
        try await mutate(.deactivate)
    }

    public func restore() async throws {
        try await mutate(.restore)
    }

    private func mutate(_ operation: LockScreenOperationName) async throws {
        if revision == nil { _ = try await status() }
        let header = LockScreenHelperRequestHeader(
            expectedRevision: revision ?? 0,
            payloadLength: 0
        )
        let response = try await perform(
            operation,
            request: LockScreenHelperMutationRequest(header: header)
        )
        try requireAvailable(response.status)
        revision = response.revision
    }

    private func perform<Request: Encodable & LockScreenHeaderProviding>(
        _ operation: LockScreenOperationName,
        request: Request
    ) async throws -> LockScreenHelperResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)
        guard requestData.count <= LockScreenHelperWire.maximumRequestBytes else {
            throw LockScreenHelperConnectionError.sourceRejected
        }
        let responseData = try await transport.send(operation, request: requestData)
        guard responseData.count <= LockScreenHelperWire.maximumResponseBytes,
              let response = try? JSONDecoder().decode(
                  LockScreenHelperResponse.self,
                  from: responseData
              ),
              response.requestID == request.header.requestID,
              response.status.protocolVersion == LockScreenHelperWire.protocolVersion,
              response.status.messageVersion == LockScreenHelperWire.messageVersion else {
            throw LockScreenHelperConnectionError.invalidResponse
        }
        return response
    }

    private func requireAvailable(_ status: LockScreenHelperStatus) throws {
        switch status.permission {
        case .available: return
        case .permissionRequired: throw LockScreenHelperConnectionError.permissionRequired
        case .unsupportedBuild: throw LockScreenHelperConnectionError.unsupportedBuild
        case .unavailable: throw LockScreenHelperConnectionError.unavailable
        }
    }

    private func prepareThumbnail(from posterURL: URL) throws -> String {
        guard posterURL.isFileURL,
              let source = CGImageSourceCreateWithURL(posterURL as CFURL, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1_920,
              ] as CFDictionary) else {
            throw LockScreenHelperConnectionError.sourceRejected
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            bytes,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw LockScreenHelperConnectionError.sourceRejected }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LockScreenHelperConnectionError.sourceRejected
        }
        let data = bytes as Data
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(
            at: preparedThumbnailRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try ContentStorage.requireDirectoryWithoutSymlink(preparedThumbnailRoot)
        let destinationURL = preparedThumbnailRoot.appendingPathComponent("\(digest).png")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try ContentStorage.requireContainedRegularFile(
                destinationURL,
                under: preparedThumbnailRoot
            )
            guard try Data(contentsOf: destinationURL) == data else {
                throw LockScreenHelperConnectionError.sourceRejected
            }
        } else {
            try data.write(to: destinationURL, options: .withoutOverwriting)
            guard chmod(destinationURL.path, 0o444) == 0 else {
                throw LockScreenHelperConnectionError.sourceRejected
            }
        }
        return digest
    }
}
