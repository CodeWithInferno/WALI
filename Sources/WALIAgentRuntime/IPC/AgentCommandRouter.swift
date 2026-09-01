import AppKit
import Foundation
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

/// Maps the versioned wire protocol onto the transport-neutral engine.
public actor AgentCommandRouter {
    private let engine: RuntimeEngine
    private let effectHandler: EngineEffectHandler
    private let transactionGate = TransactionGate()
    private var runtimeNotice: AgentRuntimeNotice?

    public init(
        restoring snapshot: EngineSnapshot = .init(),
        effectHandler: @escaping EngineEffectHandler
    ) {
        engine = RuntimeEngine(restoring: snapshot)
        self.effectHandler = effectHandler
    }

    public func handle(_ request: AgentRequest) async -> AgentResponse {
        do {
            switch request.command {
            case .handshake, .snapshot, .diagnosticsSnapshot:
                return response(for: request, snapshot: await engine.snapshot())

            case let .importFiles(bookmarks):
                let inputs = try bookmarks.map { bookmark in
                    let url = try Self.resolveBookmark(bookmark)
                    return (id: UUID(), fileName: url.lastPathComponent, bookmark: bookmark)
                }
                return try await mutate(
                    request,
                    action: .beginImports(inputs)
                )

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
                return try await mutate(
                    request,
                    action: .setPreferences(preferences.engineValue)
                )

            case let .revealItem(itemID):
                let snapshot = await engine.snapshot()
                guard let item = snapshot.items.first(where: { $0.id == itemID }) else {
                    throw EngineError.itemNotFound(itemID)
                }
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([item.masterURL])
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
                await MainActor.run {
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("com.wali.quitAll"),
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                    NSApplication.shared.terminate(nil)
                }
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
    public func performInternal(
        _ action: EngineAction,
        idempotencyKey: UUID = UUID()
    ) async throws -> EngineSnapshot {
        await transactionGate.acquire()
        do {
            _ = try await effectHandler(.preflight(action), await engine.snapshot())
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
            var snapshot = await engine.snapshot()
            for action in actions {
                _ = try await effectHandler(.preflight(action), snapshot)
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

    public func snapshot() async -> EngineSnapshot {
        await engine.snapshot()
    }

    public func replaceRuntimeNotice(_ notice: AgentRuntimeNotice?) {
        runtimeNotice = notice
    }

    private func mutate(_ request: AgentRequest, action: EngineAction) async throws -> AgentResponse {
        await transactionGate.acquire()
        do {
            _ = try await effectHandler(.preflight(action), await engine.snapshot())
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
        let agentIdentifier = Bundle.main.bundleIdentifier ?? ""
        if agentIdentifier.contains(".debug.") { return "com.wali.debug.WALI" }
        if agentIdentifier.contains(".development.") { return "com.wali.development.WALI" }
        return "com.wali.WALI"
    }

    private static func failure(from error: Error) -> AgentFailure {
        switch error {
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
        case .paused: .paused
        case .suspended: .suspended
        case .failed: .failed
        }
    }
}

private extension EngineLibraryItem {
    var wireValue: AgentLibraryItem {
        .init(
            id: id,
            name: name,
            createdAt: createdAt,
            duration: duration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            masterURL: masterURL,
            previewURL: previewURL,
            posterURL: posterURL,
            contentDigest: contentDigest,
            byteCount: byteCount,
            isFavorite: isFavorite
        )
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
