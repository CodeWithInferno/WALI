import AppKit
import Foundation
import WALIEngine
import WALIModel
import WALIUI
import WALIWire
#if !WALI_APP_STORE
import WALILockScreenWire
#endif

public enum WALIAgentRuntimeError: LocalizedError {
    case storageUnavailable
    case invalidImportState

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "WALI's local storage is unavailable."
        case .invalidImportState: "WALI could not recover this import safely."
        }
    }
}

/// Long-lived composition root for engine, renderer, storage and XPC service.
@MainActor
public final class WALIAgentController: WALIUIActionHandling {
    #if WALI_APP_STORE
    public static let shared = WALIAgentController()
    public private(set) var quitPrepared = false
    private var isShuttingDown = false
    #endif
    public let model = WALIAppModel()

    private let renderer = WallpaperRenderer()
    private let diagnostics = ProcessDiagnostics()
    private var resourceObservationTokens: [any NSObjectProtocol] = []
    private lazy var rendererSynchronization = RendererObservationSynchronizer { [weak self] in
        await self?.synchronizeRenderer()
    }
    private let stateStore: EngineSnapshotStore?
    private let runtimeStore: RuntimeStore?
    #if WALI_APP_STORE
    private let presentationCache: StorePresentationCache?
    #endif
    #if !WALI_APP_STORE
    private let lockScreenHelper: LockScreenHelperConnection?
    private let lockScreenMetadataDirectory: URL?
    private var hasAttemptedLockScreenActivation = false
    private var hasCompletedDirectQuit = false
    #endif
    private let transcoder: TranscoderConnection
    private let catalogInstallCoordinator: CatalogInstallCoordinator?
    private var router: AgentCommandRouter?
    private var serviceHost: AgentServiceHost?
    private var startupTask: Task<Void, Never>?
    private var purgeTasks: [UUID: Task<Void, Never>] = [:]
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var importContexts: [UUID: LocalImportContext] = [:]
    private var importProgressUpdates: [UUID: ImportProgressUpdate] = [:]
    #if !WALI_APP_STORE
    private var lockScreenTask: Task<Void, Never>?
    private var lockScreenPlaybackRestartTask: Task<Void, Never>?
    #endif

    public init() {
        let transcoder = TranscoderConnection()
        self.transcoder = transcoder
        let libraryPaths = try? LibraryPaths.applicationSupport()
        #if !WALI_APP_STORE
        lockScreenMetadataDirectory = libraryPaths?.metadata
        #endif
        stateStore = try? EngineSnapshotStore()
        runtimeStore = libraryPaths.map(RuntimeStore.init(paths:))
        #if WALI_APP_STORE
        presentationCache = libraryPaths.flatMap { try? StorePresentationCache(paths: $0) }
        #endif
        if let runtimeStore,
           let libraryPaths,
           let trustStore = try? CatalogTrustStore.configured(
               fileURL: libraryPaths.metadata.appendingPathComponent(
                   "catalog-trust-transition.json",
                   isDirectory: false
               )
           ),
           let quarantineRoot = try? CatalogInstallCoordinator.defaultQuarantineRoot() {
            let revocations = CatalogRevocationStore(
                fileURL: libraryPaths.metadata.appendingPathComponent(
                    "catalog-revocations.json",
                    isDirectory: false
                ),
                trustStore: trustStore
            )
            catalogInstallCoordinator = CatalogInstallCoordinator(
                runtimeStore: runtimeStore,
                trustStore: trustStore,
                revocationStore: revocations,
                quarantineRoot: quarantineRoot,
                transcode: { request in try await transcoder.transcode(request) }
            )
        } else {
            catalogInstallCoordinator = nil
        }
        #if !WALI_APP_STORE
        lockScreenHelper = libraryPaths.map { LockScreenHelperConnection.live(libraryPaths: $0) }
        #endif
    }

