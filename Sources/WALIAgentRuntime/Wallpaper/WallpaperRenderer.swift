import AppKit
import AVFoundation
import Foundation
import OSLog
import WALIModel

/// Verified agent-owned media presented on one desktop canvas.
public enum WallpaperRenderingContent: Sendable, Hashable {
    case video(videoURL: URL, efficientVideoURL: URL?, posterURL: URL?,
               lowPowerResponse: PresentationLowPowerResponse)
    case still(imageURL: URL)

    fileprivate func hasSameResource(as other: Self) -> Bool {
        switch (self, other) {
        case let (.video(a, _, ap, _), .video(b, _, bp, _)): a == b && ap == bp
        case let (.still(a), .still(b)): a == b
        default: false
        }
    }
}

/// One immutable display-to-media request accepted by ``WallpaperRenderer``.
public struct WallpaperRenderingAssignment: Sendable, Hashable {
    public let displayID: WallpaperDisplayIdentifier
    public let content: WallpaperRenderingContent
    public let contentFit: PresentationContentFit

    public init(displayID: WallpaperDisplayIdentifier, content: WallpaperRenderingContent,
                contentFit: PresentationContentFit = .fill) {
        self.displayID = displayID
        self.content = content
        self.contentFit = contentFit
    }
}

public enum WallpaperSessionStatus: Sendable, Equatable {
    case preparing
    case playing
    case displaying
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

extension WallpaperRendererSnapshot {
    /// Only enum labels and counts enter local logs; never identifiers or failure text.
    var diagnosticSummary: String {
        var statusCounts: [String: Int] = [:]
        var reasonCounts: [WallpaperAutomaticPauseReason: Int] = [:]
        for session in sessions {
            let label: String
            switch session.status {
            case .preparing: label = "preparing"
            case .playing: label = "playing"
            case .displaying: label = "displaying"
            case let .paused(reasons):
                label = "paused"
                for reason in reasons { reasonCounts[reason, default: 0] += 1 }
            case .failed: label = "failed"
            }
            statusCounts[label, default: 0] += 1
        }
        let statuses = ["preparing", "playing", "displaying", "paused", "failed"]
            .map { "\($0):\(statusCounts[$0, default: 0])" }.joined(separator: ",")
        let systemReasons = automaticPauseReasons.map(\.rawValue).sorted().joined(separator: ",")
        let sessionReasons = reasonCounts.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue):\(reasonCounts[$0, default: 0])" }.joined(separator: ",")
        return "sessions=\(sessions.count) statuses=\(statuses)"
            + " system_reasons=\(systemReasons.isEmpty ? "none" : systemReasons)"
            + " session_reasons=\(sessionReasons.isEmpty ? "none" : sessionReasons)"
    }
}

/// Main-actor facade for display reconciliation, wallpaper windows and playback.
@MainActor
public final class WallpaperRenderer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.codewithinferno.wali.WALIAgent",
        category: "WallpaperRenderer"
    )

    public typealias SnapshotHandler = @MainActor (WallpaperRendererSnapshot) -> Void

    public var onSnapshotChange: SnapshotHandler?
    public var onPresentationRefresh: (@MainActor () -> Void)?
    public var onSessionLock: (@MainActor () -> Void)?
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
            self?.onPresentationRefresh?()
            self?.reconcile()
        }
        systemEvents.onChange = { [weak self] reasons in
            guard let self else { return }
            self.automaticPauseReasons = reasons
            self.reconcile()
        }
        systemEvents.onPresentationRefresh = { [weak self] in
            self?.displayMonitor.reconcileNow()
            self?.onPresentationRefresh?()
            self?.reconcile()
        }
        systemEvents.onSessionLock = { [weak self] in
            self?.onSessionLock?()
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
        systemEvents.onPresentationRefresh = nil
        systemEvents.onSessionLock = nil
        onPresentationRefresh = nil
        onSessionLock = nil
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
        guard case let .video(_, _, _, response) = assignment.content else { return [] }
        var reasons = automaticPauseReasons
        if response != .pause { reasons.remove(.lowPower) }
        return reasons
    }

    private func effectiveAssignment(
        _ assignment: WallpaperRenderingAssignment
    ) -> WallpaperRenderingAssignment {
        guard automaticPauseReasons.contains(.lowPower),
              case let .video(_, efficientURL?, posterURL, .reduceQuality) = assignment.content
        else { return assignment }
        return WallpaperRenderingAssignment(
            displayID: assignment.displayID,
            content: .video(videoURL: efficientURL, efficientVideoURL: efficientURL,
                            posterURL: posterURL, lowPowerResponse: .reduceQuality),
            contentFit: assignment.contentFit
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
        Self.logger.notice("Renderer state: \(next.diagnosticSummary, privacy: .public)")
        onSnapshotChange?(next)
    }
}

