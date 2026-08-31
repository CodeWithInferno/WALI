import SwiftUI
import WALIUI

struct CreateSurface: View {
    let onImport: () -> Void
    let onDrop: ([URL]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create a Wallpaper")
                        .font(.title)
                    Text("Choose a video and WALI will prepare a quiet, efficient local copy for your displays.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)

                    VStack(spacing: 5) {
                        Text("Drop a video here")
                            .font(.headline)
                        Text("QuickTime movies and other formats supported by macOS")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button("Choose Video…", action: onImport)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 5])
                        )
                }
                .dropDestination(
                    for: URL.self,
                    action: { urls, _ in
                        let movieURLs = urls.filter(\.isFileURL)
                        guard !movieURLs.isEmpty else { return false }
                        onDrop(movieURLs)
                        return true
                    },
                    isTargeted: { isDropTargeted = $0 }
                )

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Private by design")
                            .font(.headline)
                        Text("Your media stays on this Mac. WALI never deletes or modifies the source file.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityIdentifier("WALI.Create")
    }
}

struct DownloadsSurface: View {
    let transfers: [WALITransferPresentation]
    let onCancel: (UUID) -> Void

    var body: some View {
        Group {
            if transfers.isEmpty {
                ContentUnavailableView {
                    Label("No Active Imports", systemImage: "arrow.down.circle")
                } description: {
                    Text("Video preparation and import progress will appear here.")
                }
            } else {
                List(transfers) { transfer in
                    TransferRow(transfer: transfer, onCancel: { onCancel(transfer.id) })
                        .padding(.vertical, 6)
                }
            }
        }
        .accessibilityIdentifier("WALI.Downloads")
    }
}

private struct TransferRow: View {
    let transfer: WALITransferPresentation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(symbolColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(transfer.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(stateTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if case let .working(progress) = transfer.state {
                    ProgressView(value: progress)
                        .accessibilityLabel("\(transfer.title) progress")
                }
            }

            if canCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        switch transfer.state {
        case .queued: "Waiting"
        case .working: "Preparing"
        case .ready: "Ready"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var detailText: String {
        if case let .failed(message) = transfer.state { return message }
        return transfer.detail
    }

    private var symbolName: String {
        switch transfer.state {
        case .queued: "clock"
        case .working: "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var symbolColor: Color {
        switch transfer.state {
        case .ready: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var canCancel: Bool {
        switch transfer.state {
        case .queued, .working: true
        default: false
        }
    }
}

struct DiscoverUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Discover Is Offline", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("The public catalog is not part of this release. Everything already in your Library remains available offline.")
        }
        .accessibilityIdentifier("WALI.Discover")
    }
}

struct PlaylistsSurface: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Playlists Yet", systemImage: "rectangle.stack")
        } description: {
            Text("Playlist rotation will arrive after the core wallpaper experience is complete.")
        }
        .accessibilityIdentifier("WALI.Playlists")
    }
}

struct NoticeBanner: View {
    let kind: WALINoticeKind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(
        kind: WALINoticeKind,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Dismiss")
            }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbolName: String {
        switch kind {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var symbolColor: Color {
        switch kind {
        case .information: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
