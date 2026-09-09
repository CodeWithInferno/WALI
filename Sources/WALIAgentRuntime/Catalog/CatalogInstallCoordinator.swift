import CryptoKit
import Foundation
import WALICatalog
import WALIEngine
import WALIModel
import WALIWire

public enum CatalogInstallError: Error, Sendable, Equatable {
    case missingDefaultArtifact
    case sourceClaimMismatch
    case invalidQuarantineReference
}

public typealias CatalogTranscodeHandler = @Sendable (TranscoderRequest) async throws -> TranscoderOutput

public struct CatalogInstallResult: Sendable {
    public let item: EngineLibraryItem
    public let completedImport: EngineImportJob?

    public init(item: EngineLibraryItem, completedImport: EngineImportJob? = nil) {
        self.item = item
        self.completedImport = completedImport
    }
}

/// Re-establishes remote trust inside the authenticated agent, then feeds the
/// downloaded canonical source through the existing sandboxed transcoder and
/// content-addressed publication journal.
public actor CatalogInstallCoordinator {
    private let runtimeStore: RuntimeStore
    private let trustStore: CatalogTrustStore
    private let revocationStore: CatalogRevocationStore
    private let quarantineRoot: URL
    private let transcode: CatalogTranscodeHandler

    public init(
        runtimeStore: RuntimeStore,
        trustStore: CatalogTrustStore,
        revocationStore: CatalogRevocationStore,
        quarantineRoot: URL,
        transcode: @escaping CatalogTranscodeHandler
    ) {
        self.runtimeStore = runtimeStore
        self.trustStore = trustStore
        self.revocationStore = revocationStore
        self.quarantineRoot = quarantineRoot.standardizedFileURL
        self.transcode = transcode
    }

    public func install(
        _ request: AgentCatalogInstallRequest,
        idempotencyKey: UUID,
        acceptedRevision: EngineRevision
    ) async throws -> CatalogInstallResult {
        let quarantineURL = quarantineRoot.appendingPathComponent(
            "\(request.quarantineReference.uuidString.lowercased()).wali-quarantine.mp4",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: quarantineURL) }
        let revocations = try await revocationStore.current()
        let verified = try await trustStore.verify(request, revocations: revocations)
        guard let defaultArtifact = verified.manifest.manifest.artifacts.first(where: {
            $0.role == .videoDefault
        }) else {
            throw CatalogInstallError.missingDefaultArtifact
        }
        let manifestDigest = verified.origin.manifestDigest
        if let existing = try await runtimeStore.installedCatalogRecord(
            releaseID: verified.manifest.manifest.releaseID,
            manifestDigest: manifestDigest
        ) {
            return try CatalogInstallResult(item: LibraryRecordFactory.makeEngineItem(from: existing))
        }

        let sourceDigest = try ContentDigest(
            algorithm: .sha256,
            value: defaultArtifact.sha256
        )
        let ownedSourceURL = try await runtimeStore.adoptCatalogQuarantine(
            quarantineURL,
            under: quarantineRoot,
            expectedDigest: sourceDigest,
            expectedByteCount: defaultArtifact.byteCount
        )
        do {
            #if WALI_APP_STORE
            let sourceBookmark = try AgentSourceAuthorization.createPersistent(forOwnedSource: ownedSourceURL)
            #else
            let sourceBookmark = try ownedSourceURL.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
            let startedAt = Date()
            let context = try await runtimeStore.beginImport(
                sourceURL: ownedSourceURL,
                sourceBookmark: sourceBookmark,
                idempotencyKey: IdempotencyKey(idempotencyKey.uuidString.lowercased()),
                expectedEngineRevision: acceptedRevision
            )
            do {
                try await runtimeStore.markImportDispatched(
                    jobID: context.jobID,
                    generation: context.generation
                )
                guard let jobUUID = UUID(uuidString: context.jobID.rawValue) else {
                    throw CatalogInstallError.invalidQuarantineReference
                }
                let output = try await transcode(TranscoderRequest(
                    jobID: jobUUID,
                    attemptGeneration: context.generation.rawValue,
                    sourceBookmark: sourceBookmark,
                    sourceURL: ownedSourceURL,
                    stagingDirectoryURL: context.stagingDirectoryURL,
                    sourceByteLimit: defaultArtifact.byteCount
                ))
                guard output.sourceDigest == defaultArtifact.sha256 else {
                    throw CatalogInstallError.sourceClaimMismatch
                }
                try await runtimeStore.finishImportAttempt(
                    jobID: context.jobID,
                    generation: context.generation,
                    outcome: .succeeded
                )
                var installed: [StoredArtifact] = []
                for claim in output.artifacts {
                    try Task.checkCancellation()
                    let candidate = try StagedArtifactCandidate(
                        jobID: context.jobID,
                        generation: context.generation,
                        role: claim.storageRole,
                        mediaKind: claim.storageMediaKind,
                        stagedURL: claim.stagedURL,
                        claimedDigest: try ContentDigest(algorithm: .sha256, value: claim.digest),
                        claimedByteCount: claim.byteCount
                    )
                    installed.append(try await runtimeStore.installArtifact(candidate))
                }
                let record = try LibraryRecordFactory.makeCatalogRecord(
                    displayName: verified.metadata.metadata.title,
                    sourceDigest: sourceDigest,
                    origin: verified.origin,
                    artifacts: installed
                )
                try await runtimeStore.commitImport(
                    jobID: context.jobID,
                    generation: context.generation,
                    record: record
                )
                let item = try LibraryRecordFactory.makeEngineItem(from: record)
                try? await runtimeStore.removeAdoptedCatalogSource(ownedSourceURL)
                return CatalogInstallResult(
                    item: item,
                    completedImport: EngineImportJob(
                        id: idempotencyKey, fileName: item.name,
                        phase: .complete, progress: 1, createdAt: startedAt
                    )
                )
            } catch {
                try? await runtimeStore.finishImportAttempt(
                    jobID: context.jobID,
                    generation: context.generation,
                    outcome: .failed
                )
                #if WALI_APP_STORE
                try? await runtimeStore.failCatalogImportForFreshRetry(jobID: context.jobID)
                #endif
                throw error
            }
        } catch {
            try? await runtimeStore.removeAdoptedCatalogSource(ownedSourceURL)
            throw error
        }
    }

    public func updateRevocations(_ update: AgentCatalogRevocationUpdate) async throws {
        try await revocationStore.update(update)
    }

    public func updateTrustTransition(
        _ update: AgentCatalogTrustTransitionUpdate
    ) async throws {
        try await trustStore.updateTransition(update)
    }

    public static func defaultQuarantineRoot(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.wali.WALIAgent",
        fileManager: FileManager = .default
    ) throws -> URL {
        #if WALI_APP_STORE
        return try StoreSharedDirectories.quarantine(fileManager: fileManager)
        #else
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let namespace = bundleIdentifier.split(separator: ".").dropLast().joined(separator: ".")
        guard !namespace.isEmpty else { throw CatalogInstallError.invalidQuarantineReference }
        return base
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("CatalogQuarantine", isDirectory: true)
        #endif
    }
}


