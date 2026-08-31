import AppKit
import Foundation
import WALIModel
import WALIUI
import WALIWire

/// Live foreground adapter: lifecycle, XPC transport, snapshot mapping and UI intentions.
@MainActor
public final class WALIAppCoordinator: WALIUIActionHandling {
    public let model: WALIAppModel

    private let connection: AgentConnection
    private let lifecycle: AgentLifecycleController
    private var pollingTask: Task<Void, Never>?
    private var lastSnapshot: AgentSnapshot?
    private var quitObserver: (any NSObjectProtocol)?
    private var settingsObserver: (any NSObjectProtocol)?
    private var pendingActions: [WALIUIAction] = []
    private var actionTask: Task<Void, Never>?

    public init(
        model: WALIAppModel = WALIAppModel(),
        connection: AgentConnection = AgentConnection(),
        lifecycle: AgentLifecycleController = AgentLifecycleController()
    ) {
        self.model = model
        self.connection = connection
        self.lifecycle = lifecycle
    }

    public func start() {
        guard pollingTask == nil else { return }
        if quitObserver == nil {
            quitObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.wali.quitAll"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        if settingsObserver == nil {
            settingsObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.wali.openSettings"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    self?.model.settingsPresentationRequest &+= 1
                }
            }
        }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--repair-agent-registration") {
                    try await lifecycle.reinstallAgent()
                }
                try lifecycle.ensureRunning()
            } catch {
                present(error: error, title: "Background Access Needed")
            }

            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        actionTask?.cancel()
        actionTask = nil
        pendingActions.removeAll()
        if let quitObserver {
            DistributedNotificationCenter.default().removeObserver(quitObserver)
            self.quitObserver = nil
        }
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        connection.invalidate()
    }

    public func send(_ action: WALIUIAction) {
        pendingActions.append(action)
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !pendingActions.isEmpty {
                let next = pendingActions.removeFirst()
                await perform(next)
            }
            actionTask = nil
        }
    }

    private func perform(_ action: WALIUIAction) async {
        do {
            guard let command = try command(for: action) else { return }
            let previousPreferences = lastSnapshot?.preferences
            let snapshot = try await sendWithSingleStaleRetry(command)
            apply(snapshot, clearNotice: true)
            if case let .updatePreferences(preferences) = action,
               previousPreferences?.launchAtLogin != preferences.launchAtLogin {
                do {
                    try lifecycle.setMainApplicationLaunchAtLogin(preferences.launchAtLogin)
                } catch {
                    if let previousPreferences {
                        let rollback = try await sendWithSingleStaleRetry(
                            .setPreferences(previousPreferences)
                        )
                        apply(rollback)
                    }
                    throw error
                }
            }
        } catch {
            present(error: error)
        }
    }

    private func sendWithSingleStaleRetry(_ command: AgentCommand) async throws -> AgentSnapshot {
        let idempotencyKey = UUID()
        for attempt in 0...1 {
            do {
                return try await connection.send(
                    command,
                    expectedRevision: expectedRevision(for: command),
                    idempotencyKey: idempotencyKey
                )
            } catch let failure as AgentFailure
                where failure.code == .staleRevision && attempt == 0 {
                let refreshed = try await connection.send(.snapshot)
                apply(refreshed)
            }
        }
        throw AgentConnectionError.unavailable
    }

    private func expectedRevision(for command: AgentCommand) -> EngineRevision? {
        switch command {
        case .snapshot, .diagnosticsSnapshot, .handshake, .openForegroundApp, .revealItem, .quit:
            nil
        default:
            lastSnapshot?.revision
        }
    }

    private func command(for action: WALIUIAction) throws -> AgentCommand? {
        switch action {
        case let .importVideos(urls):
            let bookmarks = try urls.map { url in
                try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            return .importFiles(bookmarks: bookmarks)
        case let .applyWallpaper(itemID, displayIDs, contentFit):
            return .apply(
                itemID: itemID,
                displayIDs: displayIDs.sorted(),
                scaling: .init(rawValue: contentFit.rawValue) ?? .fill
            )
        case let .deleteWallpaper(itemID):
            return .removeItem(itemID: itemID)
        case let .restoreWallpaper(itemID):
            return .restoreItem(itemID: itemID)
        case let .revealWallpaper(itemID):
            return .revealItem(itemID: itemID)
        case let .cancelTransfer(id):
            return .cancelImport(jobID: id)
        case let .setPaused(paused):
            return .setPlaybackPaused(paused)
        case .nextWallpaper:
            return .nextWallpaper
        case .stopWallpaper:
            return .stopWallpaper
        case .refreshDiagnostics:
            return .diagnosticsSnapshot
        case let .updatePreferences(preferences):
            let current = lastSnapshot?.preferences ?? .init()
            return .setPreferences(.init(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                pauseOnBattery: current.pauseOnBattery,
                pauseWhenOccluded: current.pauseWhenOccluded,
                scaling: .init(rawValue: preferences.contentFit.rawValue) ?? .fill,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause,
                muted: current.muted
            ))
        case .openMainApplication:
            NSApplication.shared.activate(ignoringOtherApps: true)
            return nil
        case .openSettings:
            NSApplication.shared.activate(ignoringOtherApps: true)
            model.settingsPresentationRequest &+= 1
            return nil
        case .quit:
            return .quit
        }
    }

    private func refresh() async {
        do {
            let snapshot = try await connection.send(.snapshot)
            apply(snapshot)
        } catch {
            if lastSnapshot == nil {
                present(error: error, title: "Connecting to WALI")
            }
        }
    }

    private func apply(_ snapshot: AgentSnapshot, clearNotice: Bool = false) {
        guard lastSnapshot == nil || snapshot.revision.rawValue >= lastSnapshot!.revision.rawValue else {
            return
        }
        lastSnapshot = snapshot
        model.snapshot = snapshot.presentationValue(
            preserving: clearNotice ? nil : model.snapshot.notice
        )
    }

    private func present(error: Error, title: String = "WALI Couldn’t Complete That") {
        model.snapshot.notice = WALINoticePresentation(
            kind: .error,
            title: title,
            message: error.localizedDescription
        )
    }
}

