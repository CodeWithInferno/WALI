import AppKit
import SwiftUI

/// Shared renderer controls used by the menu-bar extra.
public struct StatusPanel: View {
    private let status: WALIRendererPresentation
    private let actions: any WALIUIActionHandling

    public init(
        status: WALIRendererPresentation = .stopped,
        actions: any WALIUIActionHandling = NoopWALIUIActionHandler()
    ) {
        self.status = status
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            brandHeader
            activeWallpaper
            Divider()
            rendererStatus
            primaryControls
            Divider()
            secondaryActions
        }
        .padding(16)
        .frame(width: 320)
        .task {
            while !Task.isCancelled {
                actions.send(.refreshDiagnostics)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WALI.StatusPanel")
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            WALIBrandMark()
                .frame(width: 28, height: 20)
            Text("WALI")
                .font(.headline)

            Spacer(minLength: 12)

            Image(systemName: stateSymbol)
                .foregroundStyle(stateTint)
                .accessibilityHidden(true)
            Text(stateTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var activeWallpaper: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                imageURL: status.thumbnailURL,
                title: status.wallpaperTitle ?? "No wallpaper",
                cornerRadius: 8
            )
            .frame(width: 88, height: 55)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.wallpaperTitle ?? "No wallpaper active")
                    .font(.headline)
                    .lineLimit(2)

                Text(displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var rendererStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stateDetail {
                Text(stateDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .converting(progress) = status.state, let progress {
                ProgressView(value: clamped(progress))
                    .accessibilityLabel("Conversion progress")
            }

            HStack(spacing: 24) {
                metric(label: "CPU", value: formattedCPU)
                metric(label: "Memory", value: formattedMemory)
            }
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 8) {
            if status.state != .displaying {
                Button {
                    actions.send(.setPaused(!status.state.isPaused))
                } label: {
                    Label(status.state.isPaused ? "Resume" : "Pause", systemImage: status.state.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(status.state == .stopped)
            }

            Button {
                actions.send(.nextWallpaper)
            } label: {
                Label("Next", systemImage: "forward.end.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(status.wallpaperTitle == nil)
        }
        .controlSize(.large)
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            actionButton("Open WALI", systemImage: "macwindow") {
                actions.send(.openMainApplication)
            }
            actionButton("Settings…", systemImage: "gearshape") {
                actions.send(.openSettings)
            }
            actionButton("Stop Wallpaper", systemImage: "stop.circle") {
                actions.send(.stopWallpaper)
            }
            .disabled(status.state == .stopped)
            actionButton("Quit WALI", systemImage: "power") {
                actions.send(.quit)
            }
        }
        .buttonStyle(.plain)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private var formattedCPU: String {
        guard let cpuPercent = status.cpuPercent else { return "—" }
        if cpuPercent > 0, cpuPercent < 0.1 { return "<0.1%" }
        return cpuPercent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private var formattedMemory: String {
        guard let bytes = status.physicalMemoryBytes else { return "—" }
        return bytes.formatted(.byteCount(style: .memory))
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 5)
        }
    }

    private var displayDescription: String {
        switch status.displayCount {
        case 0: "Not assigned to a display"
        case 1: "1 display"
        default: "\(status.displayCount) displays"
        }
    }

    private var stateTitle: String {
        switch status.state {
        case .stopped: "Stopped"
        case .playing: "Playing"
        case .displaying: "Displayed"
        case .automaticallyPaused: "Automatically Paused"
        case .userPaused: "Paused"
        case .converting: "Converting"
        case .error: "Needs Attention"
        }
    }

    private var stateDetail: String? {
        switch status.state {
        case let .automaticallyPaused(reason): reason
        case let .error(message): message
        case .converting: "Preparing an efficient local copy. Browsing remains available."
        default: nil
        }
    }

    private var stateSymbol: String {
        switch status.state {
        case .stopped: "stop.circle"
        case .playing: "play.circle.fill"
        case .displaying: "photo"
        case .automaticallyPaused: "leaf.circle"
        case .userPaused: "pause.circle.fill"
        case .converting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var stateTint: Color {
        switch status.state {
        case .playing, .displaying: .accentColor
        case .automaticallyPaused: .orange
        case .error: .red
        default: .secondary
        }
    }

    private func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}

/// Image-first wallpaper artwork with an honest, semantic placeholder.
public struct ArtworkThumbnail: View {
    private let imageURL: URL?
    private let title: String
    private let cornerRadius: CGFloat
    @State private var image: NSImage?

    public init(imageURL: URL?, title: String, cornerRadius: CGFloat = 12) {
        self.imageURL = imageURL
        self.title = title
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(title)
        .task(id: imageURL) {
            image = nil
            guard let imageURL else { return }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: imageURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}
