import SwiftUI
import WALIUI

struct LibrarySurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let wallpapers: [WALIWallpaperPresentation]
    @Binding var selectedID: UUID?
    let previewedID: UUID?
    let canApply: Bool
    let onImport: () -> Void
    let onApply: (WALIWallpaperPresentation) -> Void
    let onPreview: (WALIWallpaperPresentation) -> Void
    let onDelete: (WALIWallpaperPresentation) -> Void
    let onReveal: (WALIWallpaperPresentation) -> Void
    let onDrop: ([URL]) -> Void

    @State private var previewTask: Task<Void, Never>?
    @State private var hoveringID: UUID?

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 16, alignment: .top)
    ]

    var body: some View {
        Group {
            if wallpapers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(wallpapers) { wallpaper in
                            WallpaperTile(
                                wallpaper: wallpaper,
                                isSelected: wallpaper.id == selectedID,
                                isPreviewing: wallpaper.id == hoveringID,
                                canApply: canApply,
                                onSelect: { selectedID = wallpaper.id },
                                onApply: { onApply(wallpaper) },
                                onPreview: { onPreview(wallpaper) },
                                onDelete: { onDelete(wallpaper) },
                                onReveal: { onReveal(wallpaper) },
                                onHover: { updateHover($0, wallpaperID: wallpaper.id) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let movieURLs = urls.filter(\.isFileURL)
            guard !movieURLs.isEmpty else { return false }
            onDrop(movieURLs)
            return true
        }
        .onDisappear {
            previewTask?.cancel()
            hoveringID = nil
        }
        .accessibilityIdentifier("WALI.Library")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library Is Ready", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Drag in a video or import one from your Mac. WALI keeps the original untouched.")
        } actions: {
            Button("Import Video…", action: onImport)
                .controlSize(.large)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let movieURLs = urls.filter(\.isFileURL)
            guard !movieURLs.isEmpty else { return false }
            onDrop(movieURLs)
            return true
        }
    }

    private func updateHover(_ isHovering: Bool, wallpaperID: UUID) {
        previewTask?.cancel()

        if isHovering, !reduceMotion {
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                hoveringID = wallpaperID
            }
        } else if hoveringID == wallpaperID {
            hoveringID = nil
        }
    }
}

private struct WallpaperTile: View {
    let wallpaper: WALIWallpaperPresentation
    let isSelected: Bool
    let isPreviewing: Bool
    let canApply: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    let onHover: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        if isApplyEnabled {
            tile
                .accessibilityAction(named: "Apply", onApply)
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if isPreviewing, let previewURL = wallpaper.previewURL {
                        LoopingVideoView(url: previewURL)
                    } else {
                        ArtworkThumbnail(imageURL: wallpaper.thumbnailURL, title: wallpaper.title)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }

                statusOverlay
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(wallpaper.title)
                        .font(.headline)
                        .lineLimit(1)
                    if wallpaper.isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Active wallpaper")
                    }
                }
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard isApplyEnabled else { return }
            onApply()
        }
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .onHover(perform: onHover)
        .contextMenu {
            Button("Apply to Selected Displays", action: onApply)
                .disabled(!isApplyEnabled)
            Button("Preview", action: onPreview)
            Divider()
            Button("Show in Finder", action: onReveal)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Preview", onPreview)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch wallpaper.availability {
        case .ready:
            if wallpaper.isActive {
                Label("Active", systemImage: "play.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        case let .preparing(progress):
            HStack(spacing: 6) {
                ProgressView(value: progress.map(clamped))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Preparing")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var metadata: String {
        [wallpaper.dimensions, wallpaper.duration, wallpaper.fileSize]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    private var accessibilityLabel: String {
        var parts = [wallpaper.title, metadata]
        if wallpaper.isActive { parts.append("Active") }
        return parts.joined(separator: ", ")
    }

    private var isReady: Bool {
        if case .ready = wallpaper.availability { true } else { false }
    }

    private var isApplyEnabled: Bool {
        isReady && canApply
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
