import AppKit
import AVFoundation
import AVKit
import QuartzCore
import SwiftUI
import WALIUI

struct LoopingVideoView: View {
    let url: URL
    var cornerRadius: CGFloat = 12
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var fadesOutAtBottom: Bool = false

    @State private var playback: LoopingPlayback?

    var body: some View {
        Group {
            if let playback {
                LayerBackedVideoPlayer(
                    player: playback.player,
                    videoGravity: videoGravity,
                    fadesOutAtBottom: fadesOutAtBottom
                )
            } else {
                Color(nsColor: .controlBackgroundColor)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            let playback = LoopingPlayback(url: url)
            self.playback = playback
            playback.player.play()
        }
        .onDisappear {
            playback?.player.pause()
            self.playback = nil
        }
        .accessibilityHidden(true)
    }
}

private struct LayerBackedVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity
    var fadesOutAtBottom = false

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.videoGravity = videoGravity
        view.fadesOutAtBottom = fadesOutAtBottom
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.player = player
        view.videoGravity = videoGravity
        view.fadesOutAtBottom = fadesOutAtBottom
    }
}

private final class PlayerLayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    var fadesOutAtBottom = false {
        didSet { updateBottomFade() }
    }

    private let fadeMask = CAGradientLayer()

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerLayerView requires AVPlayerLayer backing")
        }
        return playerLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.colors = [
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.45).cgColor,
            NSColor.clear.cgColor
        ]
        fadeMask.locations = [0, 0.48, 0.78, 1]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        fadeMask.frame = bounds
        updateBottomFade()
    }

    private func updateBottomFade() {
        playerLayer.mask = fadesOutAtBottom ? fadeMask : nil
    }
}

@MainActor
private final class LoopingPlayback {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: item)
    }
}

struct WallpaperPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let wallpaper: WALIWallpaperPresentation
    let displayIDs: Set<String>
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(minWidth: 680, minHeight: 420)
                .background(Color.black)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallpaper.title)
                        .font(.headline)
                    Text([wallpaper.dimensions, wallpaper.duration, wallpaper.fileSize].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || displayIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(idealWidth: 840, idealHeight: 560)
        .accessibilityIdentifier("WALI.Preview")
    }

    @ViewBuilder
    private var preview: some View {
        if let previewURL = wallpaper.previewURL {
            LoopingVideoView(url: previewURL, videoGravity: .resizeAspect)
                .clipShape(Rectangle())
        } else {
            ArtworkThumbnail(imageURL: wallpaper.thumbnailURL, title: wallpaper.title, cornerRadius: 0)
                .scaledToFit()
        }
    }

    private var isReady: Bool {
        if case .ready = wallpaper.availability { true } else { false }
    }
}
