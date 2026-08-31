import AppKit
import AVFoundation
import Foundation
import WALIModel

/// One immutable display-to-video request accepted by ``WallpaperRenderer``.
public struct WallpaperRenderingAssignment: Sendable, Hashable {
    public let displayID: WallpaperDisplayIdentifier
    public let videoURL: URL
    public let efficientVideoURL: URL?
    public let posterURL: URL?
    public let contentFit: PresentationContentFit
    public let lowPowerResponse: PresentationLowPowerResponse

    public init(
        displayID: WallpaperDisplayIdentifier,
        videoURL: URL,
        efficientVideoURL: URL? = nil,
        posterURL: URL? = nil,
        contentFit: PresentationContentFit = .fill,
        lowPowerResponse: PresentationLowPowerResponse = .pause
    ) {
        self.displayID = displayID
        self.videoURL = videoURL
        self.efficientVideoURL = efficientVideoURL
        self.posterURL = posterURL
        self.contentFit = contentFit
        self.lowPowerResponse = lowPowerResponse
    }
}

public enum WallpaperSessionStatus: Sendable, Equatable {
    case preparing
    case playing
    case paused(Set<WallpaperAutomaticPauseReason>)
    case failed(String)
}

public struct WallpaperSessionSnapshot: Sendable, Equatable, Identifiable {
    public let id: WallpaperDisplayIdentifier
    public let status: WallpaperSessionStatus

    public init(id: WallpaperDisplayIdentifier, status: WallpaperSessionStatus) {
        self.id = id
        self.status = status
    }
}

public struct WallpaperRendererSnapshot: Sendable, Equatable {
    public let displays: [WallpaperDisplay]
    public let sessions: [WallpaperSessionSnapshot]
    public let isUserPaused: Bool
    public let automaticPauseReasons: Set<WallpaperAutomaticPauseReason>

    public init(
        displays: [WallpaperDisplay],
        sessions: [WallpaperSessionSnapshot],
        isUserPaused: Bool,
        automaticPauseReasons: Set<WallpaperAutomaticPauseReason>
    ) {
        self.displays = displays
        self.sessions = sessions
        self.isUserPaused = isUserPaused
        self.automaticPauseReasons = automaticPauseReasons
    }
}

/// Main-actor facade for display reconciliation, wallpaper windows and playback.
@MainActor
public final class WallpaperRenderer {
    public typealias SnapshotHandler = @MainActor (WallpaperRendererSnapshot) -> Void

    public var onSnapshotChange: SnapshotHandler?
    public private(set) var snapshot = WallpaperRendererSnapshot(
        displays: [],
        sessions: [],
        isUserPaused: false,
        automaticPauseReasons: []
    )

    private let displayMonitor: WallpaperDisplayMonitor
    private let systemEvents: SystemEventSource
    private var assignments: [WallpaperRenderingAssignment] = []
    private var sessions: [WallpaperDisplayIdentifier: WallpaperSession] = [:]
    private var isUserPaused = false
    private var automaticPauseReasons: Set<WallpaperAutomaticPauseReason> = []
    private var isRunning = false

    public init(
        displayMonitor: WallpaperDisplayMonitor = WallpaperDisplayMonitor(),
        systemEvents: SystemEventSource = SystemEventSource()
    ) {
        self.displayMonitor = displayMonitor
        self.systemEvents = systemEvents
    }

