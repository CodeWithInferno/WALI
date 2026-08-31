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
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
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
        connection.invalidate()
    }

    public func send(_ action: WALIUIAction) {
        Task { @MainActor [weak self] in
            await self?.perform(action)
        }
    }

    private func perform(_ action: WALIUIAction) async {
        do {
            guard let command = try command(for: action) else { return }
            let expectedRevision: EngineRevision?
            switch command {
            case .snapshot, .handshake, .openForegroundApp, .revealItem, .quit:
                expectedRevision = nil
            default:
                expectedRevision = lastSnapshot?.revision
            }
            let snapshot = try await connection.send(command, expectedRevision: expectedRevision)
            apply(snapshot)
        } catch {
            present(error: error)
            if (error as? AgentFailure)?.code == .staleRevision {
                await refresh()
            }
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
        case let .applyWallpaper(itemID, displayIDs):
            return .apply(itemID: itemID, displayIDs: displayIDs.sorted())
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
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

    private func apply(_ snapshot: AgentSnapshot) {
        guard lastSnapshot == nil || snapshot.revision.rawValue >= lastSnapshot!.revision.rawValue else {
            return
        }
        lastSnapshot = snapshot
        model.snapshot = snapshot.presentationValue(preserving: model.snapshot.notice)
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
        let activeImports = imports.filter { ![.complete, .cancelled, .failed].contains($0.phase) }

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
                    isBuiltIn: display.isBuiltIn
                )
            },
            transfers: imports.map(\.presentationValue),
            renderer: WALIRendererPresentation(
                state: rendererState(activeImports: activeImports),
                wallpaperTitle: activeItem?.name,
                thumbnailURL: activeItem?.posterURL,
                displayCount: displays.count { $0.assignedItemID != nil && $0.isOnline },
                cpuPercent: resourceUsage.cpuPercent,
                physicalMemoryBytes: Int64(clamping: resourceUsage.residentMemoryBytes)
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

    private func rendererState(activeImports: [AgentImportJob]) -> WALIRendererState {
        if let job = activeImports.first {
            return .converting(progress: job.progress)
        }
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
            detail: detail ?? phase.displayName,
            state: state
        )
    }
}

private extension AgentImportJob.Phase {
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
