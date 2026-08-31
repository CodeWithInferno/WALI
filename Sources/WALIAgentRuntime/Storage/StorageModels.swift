import Foundation
import WALIModel

public enum StoredArtifactRole: String, Codable, Sendable, Hashable, CaseIterable {
    case masterVideo = "master_video"
    case previewVideo = "preview_video"
    case posterImage = "poster_image"
}

public enum StoredArtifactMediaKind: String, Codable, Sendable, Hashable {
    case hevcVideo = "hevc_video"
    case heicImage = "heic_image"
}

/// Untrusted worker output presented to the agent for independent installation.
public struct StagedArtifactCandidate: Codable, Sendable, Hashable {
    public let jobID: JobID
    public let generation: AttemptGeneration
    public let role: StoredArtifactRole
    public let mediaKind: StoredArtifactMediaKind
    public let stagedURL: URL
    public let claimedDigest: ContentDigest?
    public let claimedByteCount: UInt64?

    public init(
        jobID: JobID,
        generation: AttemptGeneration,
        role: StoredArtifactRole,
        mediaKind: StoredArtifactMediaKind,
        stagedURL: URL,
        claimedDigest: ContentDigest? = nil,
        claimedByteCount: UInt64? = nil
    ) throws {
        guard stagedURL.isFileURL else { throw StorageError.invalidCandidate }
        self.jobID = jobID
        self.generation = generation
        self.role = role
        self.mediaKind = mediaKind
        self.stagedURL = stagedURL
        self.claimedDigest = claimedDigest
        self.claimedByteCount = claimedByteCount
    }
}

/// Agent-verified immutable artifact ready for release metadata.
public struct StoredArtifact: Codable, Sendable, Hashable {
    public let role: StoredArtifactRole
    public let mediaKind: StoredArtifactMediaKind
    public let digest: ContentDigest
    public let byteCount: UInt64
    public let objectURL: URL
    public let pixelSize: PixelSize
    public let durationSeconds: Double?

    public init(
        role: StoredArtifactRole,
        mediaKind: StoredArtifactMediaKind,
        digest: ContentDigest,
        byteCount: UInt64,
        objectURL: URL,
        pixelSize: PixelSize,
        durationSeconds: Double?
    ) {
        self.role = role
        self.mediaKind = mediaKind
        self.digest = digest
        self.byteCount = byteCount
        self.objectURL = objectURL
        self.pixelSize = pixelSize
        self.durationSeconds = durationSeconds
    }
}

/// UI-ready committed media locations and metadata.
public struct CommittedLibraryRecord: Codable, Sendable, Hashable {
    public let item: LibraryItem
    public let release: AssetRelease
    public let importedAt: Date
    public let sourceFileName: String
    public let artifacts: [StoredArtifact]

    public init(
        item: LibraryItem,
        release: AssetRelease,
        importedAt: Date = Date(),
        sourceFileName: String,
        artifacts: [StoredArtifact]
    ) throws {
        guard artifacts.count == StoredArtifactRole.allCases.count,
              Set(artifacts.map(\.role)) == Set(StoredArtifactRole.allCases),
              Set(release.artifacts.map(\.contentID)) == Set(artifacts.map(\.digest)),
              item.releaseID == release.id,
              !sourceFileName.isEmpty,
              sourceFileName.utf8.count <= 1_024
        else {
            throw StorageError.incompleteRelease
        }
        self.item = item
        self.release = release
        self.importedAt = importedAt
        self.sourceFileName = sourceFileName
        self.artifacts = artifacts.sorted { $0.role.rawValue < $1.role.rawValue }
    }

    public var masterURL: URL? {
        artifacts.first(where: { $0.role == .masterVideo })?.objectURL
    }

    public var previewURL: URL? {
        artifacts.first(where: { $0.role == .previewVideo })?.objectURL
    }

    public var posterURL: URL? {
        artifacts.first(where: { $0.role == .posterImage })?.objectURL
    }

    public var durationSeconds: Double? {
        artifacts.first(where: { $0.role == .masterVideo })?.durationSeconds
    }

    public var pixelSize: PixelSize? {
        artifacts.first(where: { $0.role == .masterVideo })?.pixelSize
    }
}

public struct RuntimePreferences: Codable, Sendable, Hashable {
    public var launchAtLogin: Bool
    public var qualityIntent: PresentationQualityIntent
    public var lowPowerResponse: PresentationLowPowerResponse
    public var previewsOnHover: Bool

    public init(
        launchAtLogin: Bool = false,
        qualityIntent: PresentationQualityIntent = .automatic,
        lowPowerResponse: PresentationLowPowerResponse = .pause,
        previewsOnHover: Bool = true
    ) {
        self.launchAtLogin = launchAtLogin
        self.qualityIntent = qualityIntent
        self.lowPowerResponse = lowPowerResponse
        self.previewsOnHover = previewsOnHover
    }
}

/// Job context that keeps source authorization distinct from cleanup-owned staging.
public struct PersistedImportJob: Codable, Sendable, Hashable {
    public let job: ImportJob
    public let sourceURL: URL
    public let sourceBookmark: Data?
    public let stagingDirectoryName: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        job: ImportJob,
        sourceURL: URL,
        sourceBookmark: Data? = nil,
        stagingDirectoryName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard sourceURL.isFileURL,
              !stagingDirectoryName.isEmpty,
              stagingDirectoryName != ".",
              stagingDirectoryName != "..",
              !stagingDirectoryName.contains("/")
        else {
            throw StorageError.invalidCandidate
        }
        self.job = job
        self.sourceURL = sourceURL
        self.sourceBookmark = sourceBookmark
        self.stagingDirectoryName = stagingDirectoryName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Values needed to dispatch a worker attempt after its intent is durable.
public struct LocalImportContext: Codable, Sendable, Hashable {
    public let jobID: JobID
    public let generation: AttemptGeneration
    public let sourceURL: URL
    public let stagingDirectoryURL: URL

