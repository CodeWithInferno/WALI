import AppKit
import Foundation
import WALICatalog
import WALIEngine
import WALIModel
import WALIWire

public enum EngineEffectOutcome: Sendable {
    case unchanged
    case replaceRuntimeNotice(AgentRuntimeNotice?)
}

public enum EnginePipelineStep: Sendable {
    case preflight(EngineAction)
    case effect(EngineEffect)
}

public typealias EngineEffectHandler = @Sendable (
    EnginePipelineStep,
    EngineSnapshot
) async throws -> EngineEffectOutcome

public typealias AgentPresentationHandler = @Sendable ([UUID], AgentSnapshot) async throws -> AgentSnapshot

public typealias AgentShutdownHandler = @Sendable () async throws -> Void

public typealias CatalogInstallHandler = @Sendable (
    AgentCatalogInstallRequest,
    UUID,
    EngineRevision
) async throws -> CatalogInstallResult

public typealias CatalogRevocationHandler = @Sendable (
    AgentCatalogRevocationUpdate
) async throws -> Void

public typealias CatalogTrustTransitionHandler = @Sendable (
    AgentCatalogTrustTransitionUpdate
) async throws -> Void

private actor TransactionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

#if WALI_APP_STORE
private final class ShutdownDrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
#endif

/// Maps the versioned wire protocol onto the transport-neutral engine.
public actor AgentCommandRouter {
    private let presentationHandler: AgentPresentationHandler?
    private let shutdownHandler: AgentShutdownHandler?
    private var shutdownTask: Task<Void, Error>?
    private var isShuttingDown = false
    private var activeCatalogTask: Task<CatalogInstallResult, Error>?
    private let engine: RuntimeEngine
    private let effectHandler: EngineEffectHandler
    private let catalogInstallHandler: CatalogInstallHandler?
    private let catalogRevocationHandler: CatalogRevocationHandler?
    private let catalogTrustTransitionHandler: CatalogTrustTransitionHandler?
    private let transactionGate = TransactionGate()
    private var completedCatalogRequests: [UUID: AgentCatalogInstallRequest] = [:]
    private var completedCatalogRequestOrder: [UUID] = []
    private let maximumRememberedCatalogRequests = 256
    private var runtimeNotice: AgentRuntimeNotice?

    public init(
        restoring snapshot: EngineSnapshot = .init(),
        catalogInstallHandler: CatalogInstallHandler? = nil,
        catalogRevocationHandler: CatalogRevocationHandler? = nil,
        catalogTrustTransitionHandler: CatalogTrustTransitionHandler? = nil,
        shutdownHandler: AgentShutdownHandler? = nil,
        presentationHandler: AgentPresentationHandler? = nil,
        effectHandler: @escaping EngineEffectHandler
    ) {
        var restored = snapshot
        #if WALI_APP_STORE
        restored.preferences.lockScreenContinuityEnabled = false
        #endif
        engine = RuntimeEngine(restoring: restored)
        self.shutdownHandler = shutdownHandler
        self.presentationHandler = presentationHandler
        self.effectHandler = effectHandler
        self.catalogInstallHandler = catalogInstallHandler
        self.catalogRevocationHandler = catalogRevocationHandler
        self.catalogTrustTransitionHandler = catalogTrustTransitionHandler
    }

    public func handle(_ request: AgentRequest) async -> AgentResponse {
        do {
            if isShuttingDown {
                switch request.command {
                case .quit, .snapshot, .handshake, .diagnosticsSnapshot: break
                default: throw CancellationError()
                }
            }
            switch request.command {
            case .handshake, .snapshot, .diagnosticsSnapshot:
                return response(for: request, snapshot: await engine.snapshot())

            case let .preparePresentation(itemIDs):
                let snapshot = await engine.snapshot()
                #if WALI_APP_STORE
                guard !itemIDs.isEmpty, itemIDs.count <= 32, Set(itemIDs).count == itemIDs.count,
                      Set(itemIDs).isSubset(of: Set(snapshot.items.map(\.id))) else {
                    throw AgentFailure(code: .invalidRequest, message: "The requested wallpaper is no longer available.")
                }
                guard let presentationHandler else { throw WALIAgentRuntimeError.storageUnavailable }
                let projected = try await presentationHandler(itemIDs, snapshot.wireValue(notice: runtimeNotice))
                guard !isShuttingDown else { throw CancellationError() }
                let latest = await engine.snapshot()
                guard latest.revision == snapshot.revision else {
                    throw EngineError.staleRevision(expected: snapshot.revision.rawValue, actual: latest.revision.rawValue)
                }
                return AgentResponse(requestID: request.requestID, result: .snapshot(projected))
                #else
                return response(for: request, snapshot: snapshot)
                #endif

            case let .importFiles(bookmarks):
                let inputs = try bookmarks.map { bookmark in
                    #if WALI_APP_STORE
                    let accepted = try AgentSourceAuthorization.acceptTransient(bookmark)
                    return (id: UUID(), fileName: accepted.url.lastPathComponent, bookmark: accepted.persistentBookmark)
                    #else
                    let url = try Self.resolveBookmark(bookmark)
                    return (id: UUID(), fileName: url.lastPathComponent, bookmark: bookmark)
                    #endif
                }
                return try await mutate(
                    request,
                    action: .beginImports(inputs)
                )

            case let .installCatalogRelease(install):
                guard let catalogInstallHandler else {
                    throw CatalogInstallError.invalidQuarantineReference
                }
                await transactionGate.acquire()
                do {
                    #if WALI_APP_STORE
                    guard !isShuttingDown else { throw CancellationError() }
                    #endif
                    if let prior = await engine.completedTransaction(
                        for: request.idempotencyKey
                    ) {
                        guard completedCatalogRequests[request.idempotencyKey] == install else {
                            throw CatalogTrustStoreError.requestMismatch
                        }
                        await transactionGate.release()
                        return response(for: request, snapshot: prior.snapshot)
                    }
                    let snapshot = await engine.snapshot()
                    if let expected = request.expectedRevision,
                       expected.rawValue != snapshot.revision.rawValue {
                        throw EngineError.staleRevision(
                            expected: expected.rawValue,
                            actual: snapshot.revision.rawValue
                        )
                    }
                    #if WALI_APP_STORE
                    let installTask = Task {
                        try await catalogInstallHandler(install, request.idempotencyKey, snapshot.revision)
                    }
                    activeCatalogTask = installTask
                    defer { activeCatalogTask = nil }
                    let installed = try await installTask.value
                    guard !isShuttingDown else { throw CancellationError() }
                    #else
                    let installed = try await catalogInstallHandler(install, request.idempotencyKey, snapshot.revision)
                    #endif
                    let transaction = try await engine.perform(
                        .installCatalogItem(installed.item, completedImport: installed.completedImport),
                        idempotencyKey: request.idempotencyKey,
                        expectedRevision: request.expectedRevision
                    )
                    try await execute(transaction)
                    rememberCatalogRequest(install, for: request.idempotencyKey)
                    await transactionGate.release()
                    return response(for: request, snapshot: transaction.snapshot)
                } catch {
                    await transactionGate.release()
                    throw error
                }

            case let .updateCatalogRevocations(update):
                guard let catalogRevocationHandler else {
                    throw CatalogTrustStoreError.invalidConfiguration
                }
                await transactionGate.acquire()
                do {
                    #if WALI_APP_STORE
                    guard !isShuttingDown else { throw CancellationError() }
                    #endif
                    try await catalogRevocationHandler(update)
                    let snapshot = await engine.snapshot()
                    await transactionGate.release()
                    return response(for: request, snapshot: snapshot)
                } catch {
                    await transactionGate.release()
                    throw error
                }

            case let .updateCatalogTrustTransition(update):
                guard let catalogTrustTransitionHandler else {
                    throw CatalogTrustStoreError.invalidConfiguration
                }
                await transactionGate.acquire()
                do {
                    #if WALI_APP_STORE
                    guard !isShuttingDown else { throw CancellationError() }
                    #endif
                    try await catalogTrustTransitionHandler(update)
                    let snapshot = await engine.snapshot()
                    await transactionGate.release()
                    return response(for: request, snapshot: snapshot)
                } catch {
                    await transactionGate.release()
                    throw error
                }

            case let .cancelImport(jobID):
                return try await mutate(request, action: .cancelImport(jobID))

            case let .apply(itemID, displayIDs, scaling):
                return try await mutate(
                    request,
                    action: .apply(
                        itemID: itemID,
                        displayIDs: displayIDs,
                        scaling: .init(rawValue: scaling.rawValue) ?? .fill
                    )
                )

            case let .setPlaybackPaused(isPaused):
                return try await mutate(request, action: .setPaused(isPaused))

            case .nextWallpaper:
                return try await mutate(request, action: .nextWallpaper)

            case .stopWallpaper:
                return try await mutate(request, action: .stopWallpaper)

            case let .renameItem(itemID, name):
                return try await mutate(request, action: .rename(itemID: itemID, name: name))

            case let .removeItem(itemID):
                return try await mutate(request, action: .remove(itemID: itemID))

            case let .restoreItem(itemID):
                return try await mutate(request, action: .restore(itemID: itemID))

            case let .setPreferences(preferences):
                #if WALI_APP_STORE
                guard !preferences.lockScreenContinuityEnabled else {
                    throw AgentFailure(code: .invalidRequest, message: "This setting is unavailable in this distribution.")
                }
                #endif
                return try await mutate(
                    request,
                    action: .setPreferences(preferences.engineValue)
                )

            case let .revealItem(itemID):
                let snapshot = await engine.snapshot()
                guard let item = snapshot.items.first(where: { $0.id == itemID }) else {
                    throw EngineError.itemNotFound(itemID)
                }
                let file: URL
                switch item.mediaContent {
                case let .video(masterURL, _, _): file = masterURL
                case let .still(imageURL): file = imageURL
                }
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                return response(for: request, snapshot: snapshot)

            case .openForegroundApp:
                await MainActor.run {
                    if let identifier = Self.foregroundBundleIdentifier,
                       let applicationURL = NSWorkspace.shared.urlForApplication(
                           withBundleIdentifier: identifier
                       ) {
                        NSWorkspace.shared.openApplication(
                            at: applicationURL,
                            configuration: .init()
                        ) { _, _ in }
                    }
                }
                return response(for: request, snapshot: await engine.snapshot())

            case .quit:
                #if WALI_APP_STORE
                isShuttingDown = true
                activeCatalogTask?.cancel()
                if shutdownTask == nil {
                    guard let shutdownHandler else {
                        throw AgentFailure(code: .internalFailure, message: "WALI could not stop its background service.")
                    }
                    shutdownTask = Task { try await shutdownHandler() }
                }
                do {
                    try await shutdownTask?.value
                } catch {
                    shutdownTask = nil
                    throw error
                }
                #else
                // The host completes termination only after this reply is queued.
                isShuttingDown = true
                #endif
                return response(for: request, snapshot: await engine.snapshot())
            }
        } catch {
            return AgentResponse(
                requestID: request.requestID,
                result: .failure(Self.failure(from: error))
            )
        }
    }

    @discardableResult
    func recordRendererObservation(_ observation: RendererResourceObservation) async throws -> EngineSnapshot {
        try await mergeResourceObservation(observation, storageUsedBytes: nil)
    }

    @discardableResult
    func recordStorageUsage(_ bytes: UInt64) async throws -> EngineSnapshot {
        try await mergeResourceObservation(nil, storageUsedBytes: bytes)
    }

    /// Both resource producers merge against current state while holding the same gate.
    private func mergeResourceObservation(_ observation: RendererResourceObservation?,
                                          storageUsedBytes: UInt64?) async throws -> EngineSnapshot {
        await transactionGate.acquire()
        do {
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            var snapshot = await engine.snapshot()
            var usage = snapshot.resourceUsage
            if let observation {
                usage.activePlayers = observation.activePlayers
                usage.isLowPowerModeEnabled = observation.isLowPowerModeEnabled
                usage.thermalState = observation.thermalState
            }
            if let storageUsedBytes { usage.storageUsedBytes = storageUsedBytes }
            var actions: [EngineAction] = []
            if usage != snapshot.resourceUsage { actions.append(.setResourceUsage(usage)) }
            if let observation, observation.playbackStatus != snapshot.playbackStatus {
                actions.append(.setPlaybackStatus(observation.playbackStatus))
            }
            for action in actions {
                try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                try validateDistribution(action)
                _ = try await effectHandler(.preflight(action), snapshot)
                try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                try validateDistribution(action)
                let transaction = try await engine.perform(action)
                try await execute(transaction)
                snapshot = transaction.snapshot
            }
            await transactionGate.release()
            return snapshot
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    @discardableResult
    public func performInternal(
        _ action: EngineAction,
        idempotencyKey: UUID = UUID()
    ) async throws -> EngineSnapshot {
        await transactionGate.acquire()
        do {
            #if WALI_APP_STORE
            guard !isShuttingDown else { throw CancellationError() }
            #endif
            try validateDistribution(action)
            _ = try await effectHandler(.preflight(action), await engine.snapshot())
            try validateDistribution(action)
            let transaction = try await engine.perform(action, idempotencyKey: idempotencyKey)
            try await execute(transaction)
            await transactionGate.release()
            return transaction.snapshot
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    /// Applies an internal multi-step transition without allowing a user
    /// command to interleave between its crash-consistent phases.
    @discardableResult
    public func performInternal(_ actions: [EngineAction]) async throws -> EngineSnapshot {
        await transactionGate.acquire()
        do {
            #if WALI_APP_STORE
            guard !isShuttingDown else { throw CancellationError() }
            #endif
            var snapshot = await engine.snapshot()
            for action in actions {
                try validateDistribution(action)
                _ = try await effectHandler(.preflight(action), snapshot)
                try validateDistribution(action)
                let transaction = try await engine.perform(action)
                try await execute(transaction)
                snapshot = transaction.snapshot
            }
            await transactionGate.release()
            return snapshot
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    #if WALI_APP_STORE
    /// Worker drain unblocks catalog tasks; wait for their current engine
    /// transaction before writing the final shutdown snapshot. A timeout leaves
    /// Quit incomplete, while the queued waiter still releases the gate safely.
    public func drainTransactionsForShutdown() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = ShutdownDrainResult(continuation)
            Task {
                await transactionGate.acquire()
                await transactionGate.release()
                result.finish(.success(()))
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                result.finish(.failure(AgentFailure(
                    code: .internalFailure, message: "WALI is still finishing a pending operation. Try Quit again."
                )))
            }
        }
    }
    #endif

    public func snapshot() async -> EngineSnapshot {
        await engine.snapshot()
    }

    public func replaceRuntimeNotice(_ notice: AgentRuntimeNotice?) {
        runtimeNotice = notice
    }

    private func rememberCatalogRequest(
        _ request: AgentCatalogInstallRequest,
        for idempotencyKey: UUID
    ) {
        guard completedCatalogRequests[idempotencyKey] == nil else { return }
        completedCatalogRequests[idempotencyKey] = request
        completedCatalogRequestOrder.append(idempotencyKey)
        if completedCatalogRequestOrder.count > maximumRememberedCatalogRequests {
            completedCatalogRequests.removeValue(forKey: completedCatalogRequestOrder.removeFirst())
        }
    }

    private func mutate(_ request: AgentRequest, action: EngineAction) async throws -> AgentResponse {
        await transactionGate.acquire()
        do {
            #if WALI_APP_STORE
            guard !isShuttingDown else { throw CancellationError() }
            #endif
            try validateDistribution(action)
            _ = try await effectHandler(.preflight(action), await engine.snapshot())
            try validateDistribution(action)
            let transaction = try await engine.perform(
                action,
                idempotencyKey: request.idempotencyKey,
                expectedRevision: request.expectedRevision
            )
            try await execute(transaction)
            await transactionGate.release()
            return response(for: request, snapshot: transaction.snapshot)
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    private func validateDistribution(_ action: EngineAction) throws {
        #if WALI_APP_STORE
        guard !isShuttingDown else { throw CancellationError() }
        if case let .setPreferences(preferences) = action, preferences.lockScreenContinuityEnabled {
            throw AgentFailure(code: .invalidRequest, message: "This setting is unavailable in this distribution.")
        }
        #endif
    }

    private func execute(_ transaction: EngineTransaction) async throws {
        for effect in transaction.effects {
            switch try await effectHandler(.effect(effect), transaction.snapshot) {
            case .unchanged:
                break
            case let .replaceRuntimeNotice(notice):
                runtimeNotice = notice
            }
        }
    }

    private func response(for request: AgentRequest, snapshot: EngineSnapshot) -> AgentResponse {
        AgentResponse(
            requestID: request.requestID,
            result: .snapshot(snapshot.wireValue(notice: runtimeNotice))
        )
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

    private static var foregroundBundleIdentifier: String? {
        #if WALI_APP_STORE
        return Bundle.main.object(forInfoDictionaryKey: "WALIExpectedClientBundleIdentifier") as? String
        #else
        return DirectAgentIdentity.foregroundIdentifier(for: Bundle.main.bundleIdentifier)
        #endif
    }

    private static func failure(from error: Error) -> AgentFailure {
        switch error {
        case let failure as AgentFailure:
            failure
        case let EngineError.staleRevision(expected, actual):
            AgentFailure(
                code: .staleRevision,
                message: "This view is out of date (expected \(expected), current \(actual)).",
                recoverySuggestion: "Refresh and try again."
            )
        case EngineError.itemNotFound:
            AgentFailure(code: .itemNotFound, message: "That wallpaper is no longer in the library.")
        case EngineError.displayNotFound:
            AgentFailure(code: .displayNotFound, message: "That display is no longer connected.")
        case EngineError.importNotFound:
            AgentFailure(code: .importFailed, message: "That import is no longer available.")
        case EngineError.invalidName:
            AgentFailure(code: .invalidRequest, message: "Choose a name between 1 and 120 characters.")
        case WireCodecError.incompatibleProtocol:
            AgentFailure(
                code: .incompatibleProtocol,
                message: "The WALI app and agent versions do not match.",
                recoverySuggestion: "Quit WALI completely, then reopen it."
            )
        case CatalogValidationError.revokedRelease:
            AgentFailure(
                code: .catalogReleaseRevoked,
                message: "This catalog release was revoked for a critical security reason."
            )
        case is CatalogValidationError:
            AgentFailure(
                code: .catalogTrustFailed,
                message: "The signed catalog release could not be verified."
            )
        case is CatalogTrustStoreError:
            AgentFailure(
                code: .catalogTrustFailed,
                message: "The signed catalog release could not be verified."
            )
        default:
            AgentFailure(code: .internalFailure, message: error.localizedDescription)
        }
    }
}

private extension EngineSnapshot {
    func wireValue(notice: AgentRuntimeNotice?) -> AgentSnapshot {
        AgentSnapshot(
            revision: revision,
            playback: playbackStatus.wireValue,
            items: items.map(\.wireValue),
            displays: displays.map(\.wireValue),
            imports: imports.map(\.wireValue),
            preferences: preferences.wireValue,
            resourceUsage: resourceUsage.wireValue,
            notice: notice
        )
    }
}

private extension EnginePlaybackStatus {
    var wireValue: AgentPlaybackState {
        switch self {
        case .idle: .idle
        case .preparing: .preparing
        case .playing: .playing
        case .displaying: .displaying
        case .paused: .paused
        case .suspended: .suspended
        case .failed: .failed
        }
    }
}

private extension EngineLibraryItem {
    var wireValue: AgentLibraryItem {
        let content: AgentWallpaperMediaContent = switch mediaContent {
        case let .video(masterURL, previewURL, duration): .video(masterURL: masterURL, previewURL: previewURL, duration: duration)
        case let .still(imageURL): .still(imageURL: imageURL)
        }
        return .init(id: id, name: name, createdAt: createdAt, mediaContent: content,
              pixelWidth: pixelWidth, pixelHeight: pixelHeight, posterURL: posterURL,
              contentDigest: contentDigest, byteCount: byteCount, isFavorite: isFavorite)
    }
}

private extension EngineDisplay {
    var wireValue: AgentDisplay {
        .init(
            id: id,
            aliases: aliases,
            name: name,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isMain: isMain,
            isBuiltIn: isBuiltIn,
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            assignedItemID: assignedItemID,
            scaling: scaling.flatMap { .init(rawValue: $0.rawValue) },
            isOnline: isOnline
        )
    }
}

private extension EngineImportJob {
    var wireValue: AgentImportJob {
        .init(
            id: id,
            fileName: fileName,
            phase: .init(rawValue: phase.rawValue) ?? .failed,
            progress: progress,
            detail: detail,
            createdAt: createdAt
        )
    }
}

private extension EnginePreferences {
    var wireValue: AgentPreferences {
        .init(
            launchAtLogin: launchAtLogin,
            startPaused: startPaused,
            pauseOnBattery: pauseOnBattery,
            pauseWhenOccluded: pauseWhenOccluded,
            scaling: .init(rawValue: scaling.rawValue) ?? .fill,
            quality: .init(rawValue: quality.rawValue) ?? .automatic,
            lowPowerBehavior: .init(rawValue: lowPowerBehavior.rawValue) ?? .pause,
            muted: muted,
            lockScreenContinuityEnabled: lockScreenContinuityEnabled
        )
    }
}

private extension AgentPreferences {
    var engineValue: EnginePreferences {
        .init(
            launchAtLogin: launchAtLogin,
            startPaused: startPaused,
            pauseOnBattery: pauseOnBattery,
            pauseWhenOccluded: pauseWhenOccluded,
            scaling: .init(rawValue: scaling.rawValue) ?? .fill,
            quality: .init(rawValue: quality.rawValue) ?? .automatic,
            lowPowerBehavior: .init(rawValue: lowPowerBehavior.rawValue) ?? .pause,
            muted: muted,
            lockScreenContinuityEnabled: lockScreenContinuityEnabled
        )
    }
}

private extension EngineResourceUsage {
    var wireValue: AgentResourceUsage {
        .init(
            activePlayers: activePlayers,
            cpuPercent: cpuPercent,
            residentMemoryBytes: residentMemoryBytes,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalState: thermalState,
            storageUsedBytes: storageUsedBytes,
            storageLimitBytes: storageLimitBytes
        )
    }
}