/// The real video adapter and a window-free deterministic test adapter share
/// this existing playback boundary. Still content never constructs one.
@MainActor
protocol WallpaperVideoPresenting: AnyObject {
    var onStateChange: (@MainActor (LoopingVideoPlaybackState) -> Void)? { get set }
    var state: LoopingVideoPlaybackState { get }
    func replace(videoURL: URL, posterURL: URL?, scaling: PresentationContentFit) async throws
    func setScaling(_ scaling: PresentationContentFit)
    func setPaused(_ paused: Bool)
    func stop()
}

extension LoopingVideoPlayback: WallpaperVideoPresenting {}

/// Owns exactly one active presentation adapter. It has no window, assignment
/// persistence or original-media access, which keeps replacement tests isolated.
@MainActor
final class WallpaperContentPresenter {
    var onChange: (@MainActor (WallpaperSessionStatus) -> Void)?
    private(set) var status: WallpaperSessionStatus = .preparing
    private let canvas: any StaticImageWallpaperCanvas
    private let makeVideo: @MainActor () -> any WallpaperVideoPresenting
    private let loadImage: @MainActor (URL) async throws -> CGImage
    private var video: (any WallpaperVideoPresenting)?
    private var still: StaticImageWallpaperSurface?
    private var requestedContent: WallpaperRenderingContent?
    private var loadedContent: WallpaperRenderingContent?
    private var scaling: PresentationContentFit = .fill
    private var preparationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var userPaused = false
    private var pauseReasons: Set<WallpaperAutomaticPauseReason> = []
    private var closed = false
    private var applyingPauseState = false

    init(canvas: any StaticImageWallpaperCanvas,
         makeVideo: @escaping @MainActor () -> any WallpaperVideoPresenting,
         loadImage: (@MainActor (URL) async throws -> CGImage)? = nil) {
        self.canvas = canvas
        self.makeVideo = makeVideo
        self.loadImage = loadImage ?? { try await StaticWallpaperImageLoader.shared.load($0) }
    }

    func setContent(_ content: WallpaperRenderingContent, scaling: PresentationContentFit) {
        guard !closed else { return }
        self.scaling = scaling
        if let requestedContent, requestedContent.hasSameResource(as: content),
           preparationTask != nil || loadedContent?.hasSameResource(as: content) == true {
            self.requestedContent = content
            video?.setScaling(scaling)
            still?.setScaling(scaling)
            return
        }
        requestedContent = content
        if case .still = content { video?.setPaused(true) }
        generation &+= 1
        let currentGeneration = generation
        preparationTask?.cancel()
        updateStatus(.preparing)
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if currentGeneration == generation { preparationTask = nil }
            }
            do {
                switch content {
                case let .still(imageURL):
                    let image = try await loadImage(imageURL)
                    try Task.checkCancellation()
                    guard !closed, generation == currentGeneration else { return }
                    // Decode and validate before retiring the current display.
                    try StaticImageWallpaperSurface.validate(image)
                    releaseSurface()
                    let surface = try StaticImageWallpaperSurface(canvas: canvas)
                    try surface.present(image, scaling: self.scaling)
                    still = surface
                    loadedContent = content
                    updateStatus(.displaying)
                case let .video(videoURL, _, posterURL, _):
                    if video == nil {
                        releaseSurface()
                        let playback = makeVideo()
                        video = playback
                        playback.onStateChange = { [weak self, weak playback] _ in
                            guard let self, let playback,
                                  self.video === playback,
                                  case .video = self.requestedContent else { return }
                            self.applyPauseState()
                        }
                    }
                    guard let playback = video else { return }
                    playback.setPaused(userPaused || !pauseReasons.isEmpty)
                    try await playback.replace(videoURL: videoURL, posterURL: posterURL,
                                               scaling: self.scaling)
                    try Task.checkCancellation()
                    guard !closed, generation == currentGeneration else { return }
                    loadedContent = content
                    playback.setScaling(self.scaling)
                    applyPauseState()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !closed, generation == currentGeneration else { return }
                loadedContent = nil
                updateStatus(.failed(error.localizedDescription))
            }
        }
    }

    func setPaused(userPaused: Bool, automaticReasons: Set<WallpaperAutomaticPauseReason>) {
        guard !closed else { return }
        self.userPaused = userPaused
        pauseReasons = automaticReasons
        applyPauseState()
    }

    func tearDown() {
        guard !closed else { return }
        closed = true
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        releaseSurface()
        requestedContent = nil
        loadedContent = nil
        onChange = nil
    }

    private func releaseSurface() {
        if let video {
            video.onStateChange = nil
            video.stop()
            self.video = nil
            canvas.onLayout = nil
        }
        still?.tearDown()
        still = nil
    }

    private func applyPauseState() {
        guard !applyingPauseState, case .video = requestedContent, let video else { return }
        applyingPauseState = true
        defer { applyingPauseState = false }
        if case .failed(let message) = video.state {
            loadedContent = nil
            updateStatus(.failed(message))
            return
        }
        let paused = userPaused || !pauseReasons.isEmpty
        video.setPaused(paused)
        if paused {
            updateStatus(.paused(pauseReasons))
        } else {
            switch video.state {
            case .empty, .preparing, .ready: updateStatus(.preparing)
            case .playing, .paused: updateStatus(.playing)
            case .failed(let message):
                loadedContent = nil
                updateStatus(.failed(message))
            }
        }
    }

    private func updateStatus(_ value: WallpaperSessionStatus) {
        guard value != status else { return }
        status = value
        onChange?(value)
    }
}