    public init(
        jobID: JobID,
        generation: AttemptGeneration,
        sourceURL: URL,
        stagingDirectoryURL: URL
    ) {
        self.jobID = jobID
        self.generation = generation
        self.sourceURL = sourceURL
        self.stagingDirectoryURL = stagingDirectoryURL
    }
}

public enum InstallJournalPhase: String, Codable, Sendable, Hashable {
    case intentRecorded = "intent_recorded"
    case verifying
    case verified
    case prepared
    case published
    case committed
    case cleanupPending = "cleanup_pending"
    case cleaned
}

public struct ArtifactInstallJournal: Codable, Sendable, Hashable {
    public let id: UUID
    public let jobID: JobID
    public let generation: AttemptGeneration
    public let role: StoredArtifactRole
    public let mediaKind: StoredArtifactMediaKind
    public let stagedURL: URL
    public var phase: InstallJournalPhase
    public var preparedFileName: String?
    public var verifiedDigest: ContentDigest?
    public var publishedObjectURL: URL?
    public var updatedAt: Date
}

public struct ArtifactLease: Codable, Sendable, Hashable {
    public let id: UUID
    public let digest: ContentDigest
    public let holder: String
    public let generation: UInt64
    public var expiresAt: Date
}

public struct ArtifactTombstone: Codable, Sendable, Hashable {
    public let digest: ContentDigest
    public let mediaKind: StoredArtifactMediaKind
    public let createdAt: Date
}

public struct RuntimeSnapshot: Codable, Sendable, Hashable {
    public static let schemaEpoch: UInt16 = 1
    public static let schemaRevision: UInt16 = 0

    public var schemaEpoch: UInt16
    public var schemaRevision: UInt16
    public var revision: UInt64
    public var preferences: RuntimePreferences
    public var library: [CommittedLibraryRecord]
    public var assignments: [DeviceLocalPresentationAssignment]
    public var importJobs: [PersistedImportJob]
    public var installJournals: [ArtifactInstallJournal]
    public var leases: [ArtifactLease]
    public var tombstones: [ArtifactTombstone]

    public init(
        revision: UInt64 = 0,
        preferences: RuntimePreferences = .init(),
        library: [CommittedLibraryRecord] = [],
        assignments: [DeviceLocalPresentationAssignment] = [],
        importJobs: [PersistedImportJob] = [],
        installJournals: [ArtifactInstallJournal] = [],
        leases: [ArtifactLease] = [],
        tombstones: [ArtifactTombstone] = []
    ) {
        schemaEpoch = Self.schemaEpoch
        schemaRevision = Self.schemaRevision
        self.revision = revision
        self.preferences = preferences
        self.library = library
        self.assignments = assignments
        self.importJobs = importJobs
        self.installJournals = installJournals
        self.leases = leases
        self.tombstones = tombstones
    }
}

public struct StorageRecoveryReport: Sendable, Hashable {
    public let abandonedPreparedFiles: Int
    public let abandonedStagingDirectories: Int
    public let removedUnreferencedObjects: Int
    public let completedTombstones: Int
    public let expiredLeases: Int
}

public enum StorageError: Error, Sendable, Equatable {
    case invalidRoot
    case invalidDigest
    case invalidCandidate
    case pathEscapesStore
    case symbolicLinkRejected
    case nonregularFile
    case stateNotOpened
    case unsupportedSchema(epoch: UInt16, revision: UInt16)
    case corruptState(String)
    case digestMismatch
    case byteCountMismatch
    case unsupportedMedia
    case incompleteRelease
    case missingJob
    case staleGeneration
    case jobNotInstallable
    case jobNotRetryable
    case missingPublishedArtifact
    case ioFailure(String)
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "The WALI storage root is invalid."
        case .invalidDigest: "The SHA-256 content identity is invalid."
        case .invalidCandidate: "The staged artifact claim is invalid."
        case .pathEscapesStore: "A path escaped WALI-owned storage."
        case .symbolicLinkRejected: "Symbolic links are not accepted by the content store."
        case .nonregularFile: "The artifact is not a regular file."
        case .stateNotOpened: "Open the runtime store before using it."
        case let .unsupportedSchema(epoch, revision):
            "Storage schema \(epoch).\(revision) is not supported by this version of WALI."
        case let .corruptState(message): "WALI metadata is corrupt: \(message)"
        case .digestMismatch: "The verified content digest differs from the worker claim."
        case .byteCountMismatch: "The verified byte count differs from the worker claim."
        case .unsupportedMedia: "The generated artifact is not valid supported media."
        case .incompleteRelease: "The release does not contain a complete verified artifact set."
        case .missingJob: "The import job is not recorded."
        case .staleGeneration: "The artifact belongs to a stale import attempt."
        case .jobNotInstallable: "The import job is not awaiting installation."
        case .jobNotRetryable: "The import job is not in a retryable terminal-attempt state."
        case .missingPublishedArtifact: "A committed artifact is missing from content storage."
        case let .ioFailure(message): "Local storage failed: \(message)"
        }
    }
}
