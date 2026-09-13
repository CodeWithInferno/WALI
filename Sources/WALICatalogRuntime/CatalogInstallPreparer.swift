import CryptoKit
import Foundation
import WALICatalog

/// Verified, downloaded install material ready for the authenticated local
/// agent handoff. Supabase and catalog implementation types remain below this
/// adapter boundary.
public struct PreparedCatalogInstall: Sendable, Hashable {
    public let canonicalManifest: Data
    public let canonicalMetadata: Data
    public let signatureBase64URL: String
    public let keyID: String
    public let quarantineReference: UUID
    public let manifestDigest: String
    public let wallpaperID: String
    public let releaseID: String
    public let edition: UInt64
}

public struct CatalogInstallPreparer: Sendable {
    private let downloader: CatalogDownloader
    private let quarantineDirectory: URL
    private let approvedCDNHosts: Set<String>

    public init(
        environment: CatalogEnvironment,
        downloader: CatalogDownloader? = nil,
        quarantineDirectory: URL? = nil,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALI"
    ) throws {
        if let downloader {
            self.downloader = downloader
        } else {
            self.downloader = try CatalogDownloader(approvedHosts: environment.approvedCDNHosts)
        }
        self.quarantineDirectory = try quarantineDirectory
            ?? Self.defaultQuarantineDirectory(bundleIdentifier: bundleIdentifier)
        approvedCDNHosts = environment.approvedCDNHosts
    }

    public func prepare(
        grant: CatalogInstallGrant,
        expectedWallpaperID: String,
        expectedReleaseID: String,
        security: CatalogSecuritySnapshot,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws -> PreparedCatalogInstall {
        guard !grant.manifestBody.isEmpty,
              grant.manifestBody.count <= 65_536,
              !grant.metadataBody.isEmpty,
              grant.metadataBody.count <= 16_384,
              !grant.signatureBase64URL.isEmpty,
              grant.signatureBase64URL.utf8.count <= 86,
              !grant.receipt.isEmpty,
              grant.receipt.utf8.count <= 512,
              grant.expiresAt > Date()
        else {
            throw CatalogValidationError.invalidManifest
        }
        let verifier = try ManifestVerifier(
            trustedKeys: security.trustedKeys,
            approvedCDNHosts: approvedCDNHosts
        )
        let decoded = try JSONDecoder().decode(CatalogManifest.self, from: grant.manifestBody)
        let context = try CatalogVerificationContext(
            wallpaperID: expectedWallpaperID,
            releaseID: expectedReleaseID,
            metadataDigest: decoded.metadataDigest
        )
        let verified = try verifier.verify(
            manifestData: grant.manifestBody,
            signatureBase64URL: grant.signatureBase64URL,
            context: context,
            revocations: security.revocationList
        )
        let metadata = try verifier.verifyMetadata(grant.metadataBody, for: verified)
        guard verified.manifest.keyID.rawValue == grant.keyID,
              metadata.metadata.wallpaperID == expectedWallpaperID,
              metadata.metadata.releaseID == expectedReleaseID,
              verified.manifest.mediaKind == grant.mediaKind
        else {
            throw CatalogValidationError.invalidManifest
        }
        let artifact = verified.manifest.primaryArtifact
        progress?(0, artifact.byteCount)
        let quarantineURL = try await downloader.download(
            artifact: artifact,
            quarantineDirectory: quarantineDirectory,
            progress: progress
        )
        let quarantineSuffix = verified.manifest.mediaKind == .still ? ".wali-quarantine.png" : ".wali-quarantine.mp4"
        let quarantineName = quarantineURL.lastPathComponent
        guard quarantineName.hasSuffix(quarantineSuffix),
              let reference = UUID(
                uuidString: String(quarantineName.dropLast(quarantineSuffix.count))
              )
        else {
            try? FileManager.default.removeItem(at: quarantineURL)
            throw CatalogDownloadError.destinationUnavailable
        }
        let manifestDigest = SHA256.hash(data: grant.manifestBody)
            .map { String(format: "%02x", $0) }
            .joined()
        return PreparedCatalogInstall(
            canonicalManifest: grant.manifestBody,
            canonicalMetadata: metadata.canonicalBytes,
            signatureBase64URL: grant.signatureBase64URL,
            keyID: grant.keyID,
            quarantineReference: reference,
            manifestDigest: manifestDigest,
            wallpaperID: verified.manifest.wallpaperID,
            releaseID: verified.manifest.releaseID,
            edition: verified.manifest.edition
        )
    }

    public static func defaultQuarantineDirectory(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        #if WALI_APP_STORE
        let expected = bundleIdentifier.hasPrefix("com.wali.store.development.")
            ? "group.com.wali.store.development.shared" : "group.com.wali.store.shared"
        guard bundleIdentifier.hasPrefix("com.wali.store."),
              Bundle.main.object(forInfoDictionaryKey: "WALIApplicationGroupIdentifier") as? String == expected,
              let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: expected) else {
            throw CatalogDownloadError.destinationUnavailable
        }
        return try storeQuarantineDirectory(in: root, fileManager: fileManager)
        #else
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let namespace = bundleIdentifier.split(separator: ".").dropLast().joined(separator: ".")
        guard !namespace.isEmpty else { throw CatalogDownloadError.destinationUnavailable }
        return base
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("CatalogQuarantine", isDirectory: true)
        #endif
    }

    #if WALI_APP_STORE
    static func storeQuarantineDirectory(in root: URL, fileManager: FileManager = .default) throws -> URL {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0, (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw CatalogDownloadError.destinationUnavailable
        }
        let directory = root.appendingPathComponent("CatalogQuarantine", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // The foreground and agent reopen the same existing handoff directory.
            // Accept only a real directory below; never replace it or change its mode.
        }
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw CatalogDownloadError.destinationUnavailable
        }
        return directory
    }
    #endif

    public func discard(quarantineReference: UUID) {
        for suffix in ["mp4", "png"] {
            let url = quarantineDirectory.appendingPathComponent(
                "\(quarantineReference.uuidString.lowercased()).wali-quarantine.\(suffix)", isDirectory: false
            )
            try? FileManager.default.removeItem(at: url)
        }
    }
}
