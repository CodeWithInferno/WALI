import Darwin
import Foundation
import WALIWire

enum WorkerGrantError: LocalizedError {
    case missingGrant, staleGrant, scopeDenied, identityMismatch, sourceWritable, invalidFile
    var errorDescription: String? {
        switch self {
        case .missingGrant: "The Store worker requires both current-attempt grants."
        case .staleGrant: "The Store media grant is stale."
        case .scopeDenied: "The Store worker could not acquire the required scoped access."
        case .identityMismatch: "The media grant does not match this attempt."
        case .sourceWritable: "The source grant allows writing; Store media access is not sufficiently restricted."
        case .invalidFile: "The media grant does not refer to the required regular file or staging directory."
        }
    }
}

struct WorkerBookmarkOperations: Sendable {
    var resolve: @Sendable (Data) throws -> (url: URL, stale: Bool)
    var start: @Sendable (URL) -> Bool
    var stop: @Sendable (URL) -> Void
    /// Resolving an implicit bookmark acquires a scope before returning its URL.
    var resolutionStartsAccess = false
    var renew: (@Sendable (Data, URL, Bool) throws -> (url: URL, stale: Bool))? = nil
    static let system = Self(resolve: { data in
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }, start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() },
        resolutionStartsAccess: true, renew: renewIdentifiedBookmark)

    /// Caller holds received scope. The returned URL owns one implicit scope;
    /// a failure here releases it before leaving. No renewed bytes are retained.
    private static func renewIdentifiedBookmark(_ data: Data, _ url: URL, _ isDirectory: Bool) throws -> (url: URL, stale: Bool) {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let recorded = URL.resourceValues(forKeys: keys, fromBookmarkData: data),
              let fileID = recorded.fileResourceIdentifier as? NSObject, !(fileID is NSNull),
              let volumeID = recorded.volumeIdentifier as? NSObject, !(volumeID is NSNull),
              url.isFileURL, url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw WorkerGrantError.identityMismatch
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkerGrantError.scopeDenied }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFREG) else {
            throw WorkerGrantError.invalidFile
        }
        let current = try url.resourceValues(forKeys: keys)
        guard let currentFileID = current.fileResourceIdentifier as? NSObject,
              let currentVolumeID = current.volumeIdentifier as? NSObject,
              fileID.isEqual(currentFileID), volumeID.isEqual(currentVolumeID) else {
            throw WorkerGrantError.identityMismatch
        }
        let renewedData = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: keys, relativeTo: nil)
        guard !renewedData.isEmpty, renewedData.count <= StoreImportGrant.maximumBookmarkBytes else {
            throw WorkerGrantError.missingGrant
        }
        var stale = false
        let renewed = try URL(resolvingBookmarkData: renewedData, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
        var transferImplicitAccess = false
        defer { if !transferImplicitAccess { renewed.stopAccessingSecurityScopedResource() } }
        guard !stale else { throw WorkerGrantError.staleGrant }
        guard renewed.isFileURL, renewed.standardizedFileURL == url.standardizedFileURL else {
            throw WorkerGrantError.identityMismatch
        }
        let fresh = try renewed.resourceValues(forKeys: keys)
        var after = stat()
        guard let freshFileID = fresh.fileResourceIdentifier as? NSObject,
              let freshVolumeID = fresh.volumeIdentifier as? NSObject,
              fileID.isEqual(freshFileID), volumeID.isEqual(freshVolumeID),
              lstat(renewed.path, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              (after.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFREG) else {
            throw WorkerGrantError.identityMismatch
        }
        transferImplicitAccess = true
        return (renewed, false)
    }
}

/// The worker holds only the input file and exact attempt directory. It never
/// derives a library/root URL. All acquired scopes and descriptors close once.
final class WorkerScopedMediaAccess: @unchecked Sendable {
    let sourceURL: URL
    let stagingDirectoryURL: URL
    private let operations: WorkerBookmarkOperations
    private let lock = NSLock()
    private var scopes: [URL]
    private var descriptors: [Int32]

