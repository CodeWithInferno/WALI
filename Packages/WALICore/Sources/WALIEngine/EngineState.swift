import Foundation
import WALIModel

/// Durable, transport-neutral state owned by the background agent.
public struct EngineSnapshot: Codable, Sendable, Hashable {
    public var revision: EngineRevision
    public var isPausedByUser: Bool
    public var playbackStatus: EnginePlaybackStatus
    public var items: [EngineLibraryItem]
    public var trashedItems: [EngineLibraryItem]
    public var displays: [EngineDisplay]
    public var imports: [EngineImportJob]
    public var preferences: EnginePreferences
    public var resourceUsage: EngineResourceUsage

    public init(
        revision: EngineRevision = .init(rawValue: 0),
        isPausedByUser: Bool = false,
        playbackStatus: EnginePlaybackStatus = .idle,
        items: [EngineLibraryItem] = [],
        trashedItems: [EngineLibraryItem] = [],
        displays: [EngineDisplay] = [],
        imports: [EngineImportJob] = [],
        preferences: EnginePreferences = .init(),
        resourceUsage: EngineResourceUsage = .init()
    ) {
        self.revision = revision
        self.isPausedByUser = isPausedByUser
        self.playbackStatus = playbackStatus
        self.items = items
        self.trashedItems = trashedItems
        self.displays = displays
        self.imports = imports
        self.preferences = preferences
        self.resourceUsage = resourceUsage
    }
}

public enum EnginePlaybackStatus: Codable, Sendable, Hashable {
    case idle
    case preparing
    case playing
    case paused
    case suspended
    case failed(String)
}

public struct EngineLibraryItem: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let duration: TimeInterval
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let masterURL: URL
    public let previewURL: URL
    public let posterURL: URL
    public let contentDigest: String
    public let byteCount: UInt64
    public var isFavorite: Bool

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        duration: TimeInterval,
        pixelWidth: Int,
        pixelHeight: Int,
        masterURL: URL,
        previewURL: URL,
        posterURL: URL,
        contentDigest: String,
        byteCount: UInt64 = 0,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.masterURL = masterURL
        self.previewURL = previewURL
        self.posterURL = posterURL
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.isFavorite = isFavorite
    }
}

public struct EngineDisplay: Codable, Sendable, Hashable, Identifiable {
    private static let maximumLogicalFrameValue = 1_000_000.0

    public let id: String
    public var aliases: [String]
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var frameX: Double?
    public var frameY: Double?
    public var frameWidth: Double?
    public var frameHeight: Double?
    public var assignedItemID: UUID?
    public var scaling: EnginePreferences.Scaling?
    public var isOnline: Bool

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
        scaling: EnginePreferences.Scaling? = nil,
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
        scaling = try values.decodeIfPresent(EnginePreferences.Scaling.self, forKey: .scaling)
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

public struct EngineImportJob: Codable, Sendable, Hashable, Identifiable {
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
    public var fileName: String
    public var phase: Phase
    public var progress: Double
    public var detail: String?
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

public struct EnginePreferences: Codable, Sendable, Hashable {
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

    public var launchAtLogin: Bool
    public var startPaused: Bool
    public var pauseOnBattery: Bool
    public var pauseWhenOccluded: Bool
    public var scaling: Scaling
    public var quality: Quality
    public var lowPowerBehavior: LowPowerBehavior
    public var muted: Bool
    public var lockScreenContinuityEnabled: Bool

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

public struct EngineResourceUsage: Codable, Sendable, Hashable {
    public var activePlayers: Int
    public var cpuPercent: Double
    public var residentMemoryBytes: UInt64
    public var isLowPowerModeEnabled: Bool
    public var thermalState: String
    public var storageUsedBytes: UInt64
    public var storageLimitBytes: UInt64?

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
