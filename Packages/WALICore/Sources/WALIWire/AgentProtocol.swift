import Foundation
import WALIModel

/// The compatibility version shared by the foreground app and background agent.
public enum WALIProtocol {
    public static let currentVersion: UInt16 = 3
    public static let maximumMessageBytes = 4 * 1_024 * 1_024
}

/// A foreground-app request sent to the background agent.
public struct AgentRequest: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let requestID: UUID
    public let idempotencyKey: UUID
    public let expectedRevision: EngineRevision?
    public let command: AgentCommand

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        expectedRevision: EngineRevision? = nil,
        command: AgentCommand
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.command = command
    }
}

/// The complete command catalog supported by the local agent.
public enum AgentCommand: Codable, Sendable, Hashable {
    case handshake(clientVersion: String)
    case snapshot
    case diagnosticsSnapshot
    case preparePresentation(itemIDs: [UUID])
    case importFiles(bookmarks: [Data])
    case installCatalogRelease(AgentCatalogInstallRequest)
    case updateCatalogTrustTransition(AgentCatalogTrustTransitionUpdate)
    case updateCatalogRevocations(AgentCatalogRevocationUpdate)
    case cancelImport(jobID: UUID)
    case apply(itemID: UUID, displayIDs: [String], scaling: AgentPreferences.Scaling)
    case setPlaybackPaused(Bool)
    case nextWallpaper
    case stopWallpaper
    case renameItem(itemID: UUID, name: String)
    case removeItem(itemID: UUID)
    case restoreItem(itemID: UUID)
    case setPreferences(AgentPreferences)
    case revealItem(itemID: UUID)
    case openForegroundApp
    case quit
}

/// A background-agent response. Failures are values so XPC remains deterministic.
public struct AgentResponse: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let requestID: UUID
    public let result: AgentResult

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        requestID: UUID,
        result: AgentResult
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
    }
}

public enum AgentResult: Codable, Sendable, Hashable {
    case snapshot(AgentSnapshot)
    case failure(AgentFailure)
}

public struct AgentFailure: Codable, Sendable, Hashable, Error {
    public enum Code: String, Codable, Sendable, Hashable {
        case incompatibleProtocol
        case invalidRequest
        case staleRevision
        case itemNotFound
        case displayNotFound
        case importFailed
        case catalogTrustFailed
        case catalogReleaseRevoked
        case storageUnavailable
        case rendererUnavailable
        case internalFailure
    }

    public let code: Code
    public let message: String
    public let recoverySuggestion: String?

    public init(code: Code, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

/// Opaque WALI-owned quarantine object presented to the agent for one install.
/// The agent resolves the reference below its compiled fixed quarantine root;
/// no path or URL crosses IPC.
public struct AgentCatalogInstallRequest: Codable, Sendable, Hashable {
    public static let maximumManifestBytes = 65_536
    public static let maximumMetadataBytes = 16_384
    public static let maximumSignatureUTF8Length = 86
    public static let maximumKeyIDUTF8Length = 64

    public let canonicalManifest: Data
    public let canonicalMetadata: Data
    public let signatureBase64URL: String
    public let keyID: String
    public let quarantineReference: UUID

    public init(
        canonicalManifest: Data,
        canonicalMetadata: Data,
        signatureBase64URL: String,
        keyID: String,
        quarantineReference: UUID
    ) {
        self.canonicalManifest = canonicalManifest
        self.canonicalMetadata = canonicalMetadata
        self.signatureBase64URL = signatureBase64URL
        self.keyID = keyID
        self.quarantineReference = quarantineReference
    }
}

/// Cumulative signing-key state signed by a compiled trust anchor. The agent
/// independently verifies and persists it before accepting dependent releases.
public struct AgentCatalogTrustTransitionUpdate: Codable, Sendable, Hashable {
    public static let maximumBodyBytes = 32_768

    public let revision: UInt64
    public let canonicalBody: Data
    public let signatureBase64URL: String
    public let keyID: String

    public init(
        revision: UInt64,
        canonicalBody: Data,
        signatureBase64URL: String,
        keyID: String
    ) {
        self.revision = revision
        self.canonicalBody = canonicalBody
        self.signatureBase64URL = signatureBase64URL
        self.keyID = keyID
    }
}

/// Signed critical-revocation document. Verification and persistence are owned
/// by the agent and never grant remote deletion authority over local media.
public struct AgentCatalogRevocationUpdate: Codable, Sendable, Hashable {
    public static let maximumBodyBytes = 1_048_576

    public let canonicalBody: Data
    public let revision: UInt64
    public let signatureBase64URL: String
    public let keyID: String

    public init(
        revision: UInt64,
        canonicalBody: Data,
        signatureBase64URL: String,
        keyID: String
    ) {
        self.revision = revision
        self.canonicalBody = canonicalBody
        self.signatureBase64URL = signatureBase64URL
        self.keyID = keyID
    }
}

extension AgentFailure: LocalizedError {
    public var errorDescription: String? { message }
}

/// The complete UI-facing state at one monotonic engine revision.
public struct AgentSnapshot: Codable, Sendable, Hashable {
    public let revision: EngineRevision
    public let connection: AgentConnectionState
    public let playback: AgentPlaybackState
    public let items: [AgentLibraryItem]
    public let displays: [AgentDisplay]
    public let imports: [AgentImportJob]
    public let preferences: AgentPreferences
    public let resourceUsage: AgentResourceUsage
    public let notice: AgentRuntimeNotice?

    public init(
        revision: EngineRevision,
        connection: AgentConnectionState = .ready,
        playback: AgentPlaybackState = .idle,
        items: [AgentLibraryItem] = [],
        displays: [AgentDisplay] = [],
        imports: [AgentImportJob] = [],
        preferences: AgentPreferences = .init(),
        resourceUsage: AgentResourceUsage = .init(),
        notice: AgentRuntimeNotice? = nil
    ) {
        self.revision = revision
        self.connection = connection
        self.playback = playback
        self.items = items
        self.displays = displays
        self.imports = imports
        self.preferences = preferences
        self.resourceUsage = resourceUsage
        self.notice = notice
    }
}

/// A recoverable runtime condition that should remain visible across XPC
/// polling without turning an already-committed desktop command into failure.
public struct AgentRuntimeNotice: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case information
        case warning
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let message: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        message: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
    }
}

