import SwiftUI
import WALIUI

struct DownloadsSurface: View {
    let transfers: [WALITransferPresentation]
    let catalogInstall: WALICatalogInstallPresentation?
    let onCancelCatalog: () -> Void
    let onRetryCatalog: () -> Void
    let onImport: () -> Void
    let onDrop: ([URL]) -> Void
    let onCancel: (UUID) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Downloads") {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Button("Import Video…", systemImage: "plus", action: onImport)
            }
            if let catalogInstall, catalogInstall.phase != .completed {
                CatalogInstallProgressView(install: catalogInstall, onCancel: onCancelCatalog, onRetry: onRetryCatalog)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            if transfers.isEmpty && catalogInstall == nil {
                ContentUnavailableView {
                    Label("No Downloads or Imports", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a wallpaper or import a video to see its progress here.")
                } actions: {
                    Button("Import Video…", action: onImport)
                        .controlSize(.large)
                }
            } else if !transfers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        let activeCount = (catalogInstall?.isActive == true ? 1 : 0) + transfers.count { transfer in
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

struct CatalogInstallProgressView: View {
    let install: WALICatalogInstallPresentation
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(install.title).font(.body.weight(.medium)).lineLimit(1)
                Text(install.status).font(.callout).foregroundStyle(.secondary)
                if install.phase == .downloading, install.expectedBytes > 0 {
                    ProgressView(value: Double(install.receivedBytes), total: Double(install.expectedBytes))
                        .accessibilityLabel("Wallpaper download")
                    Text("\(bytes(install.receivedBytes)) of \(bytes(install.expectedBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if install.isActive {
                    ProgressView().controlSize(.small).accessibilityLabel(install.status)
                }
            }
            Spacer(minLength: 8)
            if install.canCancel {
                Button("Cancel", role: .cancel, action: onCancel)
            } else if case .failed = install.phase {
                Button("Try Again", action: onRetry)
            } else if install.phase == .cancelled {
                Button("Try Again", action: onRetry)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
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
                Text(WALILibraryItemTitle.displayName(from: transfer.title))
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(symbolColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 1)
            }

            if WALIChromeLayout.noticeShowsDismissControl, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: WALIChromeLayout.noticeMaxWidth, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: WALIChromeLayout.noticeCornerRadius, style: .continuous)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
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
