import Foundation
import WALIModel

/// Durable, transport-neutral state owned by the background agent.
public struct EngineSnapshot: Codable, Sendable, Hashable {
    public var revision: EngineRevision
    public var isPausedByUser: Bool
    public var items: [EngineLibraryItem]
    public var displays: [EngineDisplay]
    public var imports: [EngineImportJob]
    public var preferences: EnginePreferences
    public var resourceUsage: EngineResourceUsage

    public init(
        revision: EngineRevision = .init(rawValue: 0),
        isPausedByUser: Bool = false,
        items: [EngineLibraryItem] = [],
        displays: [EngineDisplay] = [],
        imports: [EngineImportJob] = [],
        preferences: EnginePreferences = .init(),
        resourceUsage: EngineResourceUsage = .init()
    ) {
        self.revision = revision
        self.isPausedByUser = isPausedByUser
        self.items = items
        self.displays = displays
        self.imports = imports
        self.preferences = preferences
        self.resourceUsage = resourceUsage
    }
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
        self.isFavorite = isFavorite
    }
}

public struct EngineDisplay: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isMain: Bool
    public var assignedItemID: UUID?
    public var isOnline: Bool

    public init(
        id: String,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        isMain: Bool,
        assignedItemID: UUID? = nil,
        isOnline: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
        self.assignedItemID = assignedItemID
        self.isOnline = isOnline
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
    }

    public var launchAtLogin: Bool
    public var pauseOnBattery: Bool
    public var pauseWhenOccluded: Bool
    public var scaling: Scaling
    public var muted: Bool

    public init(
        launchAtLogin: Bool = false,
        pauseOnBattery: Bool = false,
        pauseWhenOccluded: Bool = true,
        scaling: Scaling = .fill,
        muted: Bool = true
    ) {
        self.launchAtLogin = launchAtLogin
        self.pauseOnBattery = pauseOnBattery
        self.pauseWhenOccluded = pauseWhenOccluded
        self.scaling = scaling
        self.muted = muted
    }
}

public struct EngineResourceUsage: Codable, Sendable, Hashable {
    public var activePlayers: Int
    public var residentMemoryBytes: UInt64
    public var isLowPowerModeEnabled: Bool
    public var thermalState: String

    public init(
        activePlayers: Int = 0,
        residentMemoryBytes: UInt64 = 0,
        isLowPowerModeEnabled: Bool = false,
        thermalState: String = "nominal"
    ) {
        self.activePlayers = max(0, activePlayers)
        self.residentMemoryBytes = residentMemoryBytes
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }
}
