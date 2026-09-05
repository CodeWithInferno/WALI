import CryptoKit
import Foundation
import OSLog
import WALICatalog

public actor CatalogCache {
    private let root: URL
    private let maximumEntryBytes: Int

    public init(root: URL, maximumEntryBytes: Int = 1_048_576) throws {
        guard maximumEntryBytes > 0 else { throw CatalogRequestError.invalidConfiguration }
        self.root = root
        self.maximumEntryBytes = maximumEntryBytes
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func data(forPublicKey key: String) throws -> Data? {
        let url = entryURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumEntryBytes else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    public func storePublicData(_ data: Data, forKey key: String) throws {
        guard data.count <= maximumEntryBytes else { throw CatalogMappingError.responseTooLarge }
        let url = entryURL(for: key)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func removeAllPublicData() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        for entry in entries { try FileManager.default.removeItem(at: entry) }
    }

    private func entryURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest, directoryHint: .notDirectory)
    }
}

public struct CatalogRemoteURLPolicy: Sendable, Hashable {
    private let supabaseHost: String
    private let mediaHosts: Set<String>

    public init(supabaseURL: URL, approvedCDNHosts: Set<String>) throws {
        guard Self.isCanonicalHTTPS(supabaseURL),
              (supabaseURL.path.isEmpty || supabaseURL.path == "/"),
              let host = Self.canonicalHost(supabaseURL),
              !approvedCDNHosts.isEmpty,
              approvedCDNHosts.allSatisfy(validateCatalogPublicHostname)
        else {
            throw CatalogRequestError.invalidConfiguration
        }
        supabaseHost = host
        mediaHosts = approvedCDNHosts
    }

    public func allowsMedia(_ url: URL) -> Bool {
        Self.isCanonicalHTTPS(url)
            && url.host.map { mediaHosts.contains($0.lowercased()) } == true
    }

    public func allowsUpload(_ url: URL) -> Bool {
        Self.isCanonicalHTTPS(url)
            && url.host.map { mediaHosts.union([supabaseHost]).contains($0.lowercased()) } == true
    }

    public func allowsControlPlane(_ url: URL) -> Bool {
        Self.isCanonicalHTTPS(url) && Self.canonicalHost(url) == supabaseHost
    }

    public func allowsSignedAccountExport(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil,
              url.query?.isEmpty == false,
              url.absoluteString.utf8.count <= 4_096,
              Self.canonicalHost(url) == supabaseHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "token",
              let token = components.queryItems?.first?.value,
              (6...4_096).contains(token.utf8.count)
        else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 9,
              parts[0...5] == ["storage", "v1", "object", "sign", "exports-private", "exports"],
              UUID(uuidString: parts[6])?.uuidString.lowercased() == parts[6],
              UUID(uuidString: parts[7])?.uuidString.lowercased() == parts[7],
              parts[8] == "account.json"
        else { return false }
        return true
    }

    public func allowsSignedAccountExport(
        _ url: URL,
        subjectID: String,
        exportID: String
    ) -> Bool {
        guard allowsSignedAccountExport(url) else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts[6] == subjectID && parts[7] == exportID
    }

    public func allowsSignedModeratorArtifact(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= 4_096,
              Self.canonicalHost(url) == supabaseHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "token",
              let token = components.queryItems?.first?.value,
              (16...4_096).contains(token.utf8.count)
        else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 10,
              parts[0...5] == ["storage", "v1", "object", "sign", "processing-private", "sha256"],
              parts[6].utf8.count == 2,
              parts[7].utf8.count == 2,
              parts[8].utf8.count == 64,
              parts[8].hasPrefix(parts[6] + parts[7]),
              parts[6...8].allSatisfy({ part in
                  part.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
              }),
              (1...80).contains(parts[9].utf8.count),
              parts[9].utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              })
        else { return false }
        return true
    }

    static func isCanonicalHTTPS(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= 2_048,
              let host = canonicalHost(url),
              validateCatalogPublicHostname(host)
        else {
            return false
        }
        return true
    }

    private static func canonicalHost(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased(),
              host == url.host(percentEncoded: false),
              validateCatalogPublicHostname(host)
        else {
            return nil
        }
        return host
    }
}

final class RejectCatalogRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.wali.catalog", category: "Transport")

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        let protocolName = ["h2", "h3", "http/1.1"].contains(last.networkProtocolName ?? "")
            ? last.networkProtocolName! : "other"
        Self.logger.debug("Catalog transport: protocol=\(protocolName, privacy: .public) reused=\(last.isReusedConnection, privacy: .public) durationMs=\(Int(metrics.taskInterval.duration * 1_000), privacy: .public) status=\((last.response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
    }

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

