import SwiftUI
import WALIUI

struct DownloadsSurface: View {
    let transfers: [WALITransferPresentation]
    let onImport: () -> Void
    let onDrop: ([URL]) -> Void
    let onCancel: (UUID) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if transfers.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Imports", systemImage: "arrow.down.circle")
                } description: {
                    Text("Import a video or drop one here. WALI will show preparation progress on this page.")
                } actions: {
                    Button("Import Video…", action: onImport)
                        .controlSize(.large)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Recent Imports")
                                .font(.headline)

                            Spacer()

                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button(action: onImport) {
                                Label("Import Video…", systemImage: "plus")
                            }
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(transfers.enumerated()), id: \.element.id) { index, transfer in
                                TransferRow(transfer: transfer, onCancel: { onCancel(transfer.id) })
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)

                                if index < transfers.index(before: transfers.endIndex) {
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        }

                        Label("Original videos stay untouched", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
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
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("WALI.Downloads")
    }

    private var summary: String {
        let activeCount = transfers.count { transfer in
            switch transfer.state {
            case .queued, .working: true
            default: false
            }
        }
        if activeCount > 0 {
            return activeCount == 1 ? "1 active" : "\(activeCount) active"
        }
        return transfers.count == 1 ? "1 item" : "\(transfers.count) items"
    }
}

private struct TransferRow: View {
    let transfer: WALITransferPresentation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))

                Image(systemName: symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(symbolColor)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if case let .working(progress) = transfer.state {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .accessibilityLabel("\(transfer.title) progress")
                }
            }

            Spacer(minLength: 12)

            if canCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.small)
            } else {
                Text(stateTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(symbolColor)
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
        switch transfer.state {
        case let .failed(message): message
        case .ready: "Added to your Library"
        case .cancelled: "Import cancelled"
        default: transfer.detail
        }
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
