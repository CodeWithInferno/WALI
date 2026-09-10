import AppKit
import Foundation
import OSLog
import Observation
import WALIModel
import WALICatalogRuntime
import WALIUI
import WALIWire

/// Live foreground adapter: lifecycle, XPC transport, snapshot mapping and UI intentions.
@MainActor
@Observable
public final class WALIAppCoordinator: WALIUIActionHandling {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALI",
        category: "AgentSnapshot"
    )

    #if WALI_APP_STORE
    public static let shared = WALIAppCoordinator()
    #endif
    public enum BackgroundState: Equatable {
        case needsConsent, starting, needsApproval, ready, failed(String)
    }
    public private(set) var backgroundState: BackgroundState = .starting
    public private(set) var quitWasAcknowledged = false
    private var isQuitting = false
    private var quitRequestInProgress = false
    private let quitAgent: @MainActor @Sendable () async throws -> Void
    public let model: WALIAppModel

    private let connection: any AgentGateway
    private let lifecycle: AgentLifecycleController
    private var pollingTask: Task<Void, Never>?
    private var visibleWindows: Set<UUID> = []
    private var presentationTask: Task<Void, Never>?
    private var presentationSubject: UUID?
    private var presentationRequestID: UUID?
    private var lifecycleReconnectTask: Task<Void, Never>?
    private var lifecycleReconnectFailed = false
    private let snapshotRequest: @MainActor @Sendable () async throws -> AgentSnapshot
    private let snapshotInterval: Duration
    private var lastSnapshot: AgentSnapshot?
    private var quitObserver: (any NSObjectProtocol)?
    private var settingsObserver: (any NSObjectProtocol)?
    private var pendingActions: [WALIUIAction] = []
    private var actionTask: Task<Void, Never>?

    public init(
        model: WALIAppModel = WALIAppModel(),
        connection: any AgentGateway = AgentConnection(),
        lifecycle: AgentLifecycleController = AgentLifecycleController(),
        quitAgent: (@MainActor @Sendable () async throws -> Void)? = nil,
        snapshotRequest: (@MainActor @Sendable () async throws -> AgentSnapshot)? = nil,
        snapshotInterval: Duration = .seconds(2)
    ) {
        self.model = model
        self.connection = connection
        self.lifecycle = lifecycle
        self.quitAgent = quitAgent ?? { _ = try await connection.send(.quit) }
        self.snapshotRequest = snapshotRequest ?? { try await connection.send(.snapshot) }
        self.snapshotInterval = snapshotInterval
        #if WALI_APP_STORE
        connection.onConnectionEnded = { [weak self] in self?.reconnectLifecycleConnection() }
        connection.onAgentWillTerminate = { [weak self] in
            guard let self else { return }
            isQuitting = true
            quitWasAcknowledged = true
            lifecycleReconnectTask?.cancel()
            lifecycleReconnectTask = nil
            // Keep this connection alive until the callback reply is queued.
            pollingTask?.cancel()
            pollingTask = nil
            actionTask?.cancel()
            actionTask = nil
            pendingActions.removeAll()
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        #endif
    }

    public func start() {
        #if WALI_APP_STORE
        guard !visibleWindows.isEmpty else { return }
        #endif
        guard pollingTask == nil, !isQuitting else { return }
        guard lifecycle.hasBackgroundPlaybackConsent else {
            backgroundState = .needsConsent
            return
        }
        backgroundState = .starting
        #if !WALI_APP_STORE
        if quitObserver == nil {
            quitObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.wali.quitAll"),
                object: Bundle.main.object(forInfoDictionaryKey: "WALIControlServiceName") as? String
                    ?? Bundle.main.bundleIdentifier,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        #endif
        if settingsObserver == nil {
            settingsObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.wali.openSettings"),
                object: Bundle.main.object(forInfoDictionaryKey: "WALIControlServiceName") as? String
                    ?? Bundle.main.bundleIdentifier,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    self?.model.settingsPresentationRequest &+= 1
                }
            }
        }
        pollingTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--repair-agent-registration") {
                    try await lifecycle.reinstallAgent()
                }
                try lifecycle.ensureRunning()
                backgroundState = .ready
            } catch {
                backgroundState = lifecycle.requiresApproval ? .needsApproval : .failed(error.localizedDescription)
                present(error: error, title: "Background Access Needed")
                #if WALI_APP_STORE
                pollingTask = nil
                return
                #endif
            }

            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: snapshotInterval)
            }
        }
    }

    #if WALI_APP_STORE
    private func reconnectLifecycleConnection() {
        guard lifecycle.hasBackgroundPlaybackConsent, !isQuitting, !quitWasAcknowledged,
              !lifecycleReconnectFailed, lifecycleReconnectTask == nil else { return }
        // Reconnect once for this interruption, including with no visible
        // window. A failed handshake waits for an explicit foreground refresh.
        lifecycleReconnectFailed = true
        lifecycleReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { lifecycleReconnectTask = nil }
            do {
                guard !Task.isCancelled, !isQuitting else { return }
                let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                _ = try await connection.send(.handshake(clientVersion: clientVersion))
                guard !Task.isCancelled, !isQuitting, !quitWasAcknowledged else { return }
                guard connection.isConnected else { throw AgentConnectionError.unavailable }
                lifecycleReconnectFailed = false
            } catch {
                guard !Task.isCancelled, !isQuitting else { return }
                present(error: error, title: "Background Connection Interrupted")
            }
        }
    }
    #endif

    public func windowDidAppear(_ identifier: UUID) {
        visibleWindows.insert(identifier)
        start()
    }

    public func windowDidDisappear(_ identifier: UUID) {
        visibleWindows.remove(identifier)
        #if WALI_APP_STORE
        guard visibleWindows.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        presentationSubject = nil
        presentationRequestID = nil
        #else
        stop()
        #endif
    }

    public func preparePresentation(for itemID: UUID) {
        #if WALI_APP_STORE
        guard !isQuitting, !visibleWindows.isEmpty,
              let wallpaper = model.snapshot.wallpapers.first(where: { $0.id == itemID }) else { return }
        if let preview = wallpaper.previewURL, let poster = wallpaper.thumbnailURL,
           FileManager.default.fileExists(atPath: preview.path),
           FileManager.default.fileExists(atPath: poster.path) { return }
        guard presentationSubject != itemID || presentationTask == nil else { return }
        presentationTask?.cancel()
        presentationSubject = itemID
        let requestID = UUID()
        presentationRequestID = requestID
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if presentationRequestID == requestID { presentationTask = nil }
            }
            do {
                let snapshot = try await sendWithSingleStaleRetry(.preparePresentation(itemIDs: [itemID]))
                guard !Task.isCancelled, !isQuitting, presentationRequestID == requestID,
                      presentationSubject == itemID,
                      model.snapshot.wallpapers.contains(where: { $0.id == itemID }),
                      snapshot.items.contains(where: { $0.id == itemID }),
                      lastSnapshot == nil || snapshot.revision.rawValue >= lastSnapshot!.revision.rawValue else { return }
                apply(snapshot)
                model.presentationRevisions[itemID, default: 0] &+= 1
            } catch {
                guard !Task.isCancelled, presentationRequestID == requestID, !isQuitting else { return }
                presentationSubject = nil
                present(error: error, title: "Preview Unavailable")
            }
        }
        #endif
    }

    #if WALI_APP_STORE
    public func prepareForQuit() async throws {
        guard !quitWasAcknowledged else { return }
        guard !quitRequestInProgress else { throw CancellationError() }
        quitRequestInProgress = true
        defer { quitRequestInProgress = false }
        isQuitting = true
        lifecycleReconnectTask?.cancel()
        lifecycleReconnectTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        actionTask?.cancel()
        actionTask = nil
        pendingActions.removeAll()
        do {
            if lifecycle.hasBackgroundPlaybackConsent {
                try await quitAgent()
            }
            quitWasAcknowledged = true
            stop()
        } catch {
            if quitWasAcknowledged { return }
            present(error: error, title: "WALI Could Not Finish Quitting")
            throw error
        }
    }
    #endif

    public func allowBackgroundPlayback() {
        lifecycle.allowBackgroundPlayback()
        start()
    }

    public func openBackgroundApprovalSettings() {
        lifecycle.openApprovalSettings()
    }

    /// Window closure does not call this in Store builds: the app keeps its
    /// authenticated lifecycle connection until an explicit Quit.
    public func stop() {
        lifecycleReconnectTask?.cancel()
        lifecycleReconnectTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        presentationSubject = nil
        presentationRequestID = nil
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
        #if WALI_APP_STORE
        if case .quit = action { NSApplication.shared.terminate(nil); return }
        guard backgroundState == .ready, !isQuitting else { return }
        #endif
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

    public func installCatalogRelease(
        _ prepared: PreparedCatalogInstall
    ) async throws {
        #if WALI_APP_STORE
        guard backgroundState == .ready, !isQuitting else { throw AgentLifecycleError.consentRequired }
        #endif
        let request = AgentCatalogInstallRequest(
            canonicalManifest: prepared.canonicalManifest,
            canonicalMetadata: prepared.canonicalMetadata,
            signatureBase64URL: prepared.signatureBase64URL,
            keyID: prepared.keyID,
            quarantineReference: prepared.quarantineReference
        )
        let snapshot = try await sendWithSingleStaleRetry(.installCatalogRelease(request))
        apply(snapshot, clearNotice: true)
    }

    public func updateCatalogSecurityState(
        _ security: CatalogSecuritySnapshot
    ) async throws {
        #if WALI_APP_STORE
        guard backgroundState == .ready, !isQuitting else { throw AgentLifecycleError.consentRequired }
        #endif
        if let transition = security.trustTransition {
            let snapshot = try await sendWithSingleStaleRetry(.updateCatalogTrustTransition(
                AgentCatalogTrustTransitionUpdate(
                    revision: transition.revision,
                    canonicalBody: transition.canonicalBody,
                    signatureBase64URL: transition.signatureBase64URL,
                    keyID: transition.keyID
                )
            ))
            apply(snapshot)
        }
        let revocations = security.revocations
        let snapshot = try await sendWithSingleStaleRetry(.updateCatalogRevocations(
            AgentCatalogRevocationUpdate(
                revision: revocations.revision,
                canonicalBody: revocations.canonicalBody,
                signatureBase64URL: revocations.signatureBase64URL,
                keyID: revocations.keyID
            )
        ))
        apply(snapshot)
    }

    private func perform(_ action: WALIUIAction) async {
        do {
            guard let command = try command(for: action) else { return }
            let previousPreferences = lastSnapshot?.preferences
            let snapshot = try await sendWithSingleStaleRetry(command)
            try Task.checkCancellation()
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
        case .snapshot, .diagnosticsSnapshot, .handshake, .openForegroundApp, .revealItem, .preparePresentation,
             .updateCatalogTrustTransition, .updateCatalogRevocations, .quit:
            nil
        default:
            lastSnapshot?.revision
        }
    }

    private func command(for action: WALIUIAction) throws -> AgentCommand? {
        switch action {
        case let .importVideos(urls):
            #if WALI_APP_STORE
            let bookmarks = try ForegroundImportBookmarks.make(for: urls)
            #else
            let bookmarks = try urls.map { url in
                try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            #endif
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
                muted: current.muted,
                lockScreenContinuityEnabled: preferences.lockScreenContinuityEnabled
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
            let snapshot = try await snapshotRequest()
            try Task.checkCancellation()
            lifecycleReconnectFailed = false
            apply(snapshot, clearNotice: true)
        } catch {
            guard !Task.isCancelled else { return }
            if lastSnapshot == nil {
                present(error: error, title: "Connecting to WALI")
            }
        }
    }

    private func apply(_ snapshot: AgentSnapshot, clearNotice: Bool = false) {
        #if WALI_APP_STORE
        guard !isQuitting, !Task.isCancelled else { return }
        #endif
        if _isDebugAssertConfiguration() {
            Self.logger.debug(
                "Applying agent snapshot revision \(snapshot.revision.rawValue, privacy: .public) with \(snapshot.items.count, privacy: .public) library items"
            )
        }
        guard lastSnapshot == nil || snapshot.revision.rawValue >= lastSnapshot!.revision.rawValue else {
            return
        }
        let previousRuntimeNotice = lastSnapshot?.notice
        lastSnapshot = snapshot
        let existing = Set(snapshot.items.map(\.id))
        model.presentationRevisions = model.presentationRevisions.filter { existing.contains($0.key) }
        let preservedNotice: WALINoticePresentation? = if clearNotice
            || snapshot.notice != nil
            || previousRuntimeNotice != nil {
            nil
        } else {
            model.snapshot.notice
        }
        model.snapshot = snapshot.presentationValue(
            preserving: preservedNotice
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
                    isMain: display.isMain,
                    assignedWallpaperID: display.assignedItemID,
                    frameX: display.frameX,
                    frameY: display.frameY,
                    frameWidth: display.frameWidth,
                    frameHeight: display.frameHeight,
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
                contentFit: .init(rawValue: preferences.scaling.rawValue) ?? .fill,
                lockScreenContinuityEnabled: preferences.lockScreenContinuityEnabled
            ),
            storage: WALIStoragePresentation(
                usedBytes: Int64(clamping: resourceUsage.storageUsedBytes),
                limitBytes: resourceUsage.storageLimitBytes.map(Int64.init(clamping:))
            ),
            notice: self.notice?.presentationValue ?? notice
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

private extension AgentRuntimeNotice {
    var presentationValue: WALINoticePresentation {
        let presentationKind: WALINoticeKind = switch kind {
        case .information: .information
        case .warning: .warning
        case .error: .error
        }
        return .init(id: id, kind: presentationKind, title: title, message: message)
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
