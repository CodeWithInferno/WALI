@preconcurrency import AVFoundation
import AppKit
import Foundation
import QuartzCore

public enum WallpaperPlaybackError: Error, LocalizedError, Sendable {
    case sourceMustBeAFile
    case sourceIsUnreadable
    case assetIsNotPlayable
    case assetHasNoVideoTrack

    public var errorDescription: String? {
        switch self {
        case .sourceMustBeAFile:
            "The wallpaper source must be a local file."
        case .sourceIsUnreadable:
            "The wallpaper video cannot be read."
        case .assetIsNotPlayable:
            "The wallpaper video is not playable."
        case .assetHasNoVideoTrack:
            "The wallpaper asset has no video track."
        }
    }
}

public enum LoopingVideoPlaybackState: Sendable, Equatable {
    case empty
    case preparing
    case ready
    case playing
    case paused
    case failed(String)
}

@MainActor
final class LoopingVideoPlayback {
    var onStateChange: (@MainActor (LoopingVideoPlaybackState) -> Void)?

    private let canvas: WallpaperCanvasView
    private var activeSurface: Surface?
    private var pendingSurface: Surface?
    private var replacementGeneration: UInt64 = 0
    private var isPaused = false
    private(set) var state: LoopingVideoPlaybackState = .empty {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    init(canvas: WallpaperCanvasView) {
        self.canvas = canvas
    }

    func replace(
        videoURL: URL,
        posterURL: URL?,
        scaling: AVLayerVideoGravity
    ) async throws {
        replacementGeneration &+= 1
        let generation = replacementGeneration
        state = .preparing

        guard videoURL.isFileURL else {
            state = .failed(WallpaperPlaybackError.sourceMustBeAFile.localizedDescription)
            throw WallpaperPlaybackError.sourceMustBeAFile
        }
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            state = .failed(WallpaperPlaybackError.sourceIsUnreadable.localizedDescription)
            throw WallpaperPlaybackError.sourceIsUnreadable
        }

        let asset = AVURLAsset(url: videoURL)
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard generation == replacementGeneration else {
            throw CancellationError()
        }
        guard playable else {
            state = .failed(WallpaperPlaybackError.assetIsNotPlayable.localizedDescription)
            throw WallpaperPlaybackError.assetIsNotPlayable
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()
        guard generation == replacementGeneration else {
            throw CancellationError()
        }
        guard !videoTracks.isEmpty else {
            state = .failed(WallpaperPlaybackError.assetHasNoVideoTrack.localizedDescription)
            throw WallpaperPlaybackError.assetHasNoVideoTrack
        }

        let surface = Surface(
            asset: asset,
            poster: posterURL.flatMap(NSImage.init(contentsOf:)),
            scaling: scaling
        )
        pendingSurface?.tearDown(from: canvas)
        pendingSurface = surface
        canvas.addSurface(surface.containerLayer, visible: activeSurface == nil)

        let surfaceID = surface.id
        surface.readyObservation = surface.playerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                self?.surfaceBecameReady(surfaceID)
            }
        }
        surface.statusObservation = surface.item.observe(
            \.status,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.surfaceStatusChanged(surfaceID)
            }
        }
        surface.readyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.surfaceReadinessTimedOut(surfaceID)
        }

        // The pending player must decode one frame even when the current
        // presentation is paused; it is paused again immediately on commit.
        surface.player.play()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        guard let activeSurface else {
            if state != .preparing {
                state = paused ? .paused : .empty
            }
            return
        }

        activeSurface.setPosterVisible(paused)
        if paused {
            activeSurface.player.pause()
            state = .paused
        } else {
            activeSurface.player.play()
            state = .playing
        }
    }

    func stop() {
        replacementGeneration &+= 1
        pendingSurface?.tearDown(from: canvas)
        activeSurface?.tearDown(from: canvas)
        pendingSurface = nil
        activeSurface = nil
        canvas.removeAllSurfaces()
        state = .empty
    }

    private func surfaceBecameReady(_ surfaceID: UUID) {
        guard let pendingSurface, pendingSurface.id == surfaceID else { return }
        pendingSurface.readyObservation = nil
        pendingSurface.readyTimeoutTask?.cancel()
        pendingSurface.readyTimeoutTask = nil
        pendingSurface.setPosterVisible(isPaused)
        if isPaused {
            pendingSurface.player.pause()
        }

        let oldSurface = activeSurface
        activeSurface = pendingSurface
        self.pendingSurface = nil
        state = isPaused ? .paused : .playing

        canvas.crossfade(
            from: oldSurface?.containerLayer,
            to: pendingSurface.containerLayer
        ) { [canvas, oldSurface] in
            oldSurface?.tearDown(from: canvas)
        }
    }

    private func surfaceStatusChanged(_ surfaceID: UUID) {
        guard let surface = surface(withID: surfaceID) else { return }
        switch surface.item.status {
        case .failed:
            let message = surface.item.error?.localizedDescription
                ?? "The wallpaper player failed."
            if pendingSurface?.id == surfaceID {
                pendingSurface?.tearDown(from: canvas)
                pendingSurface = nil
                state = .failed(message)
            } else if activeSurface?.id == surfaceID {
                state = .failed(message)
                surface.setPosterVisible(true)
                surface.player.pause()
            }
        case .readyToPlay:
            if pendingSurface?.id == surfaceID, !surface.playerLayer.isReadyForDisplay {
                state = .ready
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func surfaceReadinessTimedOut(_ surfaceID: UUID) {
        guard pendingSurface?.id == surfaceID else { return }
        pendingSurface?.tearDown(from: canvas)
        pendingSurface = nil
        state = .failed("The wallpaper player did not produce a frame in time.")
    }

    private func surface(withID id: UUID) -> Surface? {
        if activeSurface?.id == id { return activeSurface }
        if pendingSurface?.id == id { return pendingSurface }
        return nil
    }

    @MainActor
    private final class Surface {
        let id = UUID()
        let containerLayer = CALayer()
        let posterLayer = CALayer()
        let playerLayer: AVPlayerLayer
        let player: AVQueuePlayer
        let item: AVPlayerItem
        var looper: AVPlayerLooper?
        var readyObservation: NSKeyValueObservation?
        var statusObservation: NSKeyValueObservation?
        var readyTimeoutTask: Task<Void, Never>?

        init(asset: AVAsset, poster: NSImage?, scaling: AVLayerVideoGravity) {
            item = AVPlayerItem(asset: asset)
            player = AVQueuePlayer()
            player.isMuted = true
            player.volume = 0
            player.actionAtItemEnd = .advance
            player.automaticallyWaitsToMinimizeStalling = true
            looper = AVPlayerLooper(player: player, templateItem: item)

            playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = scaling
            playerLayer.backgroundColor = NSColor.black.cgColor

            posterLayer.backgroundColor = NSColor.black.cgColor
            posterLayer.contents = poster?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
            posterLayer.contentsGravity = scaling == .resizeAspectFill
                ? .resizeAspectFill
                : .resizeAspect
            posterLayer.opacity = 1

            containerLayer.backgroundColor = NSColor.black.cgColor
            containerLayer.masksToBounds = true
            containerLayer.addSublayer(posterLayer)
            containerLayer.addSublayer(playerLayer)
        }

        func setPosterVisible(_ visible: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            posterLayer.opacity = visible ? 1 : 0
            playerLayer.opacity = visible ? 0 : 1
            CATransaction.commit()
        }

        func tearDown(from canvas: WallpaperCanvasView) {
            readyObservation = nil
            statusObservation = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            playerLayer.player = nil
            canvas.removeSurface(containerLayer)
        }
    }
}