public extension AgentSnapshot {
    @MainActor
    func presentationValue(preserving notice: WALINoticePresentation? = nil) -> WALIUISnapshot {
        let activeItemIDs = Set(displays.compactMap(\.assignedItemID))
        let activeItem = items.first(where: { activeItemIDs.contains($0.id) })
        return WALIUISnapshot(
            wallpapers: items.map { item in
                WALIWallpaperPresentation(
                    id: item.id,
                    title: item.name,
                    dimensions: "\(item.pixelWidth) × \(item.pixelHeight)",
                    duration: item.duration.formattedDuration,
                    fileSize: Int64(clamping: item.byteCount).formatted(.byteCount(style: .file)),
                    thumbnailURL: item.posterURL,
                    previewURL: item.previewURL,
                    isActive: activeItemIDs.contains(item.id)
                )
            },
            displays: displays.map { display in
                WALIDisplayPresentation(
                    id: display.id,
                    name: display.name,
                    detail: "\(display.pixelWidth) × \(display.pixelHeight)",
                    isConnected: display.isOnline,
                    isBuiltIn: display.isBuiltIn,
                    contentFit: display.scaling.flatMap {
                        WALIContentFitPreference(rawValue: $0.rawValue)
                    }
                )
            },
            transfers: imports.map(\.presentationValue),
            renderer: WALIRendererPresentation(
                state: rendererState,
                wallpaperTitle: activeItem?.name,
                thumbnailURL: activeItem?.posterURL,
                displayCount: displays.count { $0.assignedItemID != nil && $0.isOnline },
                cpuPercent: hasDiagnosticsSample ? resourceUsage.cpuPercent : nil,
                physicalMemoryBytes: hasDiagnosticsSample
                    ? Int64(clamping: resourceUsage.residentMemoryBytes)
                    : nil
            ),
            preferences: WALIPreferencesPresentation(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause,
                contentFit: .init(rawValue: preferences.scaling.rawValue) ?? .fill
            ),
            storage: WALIStoragePresentation(
                usedBytes: Int64(clamping: resourceUsage.storageUsedBytes),
                limitBytes: resourceUsage.storageLimitBytes.map(Int64.init(clamping:))
            ),
            notice: notice
        )
    }

    private var hasDiagnosticsSample: Bool {
        resourceUsage.residentMemoryBytes > 0
    }

    private var rendererState: WALIRendererState {
        switch playback {
        case .idle: return .stopped
        case .preparing: return .converting(progress: nil)
        case .playing: return .playing
        case .paused: return .userPaused
        case .suspended:
            return .automaticallyPaused(reason: resourceUsage.isLowPowerModeEnabled ? "Low Power Mode" : "System activity")
        case .failed: return .error(message: "The wallpaper renderer needs attention.")
        }
    }
}

private extension AgentImportJob {
    var presentationValue: WALITransferPresentation {
        let state: WALITransferState
        switch phase {
        case .queued: state = .queued
        case .complete: state = .ready
        case .cancelled: state = .cancelled
        case .failed: state = .failed(message: detail ?? "Import failed")
        default: state = .working(progress: progress)
        }
        return WALITransferPresentation(
            id: id,
            title: fileName,
            detail: phase.isTerminal ? phase.displayName : (detail ?? phase.displayName),
            state: state
        )
    }
}

private extension AgentImportJob.Phase {
    var isTerminal: Bool {
        switch self {
        case .complete, .cancelled: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .queued: "Waiting"
        case .inspecting: "Inspecting video"
        case .transcoding: "Preparing video"
        case .poster: "Creating poster"
        case .installing: "Adding to library"
        case .complete: "Ready"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = max(0, Int(self.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
