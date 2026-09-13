import Foundation
import WALIModel

public enum StoredArtifactRole: String, Codable, Sendable, Hashable, CaseIterable {
    case masterVideo = "master_video"
    case previewVideo = "preview_video"
    case posterImage = "poster_image"
    case masterImage = "master_image"

    public static func required(for kind: WallpaperMediaKind) -> Set<Self> {
        switch kind {
        case .video: [.masterVideo, .previewVideo, .posterImage]
        case .still: [.masterImage, .posterImage]
        }
    }
}

public enum StoredArtifactMediaKind: String, Codable, Sendable, Hashable {
    case hevcVideo = "hevc_video"
    case heicImage = "heic_image"
    case pngImage = "png_image"
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
    public let sourceDigest: ContentDigest
    public let importedAt: Date
    public let sourceFileName: String
    public let mediaKind: WallpaperMediaKind
    public let artifacts: [StoredArtifact]

    public init(item: LibraryItem, release: AssetRelease, sourceDigest: ContentDigest,
                importedAt: Date = Date(), sourceFileName: String,
                mediaKind: WallpaperMediaKind = .video, artifacts: [StoredArtifact]) throws {
        let required = StoredArtifactRole.required(for: mediaKind)
        guard artifacts.count == required.count, Set(artifacts.map(\.role)) == required,
              Set(release.artifacts.map(\.contentID)) == Set(artifacts.map(\.digest)),
              item.releaseID == release.id, !sourceFileName.isEmpty,
              sourceFileName.utf8.count <= 1_024,
              artifacts.allSatisfy({ artifact in
                  switch artifact.role {
                  case .masterVideo, .previewVideo: artifact.mediaKind == .hevcVideo && artifact.durationSeconds != nil
                  case .posterImage: artifact.mediaKind == .heicImage && artifact.durationSeconds == nil
                  case .masterImage: artifact.mediaKind == .pngImage && artifact.durationSeconds == nil
                  }
              }) else { throw StorageError.incompleteRelease }
        self.item = item
        self.release = release
        self.sourceDigest = sourceDigest
        self.importedAt = importedAt
        self.sourceFileName = sourceFileName
        self.mediaKind = mediaKind
        self.artifacts = artifacts.sorted { $0.role.rawValue < $1.role.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case item, release, sourceDigest, importedAt, sourceFileName, artifacts
        case mediaKind = "media_kind"
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, allowLegacyVideo: true)
    }

    init(from decoder: any Decoder, allowLegacyVideo: Bool) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let artifacts = try values.decode([StoredArtifact].self, forKey: .artifacts)
        let kind: WallpaperMediaKind
        if values.contains(.mediaKind) {
            kind = try values.decode(WallpaperMediaKind.self, forKey: .mediaKind)
        } else {
            guard allowLegacyVideo, artifacts.count == 3,
                  Set(artifacts.map(\.role)) == StoredArtifactRole.required(for: .video) else {
                throw StorageError.incompleteRelease
            }
            kind = .video
        }
        try self.init(item: values.decode(LibraryItem.self, forKey: .item),
                      release: values.decode(AssetRelease.self, forKey: .release),
                      sourceDigest: values.decode(ContentDigest.self, forKey: .sourceDigest),
                      importedAt: values.decode(Date.self, forKey: .importedAt),
                      sourceFileName: values.decode(String.self, forKey: .sourceFileName),
                      mediaKind: kind, artifacts: artifacts)
    }

    public var masterURL: URL? {
        artifacts.first(where: { $0.role == .masterVideo })?.objectURL
    }
    public var imageURL: URL? {
        artifacts.first(where: { $0.role == .masterImage })?.objectURL
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
        artifacts.first(where: { $0.role == (mediaKind == .video ? .masterVideo : .masterImage) })?.pixelSize
    }
}

public struct RuntimePreferences: Codable, Sendable, Hashable {
    public var launchAtLogin: Bool
    public var qualityIntent: PresentationQualityIntent
    public var lowPowerResponse: PresentationLowPowerResponse
    public var previewsOnHover: Bool
    public var lockScreenContinuityEnabled: Bool

    public init(
        launchAtLogin: Bool = false,
        qualityIntent: PresentationQualityIntent = .automatic,
        lowPowerResponse: PresentationLowPowerResponse = .pause,
        previewsOnHover: Bool = true,
        lockScreenContinuityEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.qualityIntent = qualityIntent
        self.lowPowerResponse = lowPowerResponse
        self.previewsOnHover = previewsOnHover
        self.lockScreenContinuityEnabled = lockScreenContinuityEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, qualityIntent, lowPowerResponse, previewsOnHover
        case lockScreenContinuityEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        qualityIntent = try values.decodeIfPresent(
            PresentationQualityIntent.self,
            forKey: .qualityIntent
        ) ?? .automatic
        lowPowerResponse = try values.decodeIfPresent(
            PresentationLowPowerResponse.self,
            forKey: .lowPowerResponse
        ) ?? .pause
        previewsOnHover = try values.decodeIfPresent(Bool.self, forKey: .previewsOnHover) ?? true
        lockScreenContinuityEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .lockScreenContinuityEnabled
        ) ?? false
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
    public static let minimumReadableSchemaRevision: UInt16 = 0
    public static let schemaRevision: UInt16 = 2

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

    private enum CodingKeys: String, CodingKey {
        case schemaEpoch, schemaRevision, revision, preferences, library, assignments
        case importJobs, installJournals, leases, tombstones
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaEpoch = try values.decode(UInt16.self, forKey: .schemaEpoch)
        schemaRevision = try values.decode(UInt16.self, forKey: .schemaRevision)
        guard schemaEpoch == Self.schemaEpoch,
              schemaRevision >= Self.minimumReadableSchemaRevision,
              schemaRevision <= Self.schemaRevision else {
            throw StorageError.unsupportedSchema(epoch: schemaEpoch, revision: schemaRevision)
        }
        revision = try values.decode(UInt64.self, forKey: .revision)
        preferences = try values.decode(RuntimePreferences.self, forKey: .preferences)
        var records = try values.nestedUnkeyedContainer(forKey: .library)
        library = []
        while !records.isAtEnd {
            library.append(try CommittedLibraryRecord(from: records.superDecoder(), allowLegacyVideo: schemaRevision < 2))
        }
        assignments = try values.decode([DeviceLocalPresentationAssignment].self, forKey: .assignments)
        importJobs = try values.decode([PersistedImportJob].self, forKey: .importJobs)
        installJournals = try values.decode([ArtifactInstallJournal].self, forKey: .installJournals)
        leases = try values.decode([ArtifactLease].self, forKey: .leases)
        tombstones = try values.decode([ArtifactTombstone].self, forKey: .tombstones)
    }

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
    case catalogInstallConflict
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
        case .catalogInstallConflict: "A catalog release conflicts with an existing local record."
        case let .ioFailure(message): "Local storage failed: \(message)"
        }
    }
}
