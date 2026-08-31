import AppKit
import Foundation
import WALIEngine
import WALIModel
import WALIUI
import WALIWire

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
    public let model = WALIAppModel()

    private let renderer = WallpaperRenderer()
    private let diagnostics = ProcessDiagnostics()
    private let stateStore: EngineSnapshotStore?
    private let runtimeStore: RuntimeStore?
    private let transcoder = TranscoderConnection()
    private var router: AgentCommandRouter?
    private var serviceHost: AgentServiceHost?
    private var startupTask: Task<Void, Never>?
    private var purgeTasks: [UUID: Task<Void, Never>] = [:]
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var importContexts: [UUID: LocalImportContext] = [:]
    private var importProgressUpdates: [UUID: ImportProgressUpdate] = [:]

    public init() {
        stateStore = try? EngineSnapshotStore()
        runtimeStore = try? RuntimeStore(paths: LibraryPaths.applicationSupport())
    }

    public func start() {
        guard startupTask == nil else { return }
        renderer.onSnapshotChange = { [weak self] snapshot in
            self?.rendererDidChange(snapshot)
        }
        renderer.start()
        startupTask = Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    public func shutdown() {
        startupTask?.cancel()
        startupTask = nil
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

        var durableSnapshot: RuntimeSnapshot?
        if let runtimeStore {
            do {
                _ = try await runtimeStore.open()
                durableSnapshot = try await runtimeStore.snapshot()
                if let durableSnapshot {
                    restored = Self.reconcile(restored, with: durableSnapshot)
                }
            } catch {
                present(error)
            }
        }

        let router = AgentCommandRouter(restoring: restored) { [weak self] effect, snapshot in
            guard let self else { return }
            try await self.execute(effect, snapshot: snapshot)
        }
        self.router = router

        let host = AgentServiceHost { [weak self] request in
            let response = await router.handle(request)
            guard case .diagnosticsSnapshot = request.command,
                  let sample = await self?.takeDiagnosticsSample() else {
                return response
            }
            return response.replacingResourceUsage(with: sample)
        }
        serviceHost = host
        host.start()

        renderDesiredState(restored)
        renderer.setUserPaused(restored.isPausedByUser || restored.preferences.startPaused)
        for item in restored.trashedItems {
            scheduleTrashPurge(item.id)
        }
        await synchronizeRenderer(renderer.snapshot)
        await publishSnapshot()
        if let durableSnapshot {
            await resumeImports(from: durableSnapshot)
        }
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
                scaling: .init(rawValue: preferences.contentFit.rawValue) ?? .fill,
                quality: .init(rawValue: preferences.quality.rawValue) ?? .automatic,
                lowPowerBehavior: .init(rawValue: preferences.lowPowerBehavior.rawValue) ?? .pause
            ))
        case .openMainApplication:
            return .openForegroundApp
        case .openSettings:
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.wali.openSettings"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
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
                    lowPowerResponse: lowPowerResponse
                )
                if try await runtimeStore.snapshot().preferences != preferences {
                    try await runtimeStore.updatePreferences(preferences)
                }
            }
        case .render, .stopRendering, .reconcileRendering:
            renderDesiredState(authoritative)
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
    }

    private func startImport(
        jobID: UUID,
        bookmark: Data,
        snapshot: EngineSnapshot
    ) {
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
            let sourceURL = try Self.resolveBookmark(bookmark)
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
        let hasSecurityScope = context.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { context.sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
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
            guard let sourceBookmark else {
                throw WALIAgentRuntimeError.invalidImportState
            }
            let output = try await transcoder.transcode(
                TranscoderRequest(
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
        let current = await router.snapshot()
        guard current.resourceUsage.storageUsedBytes != used else { return }
        var resourceUsage = current.resourceUsage
        resourceUsage.storageUsedBytes = used
        _ = try? await router.performInternal(.setResourceUsage(resourceUsage))
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
                contentFit: PresentationContentFit(
                    rawValue: (display.scaling ?? snapshot.preferences.scaling).rawValue
                ) ?? .fill,
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
        if let failure = snapshot.sessions.lazy.compactMap({ session -> String? in
            if case let .failed(message) = session.status { return message }
            return nil
        }).first {
            return .failed(failure)
        }
        if snapshot.sessions.contains(where: { session in
            if case let .paused(reasons) = session.status { return !reasons.isEmpty }
            return false
        }) {
            return .suspended
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
        guard let router else { return }
        let response = await router.handle(AgentRequest(command: .snapshot))
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
            resourceUsage: resourceUsage
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
                contentFit: .init(rawValue: preferences.scaling.rawValue) ?? .fill
            ),
            storage: .init(
                usedBytes: Int64(clamping: resourceUsage.storageUsedBytes),
                limitBytes: resourceUsage.storageLimitBytes.map(Int64.init(clamping:))
            )
        )
    }
}
