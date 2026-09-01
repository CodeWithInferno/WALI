import AVFoundation
import AVKit
import SwiftUI
import WALIUI

struct LoopingVideoView: View {
    let url: URL

    @State private var playback: LoopingPlayback?

    var body: some View {
        Group {
            if let playback {
                VideoPlayer(player: playback.player)
                    .disabled(true)
            } else {
                Color(nsColor: .controlBackgroundColor)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            let playback = LoopingPlayback(url: url)
            self.playback = playback
            playback.player.play()
        }
        .onDisappear {
            playback?.player.pause()
            playback = nil
        }
        .accessibilityHidden(true)
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
            LoopingVideoView(url: previewURL)
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
