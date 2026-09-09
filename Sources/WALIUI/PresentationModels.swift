import Foundation
import Observation
import WALIModel

/// A small, presentation-only snapshot that both WALI processes can render.
///
/// The engine remains authoritative. Hosts replace this value whenever a newer
/// engine snapshot arrives; views never persist or reconcile it themselves.
public struct WALIUISnapshot: Equatable, Sendable {
    public var wallpapers: [WALIWallpaperPresentation]
    public var displays: [WALIDisplayPresentation]
    public var transfers: [WALITransferPresentation]
    public var renderer: WALIRendererPresentation
    public var preferences: WALIPreferencesPresentation
    public var storage: WALIStoragePresentation
    public var notice: WALINoticePresentation?

    public init(
        wallpapers: [WALIWallpaperPresentation] = [],
        displays: [WALIDisplayPresentation] = [],
        transfers: [WALITransferPresentation] = [],
        renderer: WALIRendererPresentation = .stopped,
        preferences: WALIPreferencesPresentation = .init(),
        storage: WALIStoragePresentation = .init(),
        notice: WALINoticePresentation? = nil
    ) {
        self.wallpapers = wallpapers
        self.displays = displays
        self.transfers = transfers
        self.renderer = renderer
        self.preferences = preferences
        self.storage = storage
        self.notice = notice
    }

    public static let empty = WALIUISnapshot()
}

/// Main-actor presentation state updated by the foreground/agent adapters.
@MainActor
@Observable
public final class WALIAppModel {
    public var snapshot: WALIUISnapshot
    public var settingsPresentationRequest: UInt64
    /// Rebuild media views when a replaceable cached file reappears at the same URL.
    public var presentationRevisions: [UUID: UInt64] = [:]

    public init(
        snapshot: WALIUISnapshot = .empty,
        settingsPresentationRequest: UInt64 = 0
    ) {
        self.snapshot = snapshot
        self.settingsPresentationRequest = settingsPresentationRequest
    }
}

public struct WALIWallpaperPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var creator: String?
    public var license: String?
    public var dimensions: String
    public var duration: String?
    public var fileSize: String
    public var thumbnailURL: URL?
    public var previewURL: URL?
    public var isActive: Bool
    public var availability: WALIWallpaperAvailability

    public init(
        id: UUID,
        title: String,
        creator: String? = nil,
        license: String? = nil,
        dimensions: String,
        duration: String? = nil,
        fileSize: String,
        thumbnailURL: URL? = nil,
        previewURL: URL? = nil,
        isActive: Bool = false,
        availability: WALIWallpaperAvailability = .ready
    ) {
        self.id = id
        self.title = title
        self.creator = creator
        self.license = license
        self.dimensions = dimensions
        self.duration = duration
        self.fileSize = fileSize
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.isActive = isActive
        self.availability = availability
    }
}

public enum WALIWallpaperAvailability: Equatable, Sendable {
    case ready
    case preparing(progress: Double?)
    case failed(message: String)
}

public struct WALIDisplayPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var detail: String
    public var isConnected: Bool
    public var isBuiltIn: Bool
    public var isMain: Bool
    public var assignedWallpaperID: UUID?
    public var frameX: Double?
    public var frameY: Double?
    public var frameWidth: Double?
    public var frameHeight: Double?
    public var contentFit: WALIContentFitPreference?

    public init(
        id: String,
        name: String,
        detail: String,
        isConnected: Bool = true,
        isBuiltIn: Bool = false,
        isMain: Bool = false,
        assignedWallpaperID: UUID? = nil,
        frameX: Double? = nil,
        frameY: Double? = nil,
        frameWidth: Double? = nil,
        frameHeight: Double? = nil,
        contentFit: WALIContentFitPreference? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isConnected = isConnected
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.assignedWallpaperID = assignedWallpaperID
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.contentFit = contentFit
    }
}

public struct WALITransferPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var state: WALITransferState

    public init(id: UUID, title: String, detail: String, state: WALITransferState) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum WALITransferState: Equatable, Sendable {
    case queued
    case working(progress: Double?)
    case ready
    case failed(message: String)
    case cancelled
}

