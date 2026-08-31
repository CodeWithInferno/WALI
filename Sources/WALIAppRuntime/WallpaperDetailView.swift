import SwiftUI
import WALIUI

struct WallpaperDetailView: View {
    let wallpaper: WALIWallpaperPresentation
    let displays: [WALIDisplayPresentation]
    @Binding var selectedDisplayIDs: Set<String>
    let onApply: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkThumbnail(imageURL: wallpaper.thumbnailURL, title: wallpaper.title, cornerRadius: 16)
                        .aspectRatio(16 / 10, contentMode: .fit)

                    Button(action: onPreview) {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .padding(12)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(wallpaper.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Spacer()
                        if wallpaper.isActive {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
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
                    Text("Displays")
                        .font(.headline)
                    if displays.isEmpty {
                        Label("No displays are currently available", systemImage: "display.trianglebadge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(displays) { display in
                            Toggle(isOn: displayBinding(display.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                                    Text(display.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!display.isConnected)
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Apply", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!isReady || selectedDisplayIDs.isEmpty)

                    Menu {
                        Button("Show in Finder", action: onReveal)
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .controlSize(.large)
                    .help("More Actions")
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("WALI.WallpaperDetail")
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
        LabeledContent(label, value: value)
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

    private var isReady: Bool {
        if case .ready = wallpaper.availability { true } else { false }
    }
}

struct DisplayAssignmentMenu: View {
    let displays: [WALIDisplayPresentation]
    @Binding var selection: Set<String>

    var body: some View {
        Menu {
            if displays.isEmpty {
                Text("No Displays Available")
            } else {
                ForEach(displays) { display in
                    Toggle(isOn: binding(for: display.id)) {
                        Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                    }
                    .disabled(!display.isConnected)
                }
                Divider()
                Button("All Connected Displays") {
                    selection = Set(displays.lazy.filter(\.isConnected).map(\.id))
                }
            }
        } label: {
            Label(menuTitle, systemImage: "display.2")
        }
        .help("Choose Displays")
        .accessibilityIdentifier("WALI.DisplayPicker")
    }

    private var menuTitle: String {
        switch selection.count {
        case 0: "Choose Displays"
        case 1: "1 Display"
        default: "\(selection.count) Displays"
        }
    }

    private func binding(for displayID: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(displayID) },
            set: { selected in
                if selected { selection.insert(displayID) }
                else { selection.remove(displayID) }
            }
        )
    }
}
