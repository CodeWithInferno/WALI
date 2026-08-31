import AppKit
import Foundation
import WALIEngine
import WALIModel
import WALIUI
import WALIWire

public enum WALIAgentRuntimeError: LocalizedError {
    case storageUnavailable
    case mediaPipelineUnavailable

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "WALI's local storage is unavailable."
        case .mediaPipelineUnavailable: "WALI's media pipeline is not ready."
        }
    }
}

/// Long-lived composition root for engine, renderer, storage and XPC service.
@MainActor
public final class WALIAgentController: WALIUIActionHandling {
    public let model = WALIAppModel()

    private let renderer = WallpaperRenderer()
    private let stateStore: EngineSnapshotStore?
    private var router: AgentCommandRouter?
    private var serviceHost: AgentServiceHost?
    private var startupTask: Task<Void, Never>?
    private var purgeTasks: [UUID: Task<Void, Never>] = [:]

    public init() {
        stateStore = try? EngineSnapshotStore()
    }

    public func start() {
        guard startupTask == nil else { return }
        startupTask = Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    public func shutdown() {
        startupTask?.cancel()
        startupTask = nil
        for task in purgeTasks.values { task.cancel() }
        purgeTasks.removeAll()
        serviceHost?.stop()
        serviceHost = nil
        renderer.shutdown()
    }

    public func send(_ action: WALIUIAction) {
        Task { @MainActor [weak self] in
            await self?.perform(action)
        }
    }

    private func bootstrap() async {
        let restored: EngineSnapshot
        do {
            guard let stateStore else { throw WALIAgentRuntimeError.storageUnavailable }
            restored = try await stateStore.load()
        } catch {
            restored = EngineSnapshot()
            present(error)
        }

        let router = AgentCommandRouter(restoring: restored) { [weak self] effect, snapshot in
            guard let self else { return }
            try await self.execute(effect, snapshot: snapshot)
        }
        self.router = router

        let host = AgentServiceHost { request in
            await router.handle(request)
        }
        serviceHost = host
        host.start()

        renderer.onSnapshotChange = { [weak self] snapshot in
            self?.rendererDidChange(snapshot)
        }
        renderer.start()
        renderDesiredState(restored)
        renderer.setUserPaused(restored.isPausedByUser || restored.preferences.startPaused)
        await synchronizeRenderer(renderer.snapshot)
        await publishSnapshot()
    }

    private func perform(_ action: WALIUIAction) async {
        guard let router else { return }
        do {
            guard let command = try command(for: action) else { return }
            let state = await router.snapshot()
            let request = AgentRequest(
                expectedRevision: state.revision,
                command: command
            )
            let response = await router.handle(request)
            switch response.result {
            case let .snapshot(snapshot):
                model.snapshot = snapshot.agentPresentation
            case let .failure(failure):
                throw failure
            }
        } catch {
            present(error)
        }
    }

    private func command(for action: WALIUIAction) throws -> AgentCommand? {
        switch action {
        case let .importVideos(urls):
            let bookmarks = try urls.map {
                try $0.bookmarkData(options: [.withSecurityScope])
            }
            return .importFiles(bookmarks: bookmarks)
        case let .applyWallpaper(itemID, displayIDs):
            return .apply(itemID: itemID, displayIDs: displayIDs.sorted())
        case let .deleteWallpaper(itemID): return .removeItem(itemID: itemID)
        case let .restoreWallpaper(itemID): return .restoreItem(itemID: itemID)
        case let .revealWallpaper(itemID): return .revealItem(itemID: itemID)
        case let .cancelTransfer(id): return .cancelImport(jobID: id)
        case let .setPaused(paused): return .setPlaybackPaused(paused)
        case .nextWallpaper: return .nextWallpaper
        case .stopWallpaper: return .stopWallpaper
        case let .updatePreferences(preferences):
            return .setPreferences(.init(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                scaling: .init(rawValue: preferences.contentFit.rawValue) ?? .fill,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause
            ))
        case .openMainApplication, .openSettings:
            return .openForegroundApp
        case .quit:
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.wali.quitAll"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return .quit
        }
    }

    private func execute(_ effect: EngineEffect, snapshot: EngineSnapshot) async throws {
        switch effect {
        case .persist:
            guard let stateStore else { throw WALIAgentRuntimeError.storageUnavailable }
            try await stateStore.save(snapshot)
        case .render, .stopRendering:
            renderDesiredState(snapshot)
        case let .setPlaybackPaused(paused):
            renderer.setUserPaused(paused)
        case .startImport:
            throw WALIAgentRuntimeError.mediaPipelineUnavailable
        case .cancelImport:
            break
        case .removeArtifacts:
            break
        case .updateLaunchAtLogin:
            break
        case let .scheduleTrashPurge(itemID):
            scheduleTrashPurge(itemID)
        }
    }

    private func renderDesiredState(_ snapshot: EngineSnapshot) {
        let contentFit: PresentationContentFit = snapshot.preferences.scaling == .fit ? .fit : .fill
        let lowPowerResponse: PresentationLowPowerResponse
        switch snapshot.preferences.lowPowerBehavior {
        case .pause: lowPowerResponse = .pause
        case .reduceQuality: lowPowerResponse = .reduceQuality
        case .continuePlaying: lowPowerResponse = .continue
        }

        let items = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let assignments = snapshot.displays.compactMap { display -> WallpaperRenderingAssignment? in
            guard display.isOnline,
                  let itemID = display.assignedItemID,
                  let item = items[itemID] else {
                return nil
            }
            let primaryURL = snapshot.preferences.quality == .efficiency ? item.previewURL : item.masterURL
            return WallpaperRenderingAssignment(
                displayID: .init(rawValue: display.id),
                videoURL: primaryURL,
                efficientVideoURL: item.previewURL,
                posterURL: item.posterURL,
                contentFit: contentFit,
                lowPowerResponse: lowPowerResponse
            )
        }
        renderer.setAssignments(assignments)
    }

    private func rendererDidChange(_ snapshot: WallpaperRendererSnapshot) {
        Task { @MainActor [weak self] in
            await self?.synchronizeRenderer(snapshot)
        }
    }

    private func synchronizeRenderer(_ snapshot: WallpaperRendererSnapshot) async {
        guard let router else { return }
        do {
            let state = await router.snapshot()
            let displays = snapshot.displays.map { display in
                EngineDisplay(
                    id: display.id.rawValue,
                    name: display.name,
                    pixelWidth: Int((display.frame.width * display.backingScaleFactor).rounded()),
                    pixelHeight: Int((display.frame.height * display.backingScaleFactor).rounded()),
                    isMain: display.isMain,
                    isBuiltIn: display.isBuiltIn,
                    assignedItemID: nil,
                    isOnline: true
                )
            }
            let currentOnline = state.displays.filter(\.isOnline).map { ($0.id, $0.name, $0.pixelWidth, $0.pixelHeight, $0.isMain, $0.isBuiltIn) }
            let observed = displays.map { ($0.id, $0.name, $0.pixelWidth, $0.pixelHeight, $0.isMain, $0.isBuiltIn) }
            if !currentOnline.elementsEqual(observed, by: { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 && lhs.3 == rhs.3 && lhs.4 == rhs.4 && lhs.5 == rhs.5
            }) {
                _ = try await router.performInternal(.replaceDisplays(displays))
            }

            let playbackStatus = Self.playbackStatus(from: snapshot)
            if (await router.snapshot()).playbackStatus != playbackStatus {
                _ = try await router.performInternal(.setPlaybackStatus(playbackStatus))
            }
            await publishSnapshot()
        } catch {
            present(error)
        }
    }

    private static func playbackStatus(from snapshot: WallpaperRendererSnapshot) -> EnginePlaybackStatus {
        if snapshot.isUserPaused { return .paused }
        if !snapshot.automaticPauseReasons.isEmpty { return .suspended }
        if let failure = snapshot.sessions.lazy.compactMap({ session -> String? in
            if case let .failed(message) = session.status { return message }
            return nil
        }).first {
            return .failed(failure)
        }
        if snapshot.sessions.contains(where: { if case .preparing = $0.status { true } else { false } }) {
            return .preparing
        }
        if snapshot.sessions.contains(where: { if case .playing = $0.status { true } else { false } }) {
            return .playing
        }
        return .idle
    }

    private func scheduleTrashPurge(_ itemID: UUID) {
        purgeTasks[itemID]?.cancel()
        purgeTasks[itemID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let router = self.router else { return }
            _ = try? await router.performInternal(.purgeTrashed(itemID: itemID))
            self.purgeTasks.removeValue(forKey: itemID)
            await self.publishSnapshot()
        }
    }

    private func publishSnapshot() async {
        guard let router else { return }
        let response = await router.handle(AgentRequest(command: .snapshot))
        if case let .snapshot(snapshot) = response.result {
            model.snapshot = snapshot.agentPresentation
        }
    }

    private func present(_ error: Error) {
        model.snapshot.notice = .init(
            kind: .error,
            title: "WALI Needs Attention",
            message: error.localizedDescription
        )
    }
}

private extension AgentSnapshot {
    var agentPresentation: WALIUISnapshot {
        let activeIDs = Set(displays.compactMap(\.assignedItemID))
        let activeItem = items.first { activeIDs.contains($0.id) }
        let state: WALIRendererState = switch playback {
        case .idle: .stopped
        case .preparing: .converting(progress: nil)
        case .playing: .playing
        case .paused: .userPaused
        case .suspended: .automaticallyPaused(reason: "System activity")
        case .failed: .error(message: "Playback failed")
        }
        return WALIUISnapshot(
            renderer: .init(
                state: state,
                wallpaperTitle: activeItem?.name,
                thumbnailURL: activeItem?.posterURL,
                displayCount: displays.count { $0.isOnline && $0.assignedItemID != nil },
                cpuPercent: resourceUsage.cpuPercent,
                physicalMemoryBytes: Int64(clamping: resourceUsage.residentMemoryBytes)
            ),
            preferences: .init(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause,
                contentFit: .init(rawValue: preferences.scaling.rawValue) ?? .fill
            ),
            storage: .init(
                usedBytes: Int64(clamping: resourceUsage.storageUsedBytes),
                limitBytes: resourceUsage.storageLimitBytes.map(Int64.init(clamping:))
            )
        )
    }
}
