import CryptoKit
import Foundation

/// Foreground network recovery only. This record is created after agent-owned
/// verified publication succeeds; it never grants or represents local installation.
public struct CatalogInstallAcknowledgement: Codable, Sendable, Equatable {
    public let subjectID: String
    public let wallpaperID: String
    public let releaseID: String
    public let receipt: String
    public let manifestDigest: String
    public let idempotencyKey: String
    public let expiresAt: Date

    public init(subjectID: String, wallpaperID: String, releaseID: String, receipt: String,
                manifestDigest: String, idempotencyKey: String, expiresAt: Date) throws {
        self.subjectID = subjectID; self.wallpaperID = wallpaperID; self.releaseID = releaseID
        self.receipt = receipt; self.manifestDigest = manifestDigest
        self.idempotencyKey = idempotencyKey; self.expiresAt = expiresAt
        guard isValid else { throw CatalogAcknowledgementError.invalidRecord }
    }

    fileprivate var isValid: Bool {
        [subjectID, wallpaperID, releaseID, receipt].allSatisfy {
            UUID(uuidString: $0)?.uuidString.lowercased() == $0
        } && manifestDigest.count == 64 && manifestDigest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        } && (16...128).contains(idempotencyKey.utf8.count) && idempotencyKey.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && expiresAt.timeIntervalSince1970.isFinite && expiresAt.timeIntervalSince1970 > 0
    }
}

public enum CatalogAcknowledgementError: Error { case invalidRecord, invalidStorage, full, conflictingRecord }

public actor CatalogInstallAcknowledgementStore {
    private struct Envelope: Codable { let schemaVersion: Int; let entries: [CatalogInstallAcknowledgement] }
    private let fileURL: URL?
    private var entries: [CatalogInstallAcknowledgement] = []
    private var loaded = false
    private static let maximumEntries = 128
    private static let maximumBytes = 262_144
    // The server checks expiry for first use but accepts exact completed replays.
    // Keep a bounded window for recovery after a response was lost.
    private static let replayRetention: TimeInterval = 7 * 86_400

    public init(fileURL: URL? = nil) { self.fileURL = fileURL }

    public static func defaultURL(bundleIdentifier: String, projectURL: URL) throws -> URL {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 200,
              bundleIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              projectURL.scheme == "https", projectURL.host != nil, projectURL.user == nil,
              projectURL.password == nil, projectURL.port == nil, projectURL.query == nil, projectURL.fragment == nil,
              projectURL.path.isEmpty || projectURL.path == "/" else { throw CatalogAcknowledgementError.invalidStorage }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let project = SHA256.hash(data: Data((projectURL.host?.lowercased() ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("CatalogAcknowledgements", isDirectory: true)
            .appendingPathComponent(project + ".json")
    }

    public func enqueue(_ entry: CatalogInstallAcknowledgement, now: Date = .now) throws {
        try load()
        guard entry.isValid, entry.expiresAt <= now.addingTimeInterval(86_400) else { throw CatalogAcknowledgementError.invalidRecord }
        entries.removeAll { $0.expiresAt.addingTimeInterval(Self.replayRetention) < now }
        if let old = entries.first(where: { $0.subjectID == entry.subjectID && ($0.idempotencyKey == entry.idempotencyKey || $0.receipt == entry.receipt) }) {
            guard old == entry else { throw CatalogAcknowledgementError.conflictingRecord }
            try persist(); return
        }
        guard entries.count < Self.maximumEntries else { throw CatalogAcknowledgementError.full }
        entries.append(entry)
        // Retain in memory on a disk error so foreground retry remains possible.
        try persist()
    }

    public func pending(subjectID: String, now: Date = .now) throws -> [CatalogInstallAcknowledgement] {
        try load()
        let previous = entries
        entries.removeAll { $0.expiresAt.addingTimeInterval(Self.replayRetention) < now }
        if entries != previous {
            do { try persist() } catch { entries = previous; throw error }
        }
        return entries.filter { $0.subjectID == subjectID }
    }

    public func remove(_ entry: CatalogInstallAcknowledgement) throws {
        try load()
        let previous = entries
        entries.removeAll { $0 == entry }
        do { try persist() } catch { entries = previous; throw error }
    }

    private func load() throws {
        guard !loaded else { return }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { loaded = true; return }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { throw CatalogAcknowledgementError.invalidStorage }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.schemaVersion == 1, envelope.entries.count <= Self.maximumEntries,
              envelope.entries.allSatisfy(\.isValid),
              Set(envelope.entries.map { $0.subjectID + ":" + $0.idempotencyKey }).count == envelope.entries.count,
              Set(envelope.entries.map { $0.subjectID + ":" + $0.receipt }).count == envelope.entries.count
        else { throw CatalogAcknowledgementError.invalidStorage }
        entries = envelope.entries; loaded = true
    }

    private func persist() throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, entries: entries))
        guard data.count <= Self.maximumBytes else { throw CatalogAcknowledgementError.full }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resource = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard resource.isDirectory == true, resource.isSymbolicLink != true else { throw CatalogAcknowledgementError.invalidStorage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CatalogAcknowledgementError.invalidStorage }
        }
        // Write a private sibling before atomic replacement; sensitive recovery
        // metadata is never briefly created with a permissive process umask.
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CatalogAcknowledgementError.invalidStorage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: fileURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