    /// Starts system observation. This operation is idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        displayMonitor.onChange = { [weak self] _ in
            self?.reconcile()
        }
        systemEvents.onChange = { [weak self] reasons in
            guard let self else { return }
            self.automaticPauseReasons = reasons
            self.reconcile()
        }
        displayMonitor.start()
        systemEvents.start()
        reconcile()
    }

    /// Replaces the complete desired assignment set and reconciles immediately.
    public func setAssignments(_ assignments: [WallpaperRenderingAssignment]) {
        self.assignments = assignments
        reconcile()
    }

    public func setUserPaused(_ paused: Bool) {
        guard paused != isUserPaused else { return }
        isUserPaused = paused
        updatePauseState()
    }

    /// Stops rendering while leaving topology and system observation active.
    public func stopWallpaper() {
        assignments.removeAll(keepingCapacity: false)
        removeAllSessions()
        publishSnapshot()
    }

    /// Releases every observer, player and wallpaper window. Safe to call repeatedly.
    public func shutdown() {
        if isRunning {
            displayMonitor.onChange = nil
            systemEvents.onChange = nil
            displayMonitor.stop()
            systemEvents.stop()
        }
        isRunning = false
        automaticPauseReasons.removeAll(keepingCapacity: false)
        removeAllSessions()
        publishSnapshot()
    }

    private func reconcile() {
        let observations: [(WallpaperRenderingAssignment, WallpaperDisplay, NSScreen)] =
            assignments.compactMap { assignment in
                guard
                    let display = displayMonitor.displays.first(where: {
                        $0.matches(assignment.displayID)
                    }),
                    let screen = displayMonitor.screen(for: display)
                else {
                    return nil
                }
                return (assignment, display, screen)
            }

        let desiredDisplayIDs = Set(observations.map { $0.1.id })
        let staleIDs = sessions.keys.filter { !desiredDisplayIDs.contains($0) }
        for staleID in staleIDs {
            sessions.removeValue(forKey: staleID)?.tearDown()
        }

        for (requestedAssignment, display, screen) in observations {
            let assignment = effectiveAssignment(requestedAssignment)
            if let session = sessions[display.id] {
                session.update(
                    assignment: assignment,
                    screen: screen,
                    globalPauseReasons: effectiveReasons(for: assignment),
                    userPaused: isUserPaused
                )
            } else {
                let session = WallpaperSession(
                    display: display,
                    assignment: assignment,
                    screen: screen
                )
                session.onChange = { [weak self] in
                    self?.publishSnapshot()
                }
                sessions[display.id] = session
                session.start(
                    globalPauseReasons: effectiveReasons(for: assignment),
                    userPaused: isUserPaused
                )
            }
        }

        publishSnapshot()
    }

    private func updatePauseState() {
        for session in sessions.values {
            session.setPaused(
                globalReasons: effectiveReasons(for: session.assignment),
                userPaused: isUserPaused
            )
        }
        publishSnapshot()
    }

    private func effectiveReasons(
        for assignment: WallpaperRenderingAssignment
    ) -> Set<WallpaperAutomaticPauseReason> {
        var reasons = automaticPauseReasons
        if assignment.lowPowerResponse != .pause {
            reasons.remove(.lowPower)
        }
        return reasons
    }

    private func effectiveAssignment(
        _ assignment: WallpaperRenderingAssignment
    ) -> WallpaperRenderingAssignment {
        guard automaticPauseReasons.contains(.lowPower),
              assignment.lowPowerResponse == .reduceQuality,
              let efficientVideoURL = assignment.efficientVideoURL else {
            return assignment
        }
        return WallpaperRenderingAssignment(
            displayID: assignment.displayID,
            videoURL: efficientVideoURL,
            efficientVideoURL: efficientVideoURL,
            posterURL: assignment.posterURL,
            contentFit: assignment.contentFit,
            lowPowerResponse: assignment.lowPowerResponse
        )
    }

    private func removeAllSessions() {
        let oldSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        for session in oldSessions {
            session.tearDown()
        }
    }

    private func publishSnapshot() {
        let next = WallpaperRendererSnapshot(
            displays: displayMonitor.displays,
            sessions: sessions.values
                .map(\.snapshot)
                .sorted { $0.id.rawValue < $1.id.rawValue },
            isUserPaused: isUserPaused,
            automaticPauseReasons: automaticPauseReasons
        )
        guard next != snapshot else { return }
        snapshot = next
        onSnapshotChange?(next)
    }
}

@MainActor
private final class WallpaperSession {
    let display: WallpaperDisplay
    var assignment: WallpaperRenderingAssignment
    var onChange: (@MainActor () -> Void)?
    private(set) var snapshot: WallpaperSessionSnapshot

