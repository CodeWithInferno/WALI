import SwiftUI
import WALIUI

struct WallpaperDetailView: View {
    let wallpaper: WALIWallpaperPresentation
    let displays: [WALIDisplayPresentation]
    @Binding var selectedDisplayIDs: Set<String>
    @Binding var contentFit: WALIContentFitPreference
    let onApply: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkThumbnail(
                            imageURL: wallpaper.thumbnailURL,
                            title: wallpaper.title,
                            cornerRadius: 16
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 10, contentMode: .fit)

                        Button(action: onPreview) {
                            Label("Preview", systemImage: "play.fill")
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(wallpaper.title)
                                .font(.title3.weight(.semibold))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                                .textSelection(.enabled)
                            Spacer()
                            if wallpaper.isActive {
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize()
                            }
                        }

                        if let creator = wallpaper.creator {
                            Text("By \(creator)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    availability

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Details")
                            .font(.headline)
                        detailRow("Dimensions", value: wallpaper.dimensions)
                        if let duration = wallpaper.duration {
                            detailRow("Duration", value: duration)
                        }
                        detailRow("File Size", value: wallpaper.fileSize)
                        if let license = wallpaper.license {
                            detailRow("License", value: license)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appearance")
                            .font(.headline)
                        Picker("Scaling", selection: $contentFit) {
                            Text("Fill Screen").tag(WALIContentFitPreference.fill)
                            Text("Fit to Screen").tag(WALIContentFitPreference.fit)
                            Text("Stretch to Fill").tag(WALIContentFitPreference.stretch)
                            Text("Center").tag(WALIContentFitPreference.center)
                        }
                        Text(contentFitDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Displays")
                            .font(.headline)
                        if displays.isEmpty {
                            Label(
                                "No displays are currently available",
                                systemImage: "display.trianglebadge.exclamationmark"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        } else {
                            ForEach(displays) { display in
                                Toggle(isOn: displayBinding(display.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label(
                                            display.name,
                                            systemImage: display.isBuiltIn ? "laptopcomputer" : "display"
                                        )
                                        Text(display.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(!display.isConnected)
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("WALI.WallpaperDetail.Display.\(display.id)")
                            }
                        }
                    }

                }
                .frame(
                    width: max(geometry.size.width - 40, 1),
                    alignment: .leading
                )
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .accessibilityIdentifier("WALI.WallpaperDetail")
    }

    private var actionFooter: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady || !hasConnectedDisplaySelection)
                    .accessibilityIdentifier("WALI.WallpaperDetail.Apply")

                Menu {
                    Button("Show in Finder", action: onReveal)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More Actions")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var availability: some View {
        switch wallpaper.availability {
        case .ready:
            EmptyView()
        case let .preparing(progress):
            VStack(alignment: .leading, spacing: 7) {
                Label("Preparing an efficient copy", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.callout.weight(.medium))
                ProgressView(value: progress)
                Text("You can keep browsing while conversion continues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 5) {
                Label("Couldn’t prepare this video", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The source video is still untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
        .font(.callout)
    }

    private func displayBinding(_ displayID: String) -> Binding<Bool> {
        Binding(
            get: { selectedDisplayIDs.contains(displayID) },
            set: { selected in
                if selected {
                    selectedDisplayIDs.insert(displayID)
                } else {
                    selectedDisplayIDs.remove(displayID)
                }
            }
        )
    }

    private var contentFitDescription: String {
        switch contentFit {
        case .fill: "Fills the display while preserving proportions; edges may be cropped."
        case .fit: "Shows the entire video with letterboxing when needed."
        case .stretch: "Fills the display exactly; proportions may change."
        case .center: "Centers the video without enlarging it beyond its native resolution."
        }
    }

    private var isReady: Bool {
        if case .ready = wallpaper.availability { true } else { false }
    }

    private var hasConnectedDisplaySelection: Bool {
        displays.contains { display in
            display.isConnected && selectedDisplayIDs.contains(display.id)
        }
    }
}