public enum CatalogTrustStoreError: Error, Sendable, Equatable {
    case invalidConfiguration
    case requestMismatch
    case manifestDigestMismatch
}

private struct PersistedCatalogTrustTransition: Codable {
    let revision: UInt64
    let canonicalBody: Data
    let signatureBase64URL: String
    let keyID: String
}

public struct VerifiedAgentCatalogInstall: Sendable, Hashable {
    public let manifest: VerifiedCatalogManifest
    public let metadata: VerifiedCatalogInstallMetadata
    public let origin: CatalogLibraryOriginSnapshot
}

/// Agent-owned trust state. Compiled keys are the only roots authorized to
/// sign cumulative transitions; network state never replaces those anchors.
public actor CatalogTrustStore {
    private let transitionVerifier: CatalogTrustTransitionVerifier
    private let approvedCDNHosts: Set<String>
    private let fileURL: URL?
    private var trustedKeys: [TrustedCatalogSigningKey]
    private var currentTransition: VerifiedCatalogTrustTransition?
    private var didLoad = false

    public init(
        trustedKeys: [TrustedCatalogSigningKey],
        approvedCDNHosts: Set<String>,
        fileURL: URL? = nil
    ) throws {
        transitionVerifier = try CatalogTrustTransitionVerifier(compiledAnchors: trustedKeys)
        _ = try ManifestVerifier(
            trustedKeys: trustedKeys,
            approvedCDNHosts: approvedCDNHosts
        )
        self.trustedKeys = trustedKeys
        self.approvedCDNHosts = approvedCDNHosts
        self.fileURL = fileURL
    }

    public static func configured(
        bundle: Bundle = .main,
        fileURL: URL? = nil
    ) throws -> CatalogTrustStore {
        guard let keyIDValue = bundle.object(
            forInfoDictionaryKey: "WALICatalogSigningKeyID"
        ) as? String,
            let publicKeyValue = bundle.object(
                forInfoDictionaryKey: "WALICatalogSigningPublicKeyBase64"
            ) as? String,
            let publicKey = Data.catalogKeyDecoded(publicKeyValue),
            let hostValue = bundle.object(forInfoDictionaryKey: "WALIApprovedCDNHosts") as? String
        else {
            throw CatalogTrustStoreError.invalidConfiguration
        }
        var keys = [try configuredKey(id: keyIDValue, publicKey: publicKey)]
        let recoveryID = bundle.object(
            forInfoDictionaryKey: "WALICatalogRecoverySigningKeyID"
        ) as? String
        let recoveryValue = bundle.object(
            forInfoDictionaryKey: "WALICatalogRecoverySigningPublicKeyBase64"
        ) as? String
        guard (recoveryID == nil) == (recoveryValue == nil) else {
            throw CatalogTrustStoreError.invalidConfiguration
        }
        if let recoveryID, let recoveryValue {
            guard let recoveryKey = Data.catalogKeyDecoded(recoveryValue) else {
                throw CatalogTrustStoreError.invalidConfiguration
            }
            keys.append(try configuredKey(id: recoveryID, publicKey: recoveryKey))
        }
        let hosts = Set(hostValue.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return try CatalogTrustStore(
            trustedKeys: keys,
            approvedCDNHosts: hosts,
            fileURL: fileURL
        )
    }

    public func verify(
        _ request: AgentCatalogInstallRequest,
        revocations: CatalogRevocationList?
    ) throws -> VerifiedAgentCatalogInstall {
        try loadIfNeeded()
        let decoded: CatalogManifest
        do {
            decoded = try JSONDecoder().decode(CatalogManifest.self, from: request.canonicalManifest)
        } catch {
            throw CatalogTrustStoreError.requestMismatch
        }
        let context = try CatalogVerificationContext(
            wallpaperID: decoded.wallpaperID,
            releaseID: decoded.releaseID,
            metadataDigest: decoded.metadataDigest
        )
        let verifier = try manifestVerifier()
        let verifiedManifest = try verifier.verify(
            manifestData: request.canonicalManifest,
            signatureBase64URL: request.signatureBase64URL,
            context: context,
            revocations: revocations
        )
        guard verifiedManifest.manifest.keyID.rawValue == request.keyID else {
            throw CatalogTrustStoreError.requestMismatch
        }
        let verifiedMetadata = try verifier.verifyMetadata(
            request.canonicalMetadata,
            for: verifiedManifest
        )
        let digest = SHA256.hash(data: request.canonicalManifest)
            .map { String(format: "%02x", $0) }
            .joined()
        let metadata = verifiedMetadata.metadata
        let origin = try CatalogLibraryOriginSnapshot(
            wallpaperID: metadata.wallpaperID,
            releaseID: metadata.releaseID,
            edition: metadata.edition,
            creatorName: metadata.creatorName,
            creatorHandle: metadata.creatorHandle,
            attributionText: metadata.attributionText.isEmpty ? nil : metadata.attributionText,
            rightsHolder: metadata.rightsHolder,
            manifestDigest: ContentDigest(algorithm: .sha256, value: digest)
        )
        return VerifiedAgentCatalogInstall(
            manifest: verifiedManifest,
            metadata: verifiedMetadata,
            origin: origin
        )
    }

    public func updateTransition(_ update: AgentCatalogTrustTransitionUpdate) throws {
        try loadIfNeeded()
        let keyID = try CatalogKeyID(update.keyID)
        let verified: VerifiedCatalogTrustTransition
        if let currentTransition {
            verified = try transitionVerifier.verifySuccessor(
                data: update.canonicalBody,
                signatureBase64URL: update.signatureBase64URL,
                signingKeyID: keyID,
                previous: currentTransition
            )
            if verified == currentTransition { return }
        } else {
            verified = try transitionVerifier.verify(
                data: update.canonicalBody,
                signatureBase64URL: update.signatureBase64URL,
                signingKeyID: keyID
            )
        }
        guard verified.transition.revision == update.revision else {
            throw CatalogTrustStoreError.requestMismatch
        }
        try persist(update)
        currentTransition = verified
        trustedKeys = verified.trustedKeys
    }

    public func verifyRevocations(
        _ update: AgentCatalogRevocationUpdate
    ) throws -> CatalogRevocationList {
        try loadIfNeeded()
        let list = try manifestVerifier().verifyRevocations(
            data: update.canonicalBody,
            signatureBase64URL: update.signatureBase64URL
        )
        guard list.keyID.rawValue == update.keyID,
              list.revision == update.revision
        else {
            throw CatalogTrustStoreError.requestMismatch
        }
        return list
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            didLoad = true
            return
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count <= AgentCatalogTrustTransitionUpdate.maximumBodyBytes * 2 else {
                throw CatalogTrustStoreError.invalidConfiguration
            }
            let persisted = try JSONDecoder().decode(PersistedCatalogTrustTransition.self, from: data)
            let verified = try transitionVerifier.verify(
                data: persisted.canonicalBody,
                signatureBase64URL: persisted.signatureBase64URL,
                signingKeyID: CatalogKeyID(persisted.keyID)
            )
            guard verified.transition.revision == persisted.revision else {
                throw CatalogTrustStoreError.requestMismatch
            }
            currentTransition = verified
            trustedKeys = verified.trustedKeys
            didLoad = true
        } catch let error as CatalogTrustStoreError {
            throw error
        } catch {
            throw CatalogTrustStoreError.invalidConfiguration
        }
    }

    private func manifestVerifier() throws -> ManifestVerifier {
        try ManifestVerifier(
            trustedKeys: trustedKeys,
            approvedCDNHosts: approvedCDNHosts
        )
    }

    private func persist(_ update: AgentCatalogTrustTransitionUpdate) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(PersistedCatalogTrustTransition(
            revision: update.revision,
            canonicalBody: update.canonicalBody,
            signatureBase64URL: update.signatureBase64URL,
            keyID: update.keyID
        ))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func configuredKey(
        id: String,
        publicKey: Data
    ) throws -> TrustedCatalogSigningKey {
        try TrustedCatalogSigningKey(
            id: CatalogKeyID(id),
            publicKey: publicKey,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: Date(timeIntervalSince1970: 4_102_444_800),
            status: .active
        )
    }
}