    private let window: WallpaperWindow
    private let playback: LoopingVideoPlayback
    private var currentScreen: NSScreen
    private var preparationTask: Task<Void, Never>?
    private var globalPauseReasons: Set<WallpaperAutomaticPauseReason> = []
    private var isUserPaused = false
    private var isOccluded = false
    private var loadedAssignment: WallpaperRenderingAssignment?
    private var isTornDown = false

    init(
        display: WallpaperDisplay,
        assignment: WallpaperRenderingAssignment,
        screen: NSScreen
    ) {
        self.display = display
        self.assignment = assignment
        snapshot = WallpaperSessionSnapshot(id: display.id, status: .preparing)
        currentScreen = screen
        window = WallpaperWindow(screen: screen)
        playback = LoopingVideoPlayback(canvas: window.canvas)

        window.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.isOccluded = !visible
            self.applyPauseState()
        }
        playback.onStateChange = { [weak self] state in
            self?.playbackStateChanged(state)
        }
    }

    func start(
        globalPauseReasons: Set<WallpaperAutomaticPauseReason>,
        userPaused: Bool
    ) {
        self.globalPauseReasons = globalPauseReasons
        isUserPaused = userPaused
        window.show(on: currentScreen)
        loadAssignmentIfNeeded()
        applyPauseState()
    }

    func update(
        assignment: WallpaperRenderingAssignment,
        screen: NSScreen,
        globalPauseReasons: Set<WallpaperAutomaticPauseReason>,
        userPaused: Bool
    ) {
        guard !isTornDown else { return }
        self.assignment = assignment
        self.globalPauseReasons = globalPauseReasons
        isUserPaused = userPaused
        currentScreen = screen
        window.updateFrame(for: screen)
        loadAssignmentIfNeeded()
        applyPauseState()
    }

    func setPaused(
        globalReasons: Set<WallpaperAutomaticPauseReason>,
        userPaused: Bool
    ) {
        globalPauseReasons = globalReasons
        isUserPaused = userPaused
        applyPauseState()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        preparationTask?.cancel()
        preparationTask = nil
        window.onVisibilityChange = nil
        playback.onStateChange = nil
        playback.stop()
        window.tearDown()
        onChange = nil
    }

    private func loadAssignmentIfNeeded() {
        guard assignment != loadedAssignment else { return }
        loadedAssignment = assignment
        preparationTask?.cancel()

        let requestedAssignment = assignment
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await playback.replace(
                    videoURL: requestedAssignment.videoURL,
                    posterURL: requestedAssignment.posterURL,
                    scaling: requestedAssignment.contentFit == .fill
                        ? .resizeAspectFill
                        : .resizeAspect
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestedAssignment == assignment else { return }
                loadedAssignment = nil
                updateStatus(.failed(error.localizedDescription))
            }
        }
    }

    private func applyPauseState() {
        var reasons = globalPauseReasons
        if isOccluded {
            reasons.insert(.windowOccluded)
        }
        playback.setPaused(isUserPaused || !reasons.isEmpty)

        if isUserPaused || !reasons.isEmpty {
            updateStatus(.paused(reasons))
        } else {
            switch playback.state {
            case .preparing, .ready:
                updateStatus(.preparing)
            case .failed(let message):
                updateStatus(.failed(message))
            case .empty:
                updateStatus(.preparing)
            case .playing, .paused:
                updateStatus(.playing)
            }
        }
    }

    private func playbackStateChanged(_ state: LoopingVideoPlaybackState) {
        if isUserPaused || !globalPauseReasons.isEmpty || isOccluded {
            applyPauseState()
            return
        }
        switch state {
        case .empty, .preparing, .ready:
            updateStatus(.preparing)
        case .playing:
            updateStatus(.playing)
        case .paused:
            updateStatus(.paused([]))
        case .failed(let message):
            loadedAssignment = nil
            updateStatus(.failed(message))
        }
    }

    private func updateStatus(_ status: WallpaperSessionStatus) {
        let next = WallpaperSessionSnapshot(id: display.id, status: status)
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }
}