public enum AgentConnectionState: String, Codable, Sendable, Hashable {
    case starting
    case ready
    case degraded
}

public enum AgentPlaybackState: String, Codable, Sendable, Hashable {
    case idle
    case preparing
    case playing
    case displaying
    case paused
    case suspended
    case failed
}

public struct AgentLibraryItem: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let mediaContent: AgentWallpaperMediaContent
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let posterURL: URL
    public let contentDigest: String
    public let byteCount: UInt64
    public let isFavorite: Bool

    public init(id: UUID, name: String, createdAt: Date,
                mediaContent: AgentWallpaperMediaContent, pixelWidth: Int, pixelHeight: Int,
                posterURL: URL, contentDigest: String, byteCount: UInt64 = 0,
                isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.mediaContent = mediaContent
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.posterURL = posterURL
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.isFavorite = isFavorite
    }

    /// Source compatibility for callers constructing a known video item.
    public init(id: UUID, name: String, createdAt: Date, duration: TimeInterval,
                pixelWidth: Int, pixelHeight: Int, masterURL: URL, previewURL: URL,
                posterURL: URL, contentDigest: String, byteCount: UInt64 = 0,
                isFavorite: Bool = false) {
        self.init(id: id, name: name, createdAt: createdAt,
                  mediaContent: .video(masterURL: masterURL, previewURL: previewURL, duration: duration),
                  pixelWidth: pixelWidth, pixelHeight: pixelHeight, posterURL: posterURL,
                  contentDigest: contentDigest, byteCount: byteCount, isFavorite: isFavorite)
    }
}

public struct AgentDisplay: Codable, Sendable, Hashable, Identifiable {
    private static let maximumLogicalFrameValue = 1_000_000.0

    public let id: String
    public let aliases: [String]
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool
    public let isBuiltIn: Bool
    public let frameX: Double?
    public let frameY: Double?
    public let frameWidth: Double?
    public let frameHeight: Double?
    public let assignedItemID: UUID?
    public let scaling: AgentPreferences.Scaling?
    public let isOnline: Bool

    public init(
        id: String,
        aliases: [String] = [],
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        isMain: Bool,
        isBuiltIn: Bool = false,
        frameX: Double? = nil,
        frameY: Double? = nil,
        frameWidth: Double? = nil,
        frameHeight: Double? = nil,
        assignedItemID: UUID? = nil,
        scaling: AgentPreferences.Scaling? = nil,
        isOnline: Bool = true
    ) {
        self.id = id
        self.aliases = aliases
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.frameX = Self.boundedCoordinate(frameX)
        self.frameY = Self.boundedCoordinate(frameY)
        self.frameWidth = Self.boundedDimension(frameWidth)
        self.frameHeight = Self.boundedDimension(frameHeight)
        self.assignedItemID = assignedItemID
        self.scaling = scaling
        self.isOnline = isOnline
    }