private extension Data {
    static func catalogKeyDecoded(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value), data.count == 32 { return data }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        guard let data = Data(base64Encoded: normalized), data.count == 32 else { return nil }
        return data
    }
}

private struct PersistedCatalogRevocations: Codable {
    let revision: UInt64
    let canonicalBody: Data
    let signatureBase64URL: String
    let keyID: String
}

/// Agent-owned verified revocation cache. A revocation can block catalog
/// install, but this store has no API that removes an installed local item.
public actor CatalogRevocationStore {
    private let fileURL: URL?
    private let trustStore: CatalogTrustStore
    private var currentList: CatalogRevocationList?
    private var didLoad = false

    public init(fileURL: URL? = nil, trustStore: CatalogTrustStore) {
        self.fileURL = fileURL
        self.trustStore = trustStore
    }

    public func current() async throws -> CatalogRevocationList? {
        try await loadIfNeeded()
        return currentList
    }

    public func update(_ update: AgentCatalogRevocationUpdate) async throws {
        try await loadIfNeeded()
        let verified = try await trustStore.verifyRevocations(update)
        guard currentList.map({ verified.revision >= $0.revision }) ?? true else {
            throw CatalogTrustStoreError.requestMismatch
        }
        if let currentList, verified.revision == currentList.revision {
            guard verified == currentList else {
                throw CatalogTrustStoreError.requestMismatch
            }
            return
        }
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoded = try JSONEncoder().encode(PersistedCatalogRevocations(
                revision: update.revision,
                canonicalBody: update.canonicalBody,
                signatureBase64URL: update.signatureBase64URL,
                keyID: update.keyID
            ))
            try encoded.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        currentList = verified
    }

    private func loadIfNeeded() async throws {
        guard !didLoad else { return }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            didLoad = true
            return
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= AgentCatalogRevocationUpdate.maximumBodyBytes * 2 else {
            throw CatalogTrustStoreError.invalidConfiguration
        }
        let persisted = try JSONDecoder().decode(PersistedCatalogRevocations.self, from: data)
        currentList = try await trustStore.verifyRevocations(AgentCatalogRevocationUpdate(
            revision: persisted.revision,
            canonicalBody: persisted.canonicalBody,
            signatureBase64URL: persisted.signatureBase64URL,
            keyID: persisted.keyID
        ))
        didLoad = true
    }
}