@MainActor
private final class WallpaperSession {
    let display: WallpaperDisplay
    var assignment: WallpaperRenderingAssignment
    var onChange: (@MainActor () -> Void)?
    private(set) var snapshot: WallpaperSessionSnapshot
    private let window: WallpaperWindow
    private let presenter: WallpaperContentPresenter
    private var currentScreen: NSScreen
    private var globalPauseReasons: Set<WallpaperAutomaticPauseReason> = []
    private var isUserPaused = false
    private var isOccluded = false
    private var isTornDown = false

    init(display: WallpaperDisplay, assignment: WallpaperRenderingAssignment, screen: NSScreen) {
        self.display = display
        self.assignment = assignment
        snapshot = WallpaperSessionSnapshot(id: display.id, status: .preparing)
        currentScreen = screen
        let window = WallpaperWindow(screen: screen)
        self.window = window
        presenter = WallpaperContentPresenter(canvas: window.canvas,
            makeVideo: { LoopingVideoPlayback(canvas: window.canvas) })
        window.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            isOccluded = !visible
            applyPauseState()
        }
        presenter.onChange = { [weak self] status in self?.updateStatus(status) }
    }

    func start(globalPauseReasons: Set<WallpaperAutomaticPauseReason>, userPaused: Bool) {
        self.globalPauseReasons = globalPauseReasons
        isUserPaused = userPaused
        window.show(on: currentScreen)
        presenter.setContent(assignment.content, scaling: assignment.contentFit)
        applyPauseState()
    }

    func update(assignment: WallpaperRenderingAssignment, screen: NSScreen,
                globalPauseReasons: Set<WallpaperAutomaticPauseReason>, userPaused: Bool) {
        guard !isTornDown else { return }
        self.assignment = assignment
        self.globalPauseReasons = globalPauseReasons
        isUserPaused = userPaused
        currentScreen = screen
        window.refreshPlacement(on: screen)
        presenter.setContent(assignment.content, scaling: assignment.contentFit)
        applyPauseState()
    }

    func setPaused(globalReasons: Set<WallpaperAutomaticPauseReason>, userPaused: Bool) {
        globalPauseReasons = globalReasons
        isUserPaused = userPaused
        applyPauseState()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        window.onVisibilityChange = nil
        presenter.tearDown()
        window.tearDown()
        onChange = nil
    }

    private func applyPauseState() {
        var reasons = globalPauseReasons
        if isOccluded { reasons.insert(.windowOccluded) }
        presenter.setPaused(userPaused: isUserPaused, automaticReasons: reasons)
    }

    private func updateStatus(_ status: WallpaperSessionStatus) {
        let next = WallpaperSessionSnapshot(id: display.id, status: status)
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }
}