public struct WALIRendererPresentation: Equatable, Sendable {
    public var state: WALIRendererState
    public var wallpaperTitle: String?
    public var thumbnailURL: URL?
    public var displayCount: Int
    public var cpuPercent: Double?
    public var physicalMemoryBytes: Int64?

    public init(
        state: WALIRendererState,
        wallpaperTitle: String? = nil,
        thumbnailURL: URL? = nil,
        displayCount: Int = 0,
        cpuPercent: Double? = nil,
        physicalMemoryBytes: Int64? = nil
    ) {
        self.state = state
        self.wallpaperTitle = wallpaperTitle
        self.thumbnailURL = thumbnailURL
        self.displayCount = displayCount
        self.cpuPercent = cpuPercent
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static let stopped = WALIRendererPresentation(state: .stopped)
}

public enum WALIRendererState: Equatable, Sendable {
    case stopped
    case playing
    case automaticallyPaused(reason: String)
    case userPaused
    case converting(progress: Double?)
    case error(message: String)

    public var isPaused: Bool {
        switch self {
        case .automaticallyPaused, .userPaused:
            true
        default:
            false
        }
    }
}

public struct WALIPreferencesPresentation: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var startPaused: Bool
    public var quality: WALIQualityPreference
    public var lowPowerBehavior: WALILowPowerPreference
    public var contentFit: WALIContentFitPreference
    public var lockScreenContinuityEnabled: Bool

    public init(
        launchAtLogin: Bool = false,
        startPaused: Bool = false,
        quality: WALIQualityPreference = .automatic,
        lowPowerBehavior: WALILowPowerPreference = .pause,
        contentFit: WALIContentFitPreference = .fill,
        lockScreenContinuityEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.startPaused = startPaused
        self.quality = quality
        self.lowPowerBehavior = lowPowerBehavior
        self.contentFit = contentFit
        self.lockScreenContinuityEnabled = lockScreenContinuityEnabled
    }
}

/// Read-only storage accounting derived by the authoritative agent.
public struct WALIStoragePresentation: Equatable, Sendable {
    public var usedBytes: Int64
    public var limitBytes: Int64?

    public init(usedBytes: Int64 = 0, limitBytes: Int64? = nil) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }
}

public enum WALIQualityPreference: String, CaseIterable, Identifiable, Equatable, Sendable {
    case automatic
    case efficiency
    case quality

    public var id: Self { self }
}

public enum WALILowPowerPreference: String, CaseIterable, Identifiable, Equatable, Sendable {
    case pause
    case reduceQuality
    case continuePlaying

    public var id: Self { self }
}

public enum WALIContentFitPreference: String, CaseIterable, Identifiable, Equatable, Sendable {
    case fill
    case fit
    case stretch
    case center

    public var id: Self { self }
}

public struct WALINoticePresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: WALINoticeKind
    public var title: String
    public var message: String

    public init(id: UUID = UUID(), kind: WALINoticeKind, title: String, message: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
    }

    public var dismissalKey: String {
        "\(title)\u{1e}\(message)"
    }
}

public enum WALINoticeKind: Equatable, Sendable {
    case information
    case success
    case warning
    case error
}

/// Every user intention emitted by the reusable presentation layer.
public enum WALIUIAction: Equatable, Sendable {
    case importVideos([URL])
    case applyWallpaper(
        itemID: UUID,
        displayIDs: Set<String>,
        contentFit: WALIContentFitPreference
    )
    case deleteWallpaper(itemID: UUID)
    case restoreWallpaper(itemID: UUID)
    case revealWallpaper(itemID: UUID)
    case cancelTransfer(id: UUID)
    case setPaused(Bool)
    case nextWallpaper
    case stopWallpaper
    case refreshDiagnostics
    case updatePreferences(WALIPreferencesPresentation)
    case openMainApplication
    case openSettings
    case quit
}

/// Host boundary for forwarding UI intentions to the authoritative engine.
@MainActor
public protocol WALIUIActionHandling: AnyObject {
    func send(_ action: WALIUIAction)
}

/// Safe default for previews and composition roots that have not connected yet.
@MainActor
public final class NoopWALIUIActionHandler: WALIUIActionHandling {
    public init() {}

    public func send(_ action: WALIUIAction) {}
}