    public func start() {
        guard startupTask == nil else { return }
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        rendererSynchronization.start()
        renderer.onSnapshotChange = { [weak self] _ in
            self?.rendererSynchronization.request()
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            resourceObservationTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rendererSynchronization.request() }
            })
        }
        #if !WALI_APP_STORE
        renderer.onPresentationRefresh = { [weak self] in
            self?.scheduleLockScreenReconciliation()
        }
        renderer.onSessionLock = { [weak self] in
            self?.scheduleLockScreenPlaybackRestart()
        }
        #endif
        renderer.start()
        startupTask = Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    public func shutdown() {
        stopResourceObservation()
        startupTask?.cancel()
        startupTask = nil
        #if !WALI_APP_STORE
        lockScreenTask?.cancel()
        lockScreenTask = nil
        lockScreenPlaybackRestartTask?.cancel()
        lockScreenPlaybackRestartTask = nil
        #endif
        for task in purgeTasks.values { task.cancel() }
        purgeTasks.removeAll()
        for task in importTasks.values { task.cancel() }
        importTasks.removeAll()
        importContexts.removeAll()
        importProgressUpdates.removeAll()
        Task { await transcoder.invalidate() }
        serviceHost?.stop()
        serviceHost = nil
        renderer.shutdown()
    }

    #if WALI_APP_STORE
    /// Also used by the agent's native Quit menu and application termination.
    public func prepareForQuit() async throws {
        guard !quitPrepared else { return }
        if let router {
            let response = await router.handle(.init(command: .quit))
            if case let .failure(error) = response.result { throw error }
        } else {
            try await performStoreShutdown()
        }
    }

    private func performStoreShutdown() async throws {
        isShuttingDown = true
        stopResourceObservation()
        startupTask?.cancel()
        for task in purgeTasks.values { task.cancel() }
        for task in importTasks.values { task.cancel() }
        renderer.shutdown()
        model.snapshot.renderer = .stopped
        // This durable gate rejects late local and catalog publication before
        // cancellation or a lost XPC connection can deliver another result.
        if let runtimeStore { try await runtimeStore.interruptActiveImportsForShutdown() }
        try await transcoder.shutdown()
        try await router?.drainTransactionsForShutdown()
        if let stateStore, let router { try await stateStore.save(await router.snapshot()) }
        importTasks.removeAll()
        importContexts.removeAll()
        importProgressUpdates.removeAll()
        purgeTasks.removeAll()
        try await serviceHost?.notifyForegroundTermination()
        quitPrepared = true
    }

    private func terminateAfterQuitReply() {
        guard quitPrepared else { return }
        serviceHost?.stop()
        serviceHost = nil
        NSApplication.shared.terminate(nil)
    }
    #endif

    public func send(_ action: WALIUIAction) {
        Task { @MainActor [weak self] in
            await self?.perform(action)
        }
    }

    private func bootstrap() async {
        var restored: EngineSnapshot
        do {
            guard let stateStore else { throw WALIAgentRuntimeError.storageUnavailable }
            restored = try await stateStore.load()
        } catch {
            restored = EngineSnapshot()
            present(error)
        }

        #if WALI_APP_STORE
        var interruptedCatalogInstalls = 0
        #endif
        var durableSnapshot: RuntimeSnapshot?
        if let runtimeStore {
            do {
                _ = try await runtimeStore.open()
                #if WALI_APP_STORE
                interruptedCatalogInstalls = try await runtimeStore.recoverCatalogImportsRequiringFreshVerification()
                #endif
                durableSnapshot = try await runtimeStore.snapshot()
                if let durableSnapshot {
                    restored = Self.reconcile(restored, with: durableSnapshot)
                }
            } catch {
                present(error)
            }
        }

        #if WALI_APP_STORE
        guard !isShuttingDown, !Task.isCancelled else { return }
        restored.preferences.lockScreenContinuityEnabled = false
        let shutdownHandler: AgentShutdownHandler? = { [weak self] in
            try await self?.performStoreShutdown()
        }
        #else
        let shutdownHandler: AgentShutdownHandler? = nil
        #endif
        let router = AgentCommandRouter(
            restoring: restored,
            catalogInstallHandler: { [weak self] install, idempotencyKey, revision in
                guard let coordinator = self?.catalogInstallCoordinator else {
                    throw CatalogTrustStoreError.invalidConfiguration
                }
                let item = try await coordinator.install(
                    install,
                    idempotencyKey: idempotencyKey,
                    acceptedRevision: revision
                )
                // The catalog handler runs while AgentCommandRouter owns its
                // transaction gate. Updating storage usage synchronously here
                // would re-enter the router and wait forever on that same gate.
                // Defer accounting until the install transaction has committed.
                Task { @MainActor [weak self] in
                    await self?.updateStorageUsage()
                }
                return item
            },
            catalogRevocationHandler: { [weak self] update in
                guard let coordinator = self?.catalogInstallCoordinator else {
                    throw CatalogTrustStoreError.invalidConfiguration
                }
                try await coordinator.updateRevocations(update)
            },
            catalogTrustTransitionHandler: { [weak self] update in
                guard let coordinator = self?.catalogInstallCoordinator else {
                    throw CatalogTrustStoreError.invalidConfiguration
                }
                try await coordinator.updateTrustTransition(update)
            },
            shutdownHandler: shutdownHandler,
            presentationHandler: { [weak self] itemIDs, snapshot in
                #if WALI_APP_STORE
                guard let cache = self?.presentationCache else { throw WALIAgentRuntimeError.storageUnavailable }
                return try cache.prepare(itemIDs, snapshot: snapshot)
                #else
                return snapshot
                #endif
            }
        ) { [weak self] step, snapshot in
            guard let self else { return .unchanged }
            switch step {
            case let .preflight(action):
                try await self.preflight(action, snapshot: snapshot)
                return .unchanged
            case let .effect(effect):
                return try await self.execute(effect, snapshot: snapshot)
            }
        }
        self.router = router
        #if WALI_APP_STORE
        if interruptedCatalogInstalls > 0 {
            await router.replaceRuntimeNotice(.init(
                kind: .warning,
                title: "Catalog Installs Need Retry",
                message: "Catalog installs were interrupted. Retry them from Marketplace to verify current availability and permissions."
            ))
        }
        guard !isShuttingDown, !Task.isCancelled else { return }
        #endif

        #if WALI_APP_STORE
        let presentationCache = self.presentationCache
        #endif
        let host = AgentServiceHost(afterQuitReply: { [weak self] in
            #if WALI_APP_STORE
            await self?.terminateAfterQuitReply()
            #else
            await self?.completeDirectQuit()
            #endif
        }) { [weak self] request in
            if case .diagnosticsSnapshot = request.command {
                await self?.refreshRendererObservation()
            }
            var response = await router.handle(request)
            #if WALI_APP_STORE
            if case let .snapshot(snapshot) = response.result {
                // Quit needs no presentation files, which may already be closed.
                switch request.command {
                case .quit, .preparePresentation: return response
                default: break
                }
                do {
                    guard let presentationCache else { throw WALIAgentRuntimeError.storageUnavailable }
                    response = AgentResponse(requestID: response.requestID, result: .snapshot(
                        try presentationCache.project(snapshot)
                    ))
                } catch {
                    return AgentResponse(requestID: response.requestID, result: .failure(
                        AgentFailure(code: .storageUnavailable, message: error.localizedDescription)
                    ))
                }
            }
            #endif
            guard case .diagnosticsSnapshot = request.command,
                  let sample = await self?.takeDiagnosticsSample() else {
                return response
            }
            return response.replacingResourceUsage(with: sample)
        }
        serviceHost = host
        host.start()

        renderDesiredState(restored)
        #if !WALI_APP_STORE
        do {
            try await reconcileLockScreen(restored)
            await router.replaceRuntimeNotice(nil)
        } catch {
            await router.replaceRuntimeNotice(Self.lockScreenNotice(for: error))
        }
        #endif
        renderer.setUserPaused(restored.isPausedByUser || restored.preferences.startPaused)
        for item in restored.trashedItems {
            scheduleTrashPurge(item.id)
        }
        await refreshRendererObservation()
        guard !Task.isCancelled else { return }
        await publishSnapshot()
        if let durableSnapshot {
            await resumeImports(from: durableSnapshot)
        }
    }

    private func perform(_ action: WALIUIAction) async {
        #if WALI_APP_STORE
        if case .quit = action { NSApplication.shared.terminate(nil); return }
        guard !isShuttingDown else { return }
        #else
        if case .quit = action {
            do {
                if try DirectAgentQuit.requestForegroundQuit() { return }
                if let router {
                    let response = await router.handle(.init(command: .quit))
                    if case let .failure(failure) = response.result { throw failure }
                }
                completeDirectQuit()
            } catch {
                present(error)
            }
            return
        }
        #endif
        guard let router else { return }
        do {
            if case .refreshDiagnostics = action { await refreshRendererObservation() }
            let state = await router.snapshot()
            guard let command = try command(for: action, preserving: state.preferences) else { return }
            let request = AgentRequest(
                expectedRevision: state.revision,
                command: command
            )
            let response = await router.handle(request)
            #if WALI_APP_STORE
            guard !isShuttingDown else { return }
            #endif
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

    #if !WALI_APP_STORE
    private func completeDirectQuit() {
        guard !hasCompletedDirectQuit else { return }
        hasCompletedDirectQuit = true
        shutdown()
        NSApplication.shared.terminate(nil)
    }
    #endif

    private func command(
        for action: WALIUIAction,
        preserving currentPreferences: EnginePreferences = .init()
    ) throws -> AgentCommand? {
        switch action {
        case let .importVideos(urls):
            #if WALI_APP_STORE
            _ = urls
            throw AgentFailure(code: .invalidRequest, message: "Import videos from the WALI library window.")
            #else
            let bookmarks = try urls.map {
                try $0.bookmarkData(options: [.withSecurityScope])
            }
            return .importFiles(bookmarks: bookmarks)
            #endif
        case let .applyWallpaper(itemID, displayIDs, contentFit):
            return .apply(
                itemID: itemID,
                displayIDs: displayIDs.sorted(),
                scaling: .init(rawValue: contentFit.rawValue) ?? .fill
            )
        case let .deleteWallpaper(itemID): return .removeItem(itemID: itemID)
        case let .restoreWallpaper(itemID): return .restoreItem(itemID: itemID)
        case let .revealWallpaper(itemID): return .revealItem(itemID: itemID)
        case let .cancelTransfer(id): return .cancelImport(jobID: id)
        case let .setPaused(paused): return .setPlaybackPaused(paused)
        case .nextWallpaper: return .nextWallpaper
        case .stopWallpaper: return .stopWallpaper
        case .refreshDiagnostics:
            applyDiagnosticsSample(takeDiagnosticsSample())
            return nil
        case let .updatePreferences(preferences):
            return .setPreferences(.init(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                pauseOnBattery: currentPreferences.pauseOnBattery,
                pauseWhenOccluded: currentPreferences.pauseWhenOccluded,
                scaling: .init(rawValue: preferences.contentFit.rawValue) ?? .fill,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause,
                muted: currentPreferences.muted,
                lockScreenContinuityEnabled: preferences.lockScreenContinuityEnabled
            ))
        case .openMainApplication:
            return .openForegroundApp
        case .openSettings:
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.wali.openSettings"),
                object: Bundle.main.object(forInfoDictionaryKey: "WALIControlServiceName") as? String
                    ?? Bundle.main.bundleIdentifier,
                userInfo: nil,
                deliverImmediately: true
            )
            return .openForegroundApp
        case .quit:
            return .quit
        }
    }

    private func preflight(_ action: EngineAction, snapshot: EngineSnapshot) async throws {
        #if WALI_APP_STORE
        if case let .setPreferences(proposed) = action, proposed.lockScreenContinuityEnabled {
            throw AgentFailure(code: .invalidRequest, message: "This setting is unavailable in this distribution.")
        }
        #else
        guard case let .setPreferences(proposed) = action,
              !snapshot.preferences.lockScreenContinuityEnabled,
              proposed.lockScreenContinuityEnabled else { return }
        guard let lockScreenHelper else { throw WALIAgentRuntimeError.storageUnavailable }
        _ = try await lockScreenHelper.status()
        _ = try await lockScreenHelperReleaseIntent(from: snapshot)
        #endif
    }

    private func execute(
        _ effect: EngineEffect,
        snapshot: EngineSnapshot
    ) async throws -> EngineEffectOutcome {
        let authoritative = if let router {
            await router.snapshot()
        } else {
            snapshot
        }
        switch effect {
        case .persist:
            guard let stateStore else { throw WALIAgentRuntimeError.storageUnavailable }
            try await stateStore.save(authoritative)
            if let runtimeStore {
                let qualityIntent: PresentationQualityIntent = switch authoritative.preferences.quality {
                case .automatic: .automatic
                case .efficiency: .efficiency
                case .quality: .quality
                }
                let lowPowerResponse: PresentationLowPowerResponse = switch authoritative.preferences.lowPowerBehavior {
                case .pause: .pause
                case .reduceQuality: .reduceQuality
                case .continuePlaying: .continue
                }
                let preferences = RuntimePreferences(
                    launchAtLogin: authoritative.preferences.launchAtLogin,
                    qualityIntent: qualityIntent,
                    lowPowerResponse: lowPowerResponse,
                    previewsOnHover: try await runtimeStore.snapshot().preferences.previewsOnHover,
                    lockScreenContinuityEnabled: authoritative.preferences.lockScreenContinuityEnabled
                )
                if try await runtimeStore.snapshot().preferences != preferences {
                    try await runtimeStore.updatePreferences(preferences)
                }
            }
        case .render, .stopRendering, .reconcileRendering:
            renderDesiredState(authoritative)
            #if !WALI_APP_STORE
            do {
                try await reconcileLockScreen(authoritative)
                return .replaceRuntimeNotice(nil)
            } catch {
                return .replaceRuntimeNotice(Self.lockScreenNotice(for: error))
            }
            #endif
        case .setPlaybackPaused:
            renderer.setUserPaused(authoritative.isPausedByUser)
        case let .startImport(jobID, bookmark):
            startImport(jobID: jobID, bookmark: bookmark, snapshot: authoritative)
        case let .cancelImport(jobID):
            await cancelImport(jobID: jobID, acceptedRevision: authoritative.revision)
        case let .removeArtifacts(itemID):
            if let runtimeStore,
               !authoritative.items.contains(where: { $0.id == itemID }) {
                try await runtimeStore.deleteLibraryItem(
                    LibraryItemID(itemID.uuidString.lowercased())
                )
                await updateStorageUsage()
            }
        case .updateLaunchAtLogin:
            break
        case let .scheduleTrashPurge(itemID):
            scheduleTrashPurge(itemID)
        }
        return .unchanged
    }

    private func startImport(
        jobID: UUID,
        bookmark: Data,
        snapshot: EngineSnapshot
    ) {
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        guard importTasks[jobID] == nil,
              snapshot.imports.first(where: { $0.id == jobID })?.phase == .queued else {
            return
        }
        importTasks[jobID] = Task { @MainActor [weak self] in
            await self?.prepareAndRunImport(
                jobID: jobID,
                bookmark: bookmark,
                acceptedRevision: snapshot.revision
            )
        }
    }

    private func prepareAndRunImport(
        jobID: UUID,
        bookmark: Data,
        acceptedRevision: EngineRevision
    ) async {
        do {
            guard let runtimeStore else { throw WALIAgentRuntimeError.storageUnavailable }
            #if WALI_APP_STORE
            let sourceAccess = try AgentSourceAuthorization.openPersistent(bookmark)
            defer { sourceAccess.close() }
            let sourceURL = sourceAccess.url
            #else
            let sourceURL = try Self.resolveBookmark(bookmark)
            #endif
            let context = try await runtimeStore.beginImport(
                sourceURL: sourceURL,
                sourceBookmark: bookmark,
                idempotencyKey: IdempotencyKey(jobID.uuidString.lowercased()),
                expectedEngineRevision: acceptedRevision
            )
            importContexts[jobID] = context
            if Task.isCancelled {
                try? await runtimeStore.cancelImport(
                    jobID: context.jobID,
                    acceptedRevision: acceptedRevision
                )
                throw CancellationError()
            }
            await runImport(jobID: jobID, context: context, sourceBookmark: bookmark)
        } catch is CancellationError {
            importTasks.removeValue(forKey: jobID)
            importContexts.removeValue(forKey: jobID)
        } catch {
            importTasks.removeValue(forKey: jobID)
            importContexts.removeValue(forKey: jobID)
            await failImport(jobID: jobID, error: error)
        }
    }

    private func launchImport(
        jobID: UUID,
        context: LocalImportContext,
        sourceBookmark: Data?
    ) {
        guard importTasks[jobID] == nil else { return }
        importTasks[jobID] = Task { @MainActor [weak self] in
            await self?.runImport(
                jobID: jobID,
                context: context,
                sourceBookmark: sourceBookmark
            )
        }
    }

    private func runImport(
        jobID: UUID,
        context: LocalImportContext,
        sourceBookmark: Data?
    ) async {
        defer {
            importTasks.removeValue(forKey: jobID)
            importContexts.removeValue(forKey: jobID)
            importProgressUpdates.removeValue(forKey: jobID)
        }
        guard let runtimeStore, let router else { return }
        #if !WALI_APP_STORE
        let hasSecurityScope = context.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { context.sourceURL.stopAccessingSecurityScopedResource() }
        }
        #endif

        do {
            #if WALI_APP_STORE
            guard let sourceBookmark else { throw WALIAgentRuntimeError.invalidImportState }
            let sourceAccess = try AgentSourceAuthorization.openPersistent(sourceBookmark, expectedURL: context.sourceURL)
            defer { sourceAccess.close() }
            #endif
            try await runtimeStore.markImportDispatched(
                jobID: context.jobID,
                generation: context.generation
            )
            _ = try await router.performInternal(.updateImport(
                id: jobID,
                phase: .inspecting,
                progress: 0.05,
                detail: "Inspecting source video"
            ))
            let durableUUID = try Self.uuid(for: context.jobID)
            #if !WALI_APP_STORE
            guard let sourceBookmark else {
                throw WALIAgentRuntimeError.invalidImportState
            }
            #endif
            let output = try await transcoder.transcode(
                try LocalImportTranscoderRequestFactory.make(
                    jobID: durableUUID,
                    attemptGeneration: context.generation.rawValue,
                    sourceBookmark: sourceBookmark,
                    sourceURL: context.sourceURL,
                    stagingDirectoryURL: context.stagingDirectoryURL
                ),
                progress: { [weak self] progress in
                    Task { @MainActor in
                        await self?.applyTranscodeProgress(progress, to: jobID)
                    }
                }
            )
            try Task.checkCancellation()

            let sourceDigest = try ContentDigest(algorithm: .sha256, value: output.sourceDigest)
            let current = await router.snapshot()
            if let duplicate = current.items.first(where: { $0.contentDigest == sourceDigest.value }) {
                try await runtimeStore.finishImportAttempt(
                    jobID: context.jobID,
                    generation: context.generation,
                    outcome: .failed
                )
                _ = try await router.performInternal(.finishImport(jobID: jobID, item: duplicate))
                await publishSnapshot()
                return
            }

            _ = try await router.performInternal(.updateImport(
                id: jobID,
                phase: .installing,
                progress: 0.88,
                detail: "Verifying and installing local copies"
            ))
            try await runtimeStore.finishImportAttempt(
                jobID: context.jobID,
                generation: context.generation,
                outcome: .succeeded
            )

            var installed: [StoredArtifact] = []
            for claim in output.artifacts {
                try Task.checkCancellation()
                let candidate = try StagedArtifactCandidate(
                    jobID: context.jobID,
                    generation: context.generation,
                    role: claim.storageRole,
                    mediaKind: claim.storageMediaKind,
                    stagedURL: claim.stagedURL,
                    claimedDigest: ContentDigest(algorithm: .sha256, value: claim.digest),
                    claimedByteCount: claim.byteCount
                )
                installed.append(try await runtimeStore.installArtifact(candidate))
            }
            try Task.checkCancellation()

            let record = try LibraryRecordFactory.makeRecord(
                itemID: jobID,
                displayName: output.displayName,
                sourceFileName: context.sourceURL.lastPathComponent,
                sourceDigest: sourceDigest,
                artifacts: installed
            )
            try await runtimeStore.commitImport(
                jobID: context.jobID,
                generation: context.generation,
                record: record
            )
            let engineItem = try LibraryRecordFactory.makeEngineItem(from: record)
            _ = try await router.performInternal(.finishImport(jobID: jobID, item: engineItem))
            await updateStorageUsage()
            await publishSnapshot()
        } catch is CancellationError {
            return
        } catch {
            try? await runtimeStore.finishImportAttempt(
                jobID: context.jobID,
                generation: context.generation,
                outcome: .failed
            )
            await failImport(jobID: jobID, error: error)
        }
    }

    private func failImport(jobID: UUID, error: Error) async {
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        guard let router else { return }
        let current = await router.snapshot()
        if let job = current.imports.first(where: { $0.id == jobID }),
           job.phase != .cancelled,
           job.phase != .complete {
            _ = try? await router.performInternal(.updateImport(
                id: jobID,
                phase: .failed,
                progress: job.progress,
                detail: error.localizedDescription
            ))
            present(error)
            await publishSnapshot()
        }
    }

    private func applyTranscodeProgress(
        _ progress: TranscoderProgress,
        to jobID: UUID
    ) async {
        guard let router else { return }
        let mapped = Self.engineProgress(progress)
        let now = Date()
        if let previous = importProgressUpdates[jobID],
           previous.phase == mapped.phase,
           now.timeIntervalSince(previous.timestamp) < 1 {
            return
        }
        let current = await router.snapshot()
        guard let job = current.imports.first(where: { $0.id == jobID }),
              job.phase != .cancelled,
              job.phase != .complete,
              job.phase != .failed else { return }
        importProgressUpdates[jobID] = ImportProgressUpdate(
            phase: mapped.phase,
            progress: mapped.progress,
            timestamp: now
        )
        _ = try? await router.performInternal(.updateImport(
            id: jobID,
            phase: mapped.phase,
            progress: max(job.progress, mapped.progress),
            detail: mapped.detail
        ))
    }

    private static func engineProgress(
        _ progress: TranscoderProgress
    ) -> (phase: EngineImportJob.Phase, progress: Double, detail: String) {
        let fraction = min(max(progress.fractionCompleted, 0), 1)
        switch progress.phase {
        case .queued:
            return (.queued, 0.02, "Waiting for the media converter")
        case .inspecting:
            return (.inspecting, 0.03 + 0.04 * fraction, "Inspecting source video")
        case .hashingSource:
            return (.inspecting, 0.07 + 0.03 * fraction, "Reading source video")
        case .transcodingMaster:
            return (.transcoding, 0.10 + 0.55 * fraction, "Creating high-quality wallpaper")
        case .transcodingPreview:
            return (.transcoding, 0.65 + 0.18 * fraction, "Creating efficient preview")
        case .generatingPoster:
            return (.poster, 0.83 + 0.03 * fraction, "Creating poster image")
        case .verifyingOutputs:
            return (.installing, 0.86 + 0.02 * fraction, "Verifying converted media")
        case .complete:
            return (.installing, 0.88, "Installing local copies")
        }
    }

    private func cancelImport(jobID: UUID, acceptedRevision: EngineRevision) async {
        guard let context = importContexts[jobID] else {
            importTasks[jobID]?.cancel()
            return
        }
        importTasks[jobID]?.cancel()
        if let durableUUID = try? Self.uuid(for: context.jobID) {
            try? await transcoder.cancel(
                jobID: durableUUID,
                attemptGeneration: context.generation.rawValue
            )
        }
        if let runtimeStore {
            try? await runtimeStore.cancelImport(
                jobID: context.jobID,
                acceptedRevision: acceptedRevision
            )
        }
    }

    private func resumeImports(from durableSnapshot: RuntimeSnapshot) async {
        guard let runtimeStore, let router else { return }
        let engineSnapshot = await router.snapshot()
        for persisted in durableSnapshot.importJobs {
            guard let engineID = UUID(uuidString: persisted.job.header.idempotencyKey.rawValue),
                  let engineJob = engineSnapshot.imports.first(where: { $0.id == engineID }),
                  engineJob.phase != .complete,
                  engineJob.phase != .cancelled else {
                continue
            }
            do {
                let context: LocalImportContext
                switch persisted.job.header.phase {
                case .attemptActive:
                    guard let generation = persisted.job.header.attemptGeneration else {
                        throw WALIAgentRuntimeError.invalidImportState
                    }
                    context = LocalImportContext(
                        jobID: persisted.job.header.id,
                        generation: generation,
                        sourceURL: persisted.sourceURL,
                        stagingDirectoryURL: runtimeStore.paths.staging.appendingPathComponent(
                            persisted.stagingDirectoryName,
                            isDirectory: true
                        )
                    )
                case .attemptTerminal, .awaitingInstallation:
                    context = try await runtimeStore.retryImport(jobID: persisted.job.header.id)
                case .pending, .terminal:
                    continue
                }
                _ = try await router.performInternal(.updateImport(
                    id: engineID,
                    phase: .queued,
                    progress: 0,
                    detail: "Resuming interrupted import"
                ))
                importContexts[engineID] = context
                launchImport(
                    jobID: engineID,
                    context: context,
                    sourceBookmark: persisted.sourceBookmark
                )
            } catch {
                _ = try? await router.performInternal(.updateImport(
                    id: engineID,
                    phase: .failed,
                    progress: engineJob.progress,
                    detail: error.localizedDescription
                ))
            }
        }
    }

    private func updateStorageUsage() async {
        guard let runtimeStore, let router,
              let durable = try? await runtimeStore.snapshot() else { return }
        let used = durable.library
            .flatMap(\.artifacts)
            .reduce(UInt64(0)) { $0 &+ $1.byteCount }
        _ = try? await router.recordStorageUsage(used)
    }

    private static func reconcile(
        _ engine: EngineSnapshot,
        with durable: RuntimeSnapshot
    ) -> EngineSnapshot {
        var result = engine
        let records = Dictionary(uniqueKeysWithValues: durable.library.compactMap { record in
            UUID(uuidString: record.item.id.rawValue).map { ($0, record) }
        })
        let durableIDs = Set(records.keys)
        result.items.removeAll { !durableIDs.contains($0.id) }
        result.trashedItems.removeAll { !durableIDs.contains($0.id) }

        let existing = Dictionary(
            uniqueKeysWithValues: (result.items + result.trashedItems).map { ($0.id, $0) }
        )
        result.items = result.items.compactMap { item in
            guard let record = records[item.id] else { return nil }
            return try? LibraryRecordFactory.makeEngineItem(from: record, preserving: item)
        }
        result.trashedItems = result.trashedItems.compactMap { item in
            guard let record = records[item.id] else { return nil }
            return try? LibraryRecordFactory.makeEngineItem(from: record, preserving: item)
        }
        let knownIDs = Set(result.items.map(\.id) + result.trashedItems.map(\.id))
        for (id, record) in records where !knownIDs.contains(id) {
            if let item = try? LibraryRecordFactory.makeEngineItem(
                from: record,
                preserving: existing[id]
            ) {
                result.items.append(item)
            }
        }
        result.items.sort { $0.createdAt > $1.createdAt }
        result.resourceUsage.storageUsedBytes = durable.library
            .flatMap(\.artifacts)
            .reduce(UInt64(0)) { $0 &+ $1.byteCount }
        let committedEngineIDs = Set(durable.importJobs.compactMap { persisted -> UUID? in
            guard persisted.job.header.phase == .terminal,
                  persisted.job.header.terminalOutcome == .succeeded else { return nil }
            return UUID(uuidString: persisted.job.header.idempotencyKey.rawValue)
        })
        for index in result.imports.indices where committedEngineIDs.contains(result.imports[index].id) {
            result.imports[index].phase = .complete
            result.imports[index].progress = 1
            result.imports[index].detail = nil
        }
        var knownImportIDs = Set(result.imports.map(\.id))
        for persisted in durable.importJobs {
            guard persisted.job.header.phase == .terminal,
                  persisted.job.header.terminalOutcome == .succeeded,
                  let committed = persisted.job.committedResult,
                  let itemID = UUID(uuidString: committed.libraryItemID.rawValue),
                  let record = records[itemID], record.item.origin == .catalog,
                  record.release.id == committed.releaseID,
                  let id = UUID(uuidString: persisted.job.header.idempotencyKey.rawValue),
                  knownImportIDs.insert(id).inserted else { continue }
            result.imports.append(EngineImportJob(
                id: id, fileName: record.item.displayName,
                phase: .complete, progress: 1, createdAt: persisted.createdAt
            ))
        }
        result.imports.sort { $0.createdAt > $1.createdAt }
        return result
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private static func uuid(for jobID: JobID) throws -> UUID {
        guard let value = UUID(uuidString: jobID.rawValue) else {
            throw WALIAgentRuntimeError.invalidImportState
        }
        return value
    }

    private func renderDesiredState(_ snapshot: EngineSnapshot) {
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
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
            let content: WallpaperRenderingContent
            switch item.mediaContent {
            case let .video(masterURL, previewURL, _):
                content = .video(
                    videoURL: snapshot.preferences.quality == .efficiency ? previewURL : masterURL,
                    efficientVideoURL: previewURL, posterURL: item.posterURL,
                    lowPowerResponse: lowPowerResponse
                )
            case let .still(imageURL):
                content = .still(imageURL: imageURL)
            }
            return WallpaperRenderingAssignment(
                displayID: .init(rawValue: display.id), content: content,
                contentFit: PresentationContentFit(
                    rawValue: (display.scaling ?? snapshot.preferences.scaling).rawValue
                ) ?? .fill
            )
        }
        renderer.setAssignments(assignments)
    }

    #if !WALI_APP_STORE
    private func scheduleLockScreenReconciliation() {
        lockScreenTask?.cancel()
        lockScreenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let router = self.router else { return }
            let snapshot = await router.snapshot()
            do {
                try await self.reconcileLockScreen(snapshot)
                await router.replaceRuntimeNotice(nil)
            } catch {
                await router.replaceRuntimeNotice(Self.lockScreenNotice(for: error))
            }
            await self.publishSnapshot()
        }
    }

    private func scheduleLockScreenPlaybackRestart() {
        lockScreenPlaybackRestartTask?.cancel()
        lockScreenPlaybackRestartTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, let router = self.router else { return }
            let snapshot = await router.snapshot()
            do {
                try await self.reconcileLockScreen(snapshot, restartPlayback: true)
                await router.replaceRuntimeNotice(nil)
            } catch {
                await router.replaceRuntimeNotice(Self.lockScreenNotice(for: error))
            }
            await self.publishSnapshot()
        }
    }

    private func reconcileLockScreen(
        _ snapshot: EngineSnapshot,
        restartPlayback: Bool = false
    ) async throws {
        guard let lockScreenHelper else { return }
        if snapshot.preferences.lockScreenContinuityEnabled {
            // Remain conservative if disabling races an activation or its reply
            // is lost before the helper's ownership journal becomes visible.
            hasAttemptedLockScreenActivation = true
            try await lockScreenHelper.activate(
                try await lockScreenHelperReleaseIntent(from: snapshot),
                restartPlayback: restartPlayback
            )
        } else {
            if !hasAttemptedLockScreenActivation {
                guard try hasLockScreenRecoveryState() else { return }
            }
            try await lockScreenHelper.deactivate()
        }
    }

    private func hasLockScreenRecoveryState() throws -> Bool {
        guard let lockScreenMetadataDirectory else { throw WALIAgentRuntimeError.storageUnavailable }
        for name in ["lock-screen-helper-state.json", "lock-screen-choice-journal.json", "lock-screen-asset-journal.json"] {
            let path = lockScreenMetadataDirectory.appendingPathComponent(name).path
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
                return true
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
        }
        return false
    }

    private func lockScreenHelperReleaseIntent(
        from snapshot: EngineSnapshot
    ) async throws -> LockScreenHelperReleaseIntent {
        guard let runtimeStore else { throw WALIAgentRuntimeError.storageUnavailable }
        let durable = try await runtimeStore.snapshot()
        guard let display = snapshot.displays.first(where: { $0.isOnline && $0.isMain }),
              let itemID = display.assignedItemID,
              let item = snapshot.items.first(where: { $0.id == itemID }),
              let record = durable.library.first(where: {
                  UUID(uuidString: $0.item.id.rawValue) == itemID
              }),
              let releaseID = UUID(uuidString: record.release.id.rawValue),
              let master = record.artifacts.first(where: { $0.role == .masterVideo }),
              let posterURL = record.posterURL,
              record.release.artifacts.first(where: {
                  $0.contentID == master.digest
              })?.characteristics.bitDepth == 10 else {
            throw LockScreenHelperConnectionError.sourceRejected
        }
        return LockScreenHelperReleaseIntent(
            releaseID: releaseID,
            assetID: itemID,
            title: item.name,
            masterSHA256: master.digest.value,
            posterURL: posterURL
        )
    }

    private func lockScreenAssignments(
        from snapshot: EngineSnapshot
    ) async throws -> [LockScreenWallpaperAssignment] {
        guard let runtimeStore else { throw WALIAgentRuntimeError.storageUnavailable }
        return Self.lockScreenAssignments(
            from: snapshot,
            durable: try await runtimeStore.snapshot()
        )
    }

    nonisolated static func lockScreenAssignments(
        from snapshot: EngineSnapshot,
        durable: RuntimeSnapshot
    ) -> [LockScreenWallpaperAssignment] {
        let items = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let records = Dictionary(uniqueKeysWithValues: durable.library.compactMap { record in
            UUID(uuidString: record.item.id.rawValue).map { ($0, record) }
        })
        return snapshot.displays.compactMap { display in
            guard display.isOnline,
                  let itemID = display.assignedItemID,
                  let item = items[itemID],
                  case let .video(masterURL, _, _) = item.mediaContent else { return nil }
            let record = records[itemID]
            let masterArtifact = record?.artifacts.first(where: { $0.role == .masterVideo })
            let posterArtifact = record?.artifacts.first(where: { $0.role == .posterImage })
            let masterBitDepth = record.flatMap { record -> UInt16? in
                guard let masterID = masterArtifact?.digest else { return nil }
                return record.release.artifacts.first(where: {
                    $0.contentID == masterID
                })?.characteristics.bitDepth
            }
            return LockScreenWallpaperAssignment(
                displayID: display.id,
                isMain: display.isMain,
                itemID: itemID,
                name: item.name,
                masterBitDepth: masterBitDepth,
                masterArtifactSHA256: masterArtifact?.digest.value,
                posterArtifactSHA256: posterArtifact?.digest.value,
                masterURL: masterURL,
                posterURL: item.posterURL
            )
        }
    }

    private static func lockScreenNotice(for error: Error) -> AgentRuntimeNotice {
        AgentRuntimeNotice(
            kind: .warning,
            title: "Lock Screen Continuity Unavailable",
            message: "Lock Screen continuity could not update. \(error.localizedDescription)"
        )
    }

    #endif
    private func stopResourceObservation() {
        rendererSynchronization.stop()
        renderer.onSnapshotChange = nil
        for token in resourceObservationTokens { NotificationCenter.default.removeObserver(token) }
        resourceObservationTokens.removeAll()
    }

    private func refreshRendererObservation() async {
        await rendererSynchronization.flush()
    }

    private func synchronizeRenderer() async {
        guard let router, !Task.isCancelled else { return }
        let snapshot = renderer.snapshot
        do {
            let state = await router.snapshot()
            try Task.checkCancellation()
            let displays = snapshot.displays.map { display in
                EngineDisplay(
                    id: display.id.rawValue,
                    aliases: display.aliases.map(\.rawValue).sorted(),
                    name: display.name,
                    pixelWidth: Int((display.frame.width * display.backingScaleFactor).rounded()),
                    pixelHeight: Int((display.frame.height * display.backingScaleFactor).rounded()),
                    isMain: display.isMain,
                    isBuiltIn: display.isBuiltIn,
                    frameX: Double(display.frame.origin.x),
                    frameY: Double(display.frame.origin.y),
                    frameWidth: Double(display.frame.width),
                    frameHeight: Double(display.frame.height),
                    assignedItemID: nil,
                    isOnline: true
                )
            }
            guard snapshot.displays == renderer.snapshot.displays else { return }
            let currentOnline = state.displays.filter(\.isOnline).map {
                (
                    $0.id, $0.aliases, $0.name, $0.pixelWidth, $0.pixelHeight,
                    $0.isMain, $0.isBuiltIn, $0.frameX, $0.frameY, $0.frameWidth,
                    $0.frameHeight
                )
            }
            let observed = displays.map {
                (
                    $0.id, $0.aliases, $0.name, $0.pixelWidth, $0.pixelHeight,
                    $0.isMain, $0.isBuiltIn, $0.frameX, $0.frameY, $0.frameWidth,
                    $0.frameHeight
                )
            }
            if !currentOnline.elementsEqual(observed, by: { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 && lhs.3 == rhs.3
                    && lhs.4 == rhs.4 && lhs.5 == rhs.5 && lhs.6 == rhs.6
                    && lhs.7 == rhs.7 && lhs.8 == rhs.8 && lhs.9 == rhs.9
                    && lhs.10 == rhs.10
            }) {
                _ = try await router.performInternal(.replaceDisplays(displays))
            }

            try Task.checkCancellation()
            let process = ProcessInfo.processInfo
            let observation = Self.resourceObservation(from: renderer.snapshot,
                isLowPowerModeEnabled: process.isLowPowerModeEnabled, thermalState: process.thermalState)
            _ = try await router.recordRendererObservation(observation)
            try Task.checkCancellation()
            await publishSnapshot()
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    static func resourceObservation(from snapshot: WallpaperRendererSnapshot,
                                    isLowPowerModeEnabled: Bool,
                                    thermalState: ProcessInfo.ThermalState) -> RendererResourceObservation {
        let thermalLabel: String
        switch thermalState {
        case .nominal: thermalLabel = "nominal"
        case .fair: thermalLabel = "fair"
        case .serious: thermalLabel = "serious"
        case .critical: thermalLabel = "critical"
        @unknown default: thermalLabel = "unknown"
        }
        return RendererResourceObservation(playbackStatus: playbackStatus(from: snapshot),
            activePlayers: snapshot.sessions.count { $0.status == .playing },
            isLowPowerModeEnabled: isLowPowerModeEnabled, thermalState: thermalLabel)
    }

    static func playbackStatus(from snapshot: WallpaperRendererSnapshot) -> EnginePlaybackStatus {
        if !snapshot.sessions.isEmpty && snapshot.sessions.allSatisfy({ $0.status == .displaying }) {
            return .displaying
        }
        if snapshot.isUserPaused { return .paused }
        if let failure = snapshot.sessions.lazy.compactMap({ session -> String? in
            if case let .failed(message) = session.status { return message }
            return nil
        }).first {
            return .failed(failure)
        }
        let hasPlayingSession = snapshot.sessions.contains { $0.status == .playing }
        // A covered display must not label another display's motion as suspended.
        if !hasPlayingSession, snapshot.sessions.contains(where: { session in
            if case let .paused(reasons) = session.status { return !reasons.isEmpty }
            return false
        }) {
            return .suspended
        }
        if snapshot.sessions.contains(where: { if case .preparing = $0.status { true } else { false } }) {
            return .preparing
        }
        if hasPlayingSession { return .playing }
        if snapshot.sessions.contains(where: { $0.status == .displaying }) { return .displaying }
        return .idle
    }

    private func scheduleTrashPurge(_ itemID: UUID) {
        purgeTasks[itemID]?.cancel()
        purgeTasks[itemID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let router = self.router else { return }
            while !Task.isCancelled {
                do {
                    _ = try await router.performInternal([
                        .purgeTrashed(itemID: itemID),
                        .finalizeTrashPurge(itemID: itemID),
                    ])
                    self.purgeTasks.removeValue(forKey: itemID)
                    await self.publishSnapshot()
                    return
                } catch {
                    self.present(error)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private func publishSnapshot() async {
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        guard let router else { return }
        let response = await router.handle(AgentRequest(command: .snapshot))
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        if case let .snapshot(snapshot) = response.result {
            model.snapshot = snapshot.agentPresentation
        }
    }

    private func takeDiagnosticsSample() -> ProcessResourceSample {
        diagnostics.sampleNow()
    }

    private func applyDiagnosticsSample(_ sample: ProcessResourceSample) {
        model.snapshot.renderer.cpuPercent = sample.cpuPercent
        model.snapshot.renderer.physicalMemoryBytes = Int64(clamping: sample.physicalMemoryBytes)
    }

    private func present(_ error: Error) {
        #if WALI_APP_STORE
        guard !isShuttingDown else { return }
        #endif
        model.snapshot.notice = .init(
            kind: .error,
            title: "WALI Needs Attention",
            message: error.localizedDescription
        )
    }
}

private extension AgentResponse {
    func replacingResourceUsage(with sample: ProcessResourceSample) -> AgentResponse {
        guard case let .snapshot(snapshot) = result else { return self }
        let current = snapshot.resourceUsage
        let resourceUsage = AgentResourceUsage(
            activePlayers: current.activePlayers,
            cpuPercent: sample.cpuPercent,
            residentMemoryBytes: sample.physicalMemoryBytes,
            isLowPowerModeEnabled: current.isLowPowerModeEnabled,
            thermalState: current.thermalState,
            storageUsedBytes: current.storageUsedBytes,
            storageLimitBytes: current.storageLimitBytes
        )
        let replacement = AgentSnapshot(
            revision: snapshot.revision,
            connection: snapshot.connection,
            playback: snapshot.playback,
            items: snapshot.items,
            displays: snapshot.displays,
            imports: snapshot.imports,
            preferences: snapshot.preferences,
            resourceUsage: resourceUsage,
            notice: snapshot.notice
        )
        return AgentResponse(
            protocolVersion: protocolVersion,
            requestID: requestID,
            result: .snapshot(replacement)
        )
    }
}

private struct ImportProgressUpdate {
    let phase: EngineImportJob.Phase
    let progress: Double
    let timestamp: Date
}

extension AgentSnapshot {
    var agentPresentation: WALIUISnapshot {
        let activeIDs = Set(displays.compactMap(\.assignedItemID))
        let activeItem = items.first { activeIDs.contains($0.id) }
        let state: WALIRendererState = switch playback {
        case .idle: .stopped
        case .preparing: .converting(progress: nil)
        case .playing: .playing
        case .displaying: .displaying
        case .paused: .userPaused
        case .suspended: .automaticallyPaused(reason: WALIRendererState.automaticPauseReason(
            isLowPowerModeEnabled: resourceUsage.isLowPowerModeEnabled,
            pausesForLowPowerMode: preferences.lowPowerBehavior == .pause,
            thermalState: resourceUsage.thermalState))
        case .failed: .error(message: "Playback failed")
        }
        return WALIUISnapshot(
            renderer: .init(
                state: state,
                wallpaperTitle: activeItem?.name,
                thumbnailURL: activeItem?.posterURL,
                displayCount: displays.count { $0.isOnline && $0.assignedItemID != nil },
                cpuPercent: resourceUsage.residentMemoryBytes > 0 ? resourceUsage.cpuPercent : nil,
                physicalMemoryBytes: resourceUsage.residentMemoryBytes > 0
                    ? Int64(clamping: resourceUsage.residentMemoryBytes)
                    : nil
            ),
            preferences: .init(
                launchAtLogin: preferences.launchAtLogin,
                startPaused: preferences.startPaused,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause,
                contentFit: .init(rawValue: preferences.scaling.rawValue) ?? .fill,
                lockScreenContinuityEnabled: preferences.lockScreenContinuityEnabled
            ),
            storage: .init(
                usedBytes: Int64(clamping: resourceUsage.storageUsedBytes),
                limitBytes: resourceUsage.storageLimitBytes.map(Int64.init(clamping:))
            ),
            notice: notice?.agentPresentation
        )
    }
}

private extension AgentRuntimeNotice {
    var agentPresentation: WALINoticePresentation {
        let presentationKind: WALINoticeKind = switch kind {
        case .information: .information
        case .warning: .warning
        case .error: .error
        }
        return .init(id: id, kind: presentationKind, title: title, message: message)
    }
}

/// Transient agent-local observation; never encoded or sent across IPC.
struct RendererResourceObservation: Sendable, Equatable {
    let playbackStatus: EnginePlaybackStatus
    let activePlayers: Int
    let isLowPowerModeEnabled: Bool
    let thermalState: String
}

/// One event-driven drain; a change during an await requests a fresh pass.
@MainActor
final class RendererObservationSynchronizer {
    private let synchronize: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var pending = false
    private var isActive = false
    private var generation: UInt64 = 0

    init(synchronize: @escaping @MainActor () async -> Void) {
        self.synchronize = synchronize
    }

    func start() { isActive = true }

    func request() {
        guard isActive else { return }
        pending = true
        guard task == nil else { return }
        let admittedGeneration = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == admittedGeneration { task = nil }
            }
            while isActive, generation == admittedGeneration, pending, !Task.isCancelled {
                pending = false
                await synchronize()
            }
        }
    }

    func flush() async {
        request()
        await task?.value
    }

    func stop() {
        isActive = false
        pending = false
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