    private init(sourceURL: URL, stagingDirectoryURL: URL, operations: WorkerBookmarkOperations,
                 scopes: [URL], descriptors: [Int32]) {
        self.sourceURL = sourceURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.operations = operations
        self.scopes = scopes
        self.descriptors = descriptors
    }

    static func open(_ value: StoreTranscoderRequest,
                     operations: WorkerBookmarkOperations = .system) throws -> WorkerScopedMediaAccess {
        _ = try StoreTranscoderWireCodec.encodeRequest(value)
        var scopes: [URL] = []
        var descriptors: [Int32] = []
        do {
            let source = try resolve(value.request.sourceBookmark, expected: value.request.sourceURL, isDirectory: false, operations: operations)
            scopes.append(source)
            let input = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw WorkerGrantError.scopeDenied }
            descriptors.append(input)
            var info = stat()
            guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size > 0, UInt64(info.st_size) <= value.request.sourceByteLimit else { throw WorkerGrantError.invalidFile }
            // A non-destructive fail-closed check, not a substitute for signed
            // write/truncate/rename denial tests with a normally writable fixture.
            let writable = Darwin.open(source.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if writable >= 0 { Darwin.close(writable); throw WorkerGrantError.sourceWritable }
            guard errno == EACCES || errno == EPERM || errno == EROFS else { throw WorkerGrantError.scopeDenied }

            let staging = try resolve(value.stagingBookmark, expected: value.request.stagingDirectoryURL, isDirectory: true, operations: operations)
            scopes.append(staging)
            guard staging.resolvingSymlinksInPath().standardizedFileURL == staging.standardizedFileURL,
                  !source.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw WorkerGrantError.identityMismatch }
            let directory = Darwin.open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw WorkerGrantError.invalidFile }
            descriptors.append(directory)
            let probeName = ".wali-scope-probe-" + UUID().uuidString.lowercased()
            let probe = openat(directory, probeName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard probe >= 0 else { throw WorkerGrantError.scopeDenied }
            Darwin.close(probe)
            guard unlinkat(directory, probeName, 0) == 0 else { throw WorkerGrantError.scopeDenied }
            return WorkerScopedMediaAccess(sourceURL: source, stagingDirectoryURL: staging, operations: operations,
                                           scopes: scopes, descriptors: descriptors)
        } catch {
            descriptors.reversed().forEach { Darwin.close($0) }
            scopes.reversed().forEach(operations.stop)
            throw error
        }
    }

    private static func resolve(_ data: Data, expected: URL, isDirectory: Bool, operations: WorkerBookmarkOperations) throws -> URL {
        let resolved = try operations.resolve(data)
        // Resolve with implicit access so private-container metadata is available.
        // Transfer that temporary acquisition to one explicit attempt acquisition;
        // stale, mismatched and denied grants must release the resolver's scope too.
        defer {
            if operations.resolutionStartsAccess { operations.stop(resolved.url) }
        }
        guard resolved.url.isFileURL, resolved.url.standardizedFileURL == expected.standardizedFileURL else {
            throw WorkerGrantError.identityMismatch
        }
        if resolved.stale {
            guard operations.resolutionStartsAccess, let renew = operations.renew else { throw WorkerGrantError.staleGrant }
            guard operations.start(resolved.url) else { throw WorkerGrantError.scopeDenied }
            defer { operations.stop(resolved.url) }
            let fresh = try renew(data, resolved.url, isDirectory)
            defer { operations.stop(fresh.url) }
            guard !fresh.stale else { throw WorkerGrantError.staleGrant }
            guard fresh.url.isFileURL, fresh.url.standardizedFileURL == expected.standardizedFileURL else {
                throw WorkerGrantError.identityMismatch
            }
            guard operations.start(fresh.url) else { throw WorkerGrantError.scopeDenied }
            return fresh.url
        }
        guard operations.start(resolved.url) else { throw WorkerGrantError.scopeDenied }
        return resolved.url
    }

    func close() {
        lock.lock()
        let openDescriptors = descriptors
        let openScopes = scopes
        descriptors = []
        scopes = []
        lock.unlock()
        openDescriptors.reversed().forEach { Darwin.close($0) }
        openScopes.reversed().forEach(operations.stop)
    }
    deinit { close() }
}