    private enum CodingKeys: String, CodingKey {
        case id, aliases, name, pixelWidth, pixelHeight, isMain, isBuiltIn
        case frameX, frameY, frameWidth, frameHeight
        case assignedItemID, scaling, isOnline
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        name = try values.decode(String.self, forKey: .name)
        pixelWidth = try values.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try values.decode(Int.self, forKey: .pixelHeight)
        isMain = try values.decode(Bool.self, forKey: .isMain)
        isBuiltIn = try values.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        frameX = Self.boundedCoordinate(try values.decodeIfPresent(Double.self, forKey: .frameX))
        frameY = Self.boundedCoordinate(try values.decodeIfPresent(Double.self, forKey: .frameY))
        frameWidth = Self.boundedDimension(try values.decodeIfPresent(Double.self, forKey: .frameWidth))
        frameHeight = Self.boundedDimension(try values.decodeIfPresent(Double.self, forKey: .frameHeight))
        assignedItemID = try values.decodeIfPresent(UUID.self, forKey: .assignedItemID)
        scaling = try values.decodeIfPresent(AgentPreferences.Scaling.self, forKey: .scaling)
        isOnline = try values.decodeIfPresent(Bool.self, forKey: .isOnline) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(aliases, forKey: .aliases)
        try values.encode(name, forKey: .name)
        try values.encode(pixelWidth, forKey: .pixelWidth)
        try values.encode(pixelHeight, forKey: .pixelHeight)
        try values.encode(isMain, forKey: .isMain)
        try values.encode(isBuiltIn, forKey: .isBuiltIn)
        try values.encodeIfPresent(Self.boundedCoordinate(frameX), forKey: .frameX)
        try values.encodeIfPresent(Self.boundedCoordinate(frameY), forKey: .frameY)
        try values.encodeIfPresent(Self.boundedDimension(frameWidth), forKey: .frameWidth)
        try values.encodeIfPresent(Self.boundedDimension(frameHeight), forKey: .frameHeight)
        try values.encodeIfPresent(assignedItemID, forKey: .assignedItemID)
        try values.encodeIfPresent(scaling, forKey: .scaling)
        try values.encode(isOnline, forKey: .isOnline)
    }

    private static func boundedCoordinate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, abs(value) <= maximumLogicalFrameValue else {
            return nil
        }
        return value
    }

    private static func boundedDimension(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= maximumLogicalFrameValue else {
            return nil
        }
        return value
    }
}

public struct AgentImportJob: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: String, Codable, Sendable, Hashable {
        case queued
        case inspecting
        case transcoding
        case poster
        case installing
        case complete
        case cancelled
        case failed
    }

    public let id: UUID
    public let fileName: String
    public let phase: Phase
    public let progress: Double
    public let detail: String?
    public let createdAt: Date

    public init(
        id: UUID,
        fileName: String,
        phase: Phase,
        progress: Double,
        detail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct AgentPreferences: Codable, Sendable, Hashable {
    public enum Scaling: String, Codable, Sendable, Hashable {
        case fill
        case fit
        case stretch
        case center
    }

    public enum Quality: String, Codable, Sendable, Hashable {
        case automatic
        case efficiency
        case quality
    }

    public enum LowPowerBehavior: String, Codable, Sendable, Hashable {
        case pause
        case reduceQuality
        case continuePlaying
    }

    public let launchAtLogin: Bool
    public let startPaused: Bool
    public let pauseOnBattery: Bool
    public let pauseWhenOccluded: Bool
    public let scaling: Scaling
    public let quality: Quality
    public let lowPowerBehavior: LowPowerBehavior
    public let muted: Bool
    public let lockScreenContinuityEnabled: Bool

    public init(
        launchAtLogin: Bool = false,
        startPaused: Bool = false,
        pauseOnBattery: Bool = false,
        pauseWhenOccluded: Bool = true,
        scaling: Scaling = .fill,
        quality: Quality = .automatic,
        lowPowerBehavior: LowPowerBehavior = .pause,
        muted: Bool = true,
        lockScreenContinuityEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.startPaused = startPaused
        self.pauseOnBattery = pauseOnBattery
        self.pauseWhenOccluded = pauseWhenOccluded
        self.scaling = scaling
        self.quality = quality
        self.lowPowerBehavior = lowPowerBehavior
        self.muted = muted
        self.lockScreenContinuityEnabled = lockScreenContinuityEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, startPaused, pauseOnBattery, pauseWhenOccluded
        case scaling, quality, lowPowerBehavior, muted, lockScreenContinuityEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        startPaused = try values.decodeIfPresent(Bool.self, forKey: .startPaused) ?? false
        pauseOnBattery = try values.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        pauseWhenOccluded = try values.decodeIfPresent(Bool.self, forKey: .pauseWhenOccluded) ?? true
        scaling = try values.decodeIfPresent(Scaling.self, forKey: .scaling) ?? .fill
        quality = try values.decodeIfPresent(Quality.self, forKey: .quality) ?? .automatic
        lowPowerBehavior = try values.decodeIfPresent(LowPowerBehavior.self, forKey: .lowPowerBehavior) ?? .pause
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        lockScreenContinuityEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .lockScreenContinuityEnabled
        ) ?? false
    }
}

public struct AgentResourceUsage: Codable, Sendable, Hashable {
    public let activePlayers: Int
    public let cpuPercent: Double
    public let residentMemoryBytes: UInt64
    public let isLowPowerModeEnabled: Bool
    public let thermalState: String
    public let storageUsedBytes: UInt64
    public let storageLimitBytes: UInt64?

    public init(
        activePlayers: Int = 0,
        cpuPercent: Double = 0,
        residentMemoryBytes: UInt64 = 0,
        isLowPowerModeEnabled: Bool = false,
        thermalState: String = "nominal",
        storageUsedBytes: UInt64 = 0,
        storageLimitBytes: UInt64? = nil
    ) {
        self.activePlayers = max(0, activePlayers)
        self.cpuPercent = max(0, cpuPercent)
        self.residentMemoryBytes = residentMemoryBytes
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
        self.storageUsedBytes = storageUsedBytes
        self.storageLimitBytes = storageLimitBytes
    }
}
