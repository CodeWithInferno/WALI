import Darwin
import Foundation
import WALIWire

public enum AgentSourceAuthorizationError: LocalizedError, Sendable {
    case invalidGrant, staleGrant, scopeDenied, sourceMismatch, nonregularSource
    public var errorDescription: String? {
        switch self {
        case .invalidGrant: "The source authorization is invalid. Select the source again."
        case .staleGrant: "The source authorization is stale. Select the source again."
        case .scopeDenied: "WALI cannot access the selected source. Select it again."
        case .sourceMismatch: "The source authorization refers to a different file."
        case .nonregularSource: "The source must be a regular file, not a symbolic link."
        }
    }
}

public struct AgentAuthorizedSource: Sendable {
    public let url: URL
    /// Created by the agent identity. Only this app-scoped bookmark is durable.
    public let persistentBookmark: Data
}

/// Owns exactly one successful startAccessing call; close and deinit are idempotent.
public final class AgentSourceAccess: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var isOpen = true
    init(url: URL) { self.url = url }
    public func close() {
        lock.lock()
        let stop = isOpen
        isOpen = false
        lock.unlock()
        if stop { url.stopAccessingSecurityScopedResource() }
    }
    deinit { close() }
}

public enum AgentSourceAuthorization {
    public static func acceptTransient(_ encoded: Data) throws -> AgentAuthorizedSource {
        let grant = try StoreImportGrantCodec.decode(from: encoded)
        let url = try resolve(grant.bookmark, persistent: false)
        guard url.startAccessingSecurityScopedResource() else { throw AgentSourceAuthorizationError.scopeDenied }
        defer { url.stopAccessingSecurityScopedResource() }
        try requireRegularSource(url)
        return AgentAuthorizedSource(url: url, persistentBookmark: try createPersistent(forOwnedSource: url))
    }

    public static func createPersistent(forOwnedSource url: URL) throws -> Data {
        try requireRegularSource(url)
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
        guard !bookmark.isEmpty, bookmark.count <= StoreImportGrant.maximumBookmarkBytes else {
            throw AgentSourceAuthorizationError.invalidGrant
        }
        return bookmark
    }

    public static func openPersistent(_ bookmark: Data, expectedURL: URL? = nil) throws -> AgentSourceAccess {
        let url = try resolve(bookmark, persistent: true)
        guard expectedURL == nil || url.standardizedFileURL == expectedURL?.standardizedFileURL else {
            throw AgentSourceAuthorizationError.sourceMismatch
        }
        guard url.startAccessingSecurityScopedResource() else { throw AgentSourceAuthorizationError.scopeDenied }
        do {
            try requireRegularSource(url)
            return AgentSourceAccess(url: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private static func resolve(_ bookmark: Data, persistent: Bool) throws -> URL {
        guard !bookmark.isEmpty, bookmark.count <= StoreImportGrant.maximumBookmarkBytes else {
            throw AgentSourceAuthorizationError.invalidGrant
        }
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if persistent { options.insert(.withSecurityScope) }
        else { options.insert(.withoutImplicitStartAccessing) }
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AgentSourceAuthorizationError.staleGrant }
        guard url.isFileURL else { throw AgentSourceAuthorizationError.invalidGrant }
        return url
    }

    private static func requireRegularSource(_ url: URL) throws {
        guard url.isFileURL else { throw AgentSourceAuthorizationError.invalidGrant }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentSourceAuthorizationError.scopeDenied }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentSourceAuthorizationError.nonregularSource
        }
    }
}

public enum StoreWorkerRequestFactory {
    /// Source scope is reopened under the agent identity, then attenuated through
    /// the read-only bookmark URL before creating the transient handoff. Signed
    /// tests must prove the resulting implicit grant denies worker writes.
    public static func make(request: TranscoderRequest, persistentBookmark: Data) throws -> StoreTranscoderRequest {
        let source = try AgentSourceAuthorization.openPersistent(persistentBookmark, expectedURL: request.sourceURL)
        defer { source.close() }
        try ContentStorage.requireDirectoryWithoutSymlink(request.stagingDirectoryURL)
        let expectedName = "\(request.jobID.uuidString.lowercased())-\(request.attemptGeneration)"
        guard request.stagingDirectoryURL.lastPathComponent == expectedName,
              request.stagingDirectoryURL.resolvingSymlinksInPath().standardizedFileURL == request.stagingDirectoryURL.standardizedFileURL,
              !source.url.standardizedFileURL.path.hasPrefix(request.stagingDirectoryURL.standardizedFileURL.path + "/") else {
            throw StorageError.pathEscapesStore
        }
        // Keep the full file identity in the transient bookmark. Minimal
        // bookmarks for agent-container resources can resolve stale in the
        // separately sandboxed worker even when their path still matches.
        let sourceGrant = try source.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let stagingGrant = try request.stagingDirectoryURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let result = StoreTranscoderRequest(request: TranscoderRequest(
            jobID: request.jobID, attemptGeneration: request.attemptGeneration,
            sourceBookmark: sourceGrant, sourceURL: source.url,
            stagingDirectoryURL: request.stagingDirectoryURL, sourceByteLimit: request.sourceByteLimit, mediaKind: request.mediaKind
        ), stagingBookmark: stagingGrant)
        _ = try StoreTranscoderWireCodec.encodeRequest(result)
        return result
    }
}
