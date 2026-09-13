import Foundation

/// WALI-owned local paths. All transient and published bytes share one volume.
public struct LibraryPaths: Sendable, Hashable {
    public let root: URL
    public let metadata: URL
    public let staging: URL
    public let prepared: URL
    public let objects: URL

    public init(root: URL) throws {
        guard root.isFileURL else { throw StorageError.invalidRoot }
        let standardized = root.standardizedFileURL
        self.root = standardized
        metadata = standardized.appendingPathComponent("Metadata", isDirectory: true)
        staging = standardized.appendingPathComponent("Staging", isDirectory: true)
        prepared = standardized.appendingPathComponent("Prepared", isDirectory: true)
        objects = standardized
            .appendingPathComponent("Objects", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
    }

    /// Configuration-specific application-support storage for the agent.
    public static func applicationSupport(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALIAgent"
    ) throws -> LibraryPaths {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try LibraryPaths(
            root: base
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        )
    }

    public var stateFile: URL {
        metadata.appendingPathComponent("runtime-state.json", isDirectory: false)
    }

    public func objectURL(
        forSHA256 digest: String,
        mediaKind: StoredArtifactMediaKind
    ) throws -> URL {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw StorageError.invalidDigest
        }
        return objects
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).\(mediaKind.fileExtension)", isDirectory: false)
    }
}

extension StoredArtifactMediaKind {
    var fileExtension: String {
        switch self {
        case .hevcVideo: "mov"
        case .heicImage: "heic"
        case .pngImage: "png"
        }
    }
}