enum CatalogURLSessionFactory {
    static func redirectRejecting(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: RejectCatalogRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

public enum CatalogSecurityStateError: String, Error, Sendable, Equatable {
    case unavailable
    case corruptCache
    case invalidResponse
}

public struct CatalogSecuritySnapshot: Sendable, Hashable {
    public let trustTransition: CatalogSignedDocument?
    public let revocations: CatalogSignedDocument
    public let trustedKeys: [TrustedCatalogSigningKey]
    public let revocationList: CatalogRevocationList

    public init(
        trustTransition: CatalogSignedDocument?,
        revocations: CatalogSignedDocument,
        trustedKeys: [TrustedCatalogSigningKey],
        revocationList: CatalogRevocationList
    ) {
        self.trustTransition = trustTransition
        self.revocations = revocations
        self.trustedKeys = trustedKeys
        self.revocationList = revocationList
    }
}

public actor CatalogSecurityStateStore {
    private let cacheURL: URL?
    private let compiledAnchors: [TrustedCatalogSigningKey]
    private let transitionVerifier: CatalogTrustTransitionVerifier
    private let approvedCDNHosts: Set<String>
    private var current: CatalogSecuritySnapshot?
    private var didLoad = false

    public init(environment: CatalogEnvironment, cacheURL: URL? = nil) throws {
        let anchors = try environment.compiledTrustAnchors()
        compiledAnchors = anchors
        transitionVerifier = try CatalogTrustTransitionVerifier(compiledAnchors: anchors)
        approvedCDNHosts = environment.approvedCDNHosts
        self.cacheURL = cacheURL
    }

    public static func defaultCacheURL(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let namespace = bundleIdentifier.split(separator: ".").dropLast().joined(separator: ".")
        guard !namespace.isEmpty else { throw CatalogSecurityStateError.unavailable }
        return base
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("CatalogSecurity", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    public func accept(_ state: CatalogSecurityState) throws -> CatalogSecuritySnapshot {
        try loadIfNeeded()
        let snapshot = try validate(state, previous: current)
        if snapshot != current {
            try persist(state: CatalogSecurityState(
                trustTransition: snapshot.trustTransition,
                revocations: snapshot.revocations
            ))
            current = snapshot
        }
        return snapshot
    }

    public func lastKnownGood() throws -> CatalogSecuritySnapshot {
        try loadIfNeeded()
        guard let current else { throw CatalogSecurityStateError.unavailable }
        return current
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else {
            didLoad = true
            return
        }
        do {
            let data = try Data(contentsOf: cacheURL, options: [.mappedIfSafe])
            guard data.count <= 2_500_000 else { throw CatalogSecurityStateError.corruptCache }
            let persisted = try JSONDecoder().decode(CatalogSecurityState.self, from: data)
            current = try validate(persisted, previous: nil)
            didLoad = true
        } catch let error as CatalogSecurityStateError {
            throw error
        } catch {
            throw CatalogSecurityStateError.corruptCache
        }
    }

    private func validate(
        _ state: CatalogSecurityState,
        previous: CatalogSecuritySnapshot?
    ) throws -> CatalogSecuritySnapshot {
        let transition: CatalogSignedDocument?
        let trustedKeys: [TrustedCatalogSigningKey]
        if let candidate = state.trustTransition {
            let keyID = try CatalogKeyID(candidate.keyID)
            let verified: VerifiedCatalogTrustTransition
            if let prior = previous?.trustTransition {
                let priorVerified = try transitionVerifier.verify(
                    data: prior.canonicalBody,
                    signatureBase64URL: prior.signatureBase64URL,
                    signingKeyID: CatalogKeyID(prior.keyID)
                )
                verified = try transitionVerifier.verifySuccessor(
                    data: candidate.canonicalBody,
                    signatureBase64URL: candidate.signatureBase64URL,
                    signingKeyID: keyID,
                    previous: priorVerified
                )
            } else {
                verified = try transitionVerifier.verify(
                    data: candidate.canonicalBody,
                    signatureBase64URL: candidate.signatureBase64URL,
                    signingKeyID: keyID
                )
            }
            guard candidate.revision == verified.transition.revision else {
                throw CatalogSecurityStateError.invalidResponse
            }
            if let prior = previous?.trustTransition,
               candidate.revision == prior.revision,
               candidate.canonicalBody == prior.canonicalBody {
                transition = prior
            } else {
                transition = candidate
            }
            trustedKeys = verified.trustedKeys
        } else if let previous {
            transition = previous.trustTransition
            trustedKeys = previous.trustedKeys
        } else {
            transition = nil
            trustedKeys = compiledAnchors
        }

        let revocations = state.revocations
        guard revocations.canonicalBody.count <= 1_048_576,
              revocations.signatureBase64URL.utf8.count <= 86,
              revocations.keyID.utf8.count <= 64
        else {
            throw CatalogSecurityStateError.invalidResponse
        }
        let manifestVerifier = try ManifestVerifier(
            trustedKeys: trustedKeys,
            approvedCDNHosts: approvedCDNHosts
        )
        let list = try manifestVerifier.verifyRevocations(
            data: revocations.canonicalBody,
            signatureBase64URL: revocations.signatureBase64URL
        )
        guard list.revision == revocations.revision,
              list.keyID.rawValue == revocations.keyID
        else {
            throw CatalogSecurityStateError.invalidResponse
        }
        var retainedRevocations = revocations
        var retainedList = list
        if let previous {
            if list.revision < previous.revocationList.revision {
                throw CatalogValidationError.staleRevocations
            }
            if list.revision == previous.revocationList.revision {
                guard revocations.canonicalBody == previous.revocations.canonicalBody else {
                    throw CatalogValidationError.revocationEquivocation
                }
                retainedRevocations = previous.revocations
                retainedList = previous.revocationList
            }
        }
        return CatalogSecuritySnapshot(
            trustTransition: transition,
            revocations: retainedRevocations,
            trustedKeys: trustedKeys,
            revocationList: retainedList
        )
    }

    private func persist(state: CatalogSecurityState) throws {
        guard let cacheURL else { return }
        let parent = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
