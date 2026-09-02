import AppKit
import SwiftUI
import WALICatalogRuntime
import WALIUI

struct MarketplaceWallpaperDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @Bindable var marketplace: WALIMarketplaceModel
    let wallpaperID: String
    let onRetry: () -> Void
    let onOpenRelated: (String) -> Void
    let onInstall: () -> Void
    let onFavorite: () -> Void
    let onSave: () -> Void
    let onReport: (CatalogReportKind, String) -> Void

    @State private var showsReportSheet = false

    var body: some View {
        Group {
            if let detail = marketplace.selectedDetail, detail.id == wallpaperID {
                detailContent(detail)
            } else {
                loadingContent
            }
        }
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .topLeading) {
            backButton
                .padding(.leading, 228)
                .padding(.top, 14)
        }
        .overlay(alignment: .bottom) {
            actionNotice
                .padding(18)
        }
        .sheet(isPresented: $showsReportSheet) {
            WallpaperReportView(state: marketplace.reportState) { kind, detail in
                onReport(kind, detail)
            }
            .interactiveDismissDisabled(marketplace.reportState == .working)
        }
        .onChange(of: marketplace.reportState) { _, state in
            if case .succeeded = state { showsReportSheet = false }
        }
        .accessibilityIdentifier("WALI.Marketplace.Detail")
    }

    @ViewBuilder
    private func detailContent(_ detail: WALICatalogDetailPresentation) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    hero(detail, height: max(560, geometry.size.height * 0.82))
                    metadata(detail)
                    if !detail.related.isEmpty {
                        related(detail.related)
                    }
                }
            }
            .background(Color.black)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func hero(_ detail: WALICatalogDetailPresentation, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if reduceMotion, let posterURL = detail.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                } else if let previewURL = detail.previewURL {
                    LoopingVideoView(url: previewURL, cornerRadius: 0)
                } else if let posterURL = detail.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                } else {
                    Color.black
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.title)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(2)
                    Text("By \(detail.creator)  ·  \(detail.category)")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Label(
                        "\(detail.verifiedInstallCount.formatted(.number.notation(.compactName))) verified installs",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                heroActions(detail)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 34)
            .padding(.bottom, 30)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var backButton: some View {
        if #available(macOS 26.0, *) {
            Button("Back", systemImage: "chevron.left") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            Button("Back", systemImage: "chevron.left") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private func heroActions(_ detail: WALICatalogDetailPresentation) -> some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 10) {
                favoriteButton(detail)
                    .buttonStyle(.glass)
                installButton
                    .buttonStyle(.glassProminent)
            }
        } else {
            HStack(spacing: 10) {
                favoriteButton(detail)
                    .buttonStyle(.bordered)
                installButton
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func favoriteButton(_ detail: WALICatalogDetailPresentation) -> some View {
        Button(action: onFavorite) {
            Label("Favorite", systemImage: detail.isFavorite ? "heart.fill" : "heart")
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .disabled(marketplace.actionState == .working)
    }

    private var installButton: some View {
        Button(action: onInstall) {
            Label("Add to Library", systemImage: "arrow.down.circle.fill")
        }
        .controlSize(.large)
        .disabled(marketplace.actionState == .working)
    }

    private func metadata(_ detail: WALICatalogDetailPresentation) -> some View {
        HStack(alignment: .top, spacing: 42) {
            VStack(alignment: .leading, spacing: 18) {
                Text("About this wallpaper")
                    .font(.title2.weight(.semibold))
                Text(detail.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)

                LabeledContent("Rights Holder", value: detail.rightsHolder)

                if let attribution = detail.attribution, !attribution.isEmpty {
                    LabeledContent("Attribution", value: attribution)
                }

                HStack(spacing: 10) {
                    ForEach(detail.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Dimensions", value: detail.dimensions)
                LabeledContent("Duration", value: detail.duration)
                LabeledContent("Frame Rate", value: "\(detail.framesPerSecond.formatted()) fps")
                LabeledContent("Favorites", value: detail.favoriteCount.formatted())
                LabeledContent("Saves", value: detail.saveCount.formatted())
                Button(detail.licenseName) { openURL(detail.licenseTermsURL) }
                HStack {
                    Button("Save", systemImage: detail.isSaved ? "bookmark.fill" : "bookmark", action: onSave)
                    Button("Copy Wallpaper ID", systemImage: "doc.on.doc") { copyIdentifier(detail.id) }
                    Button("Report", systemImage: "exclamationmark.bubble") {
                        marketplace.reportState = .idle
                        showsReportSheet = true
                    }
                }
                .labelStyle(.iconOnly)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(34)
        .foregroundStyle(.white)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
    }

    private func related(_ cards: [WALICatalogCardPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Related Wallpapers")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 18)],
                spacing: 24
            ) {
                ForEach(cards) { card in
                    CatalogCardView(card: card) { onOpenRelated(card.id) }
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(34)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
    }

    @ViewBuilder
    private var loadingContent: some View {
        switch marketplace.detailState {
        case .idle, .loading:
            ProgressView("Loading wallpaper…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .offline:
            ContentUnavailableView {
                Label("Marketplace Offline", systemImage: "wifi.slash")
            } description: {
                Text("Reconnect to load this wallpaper.")
            } actions: {
                Button("Try Again", action: onRetry)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t Load Wallpaper", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: onRetry)
            }
        default:
            ContentUnavailableView("Wallpaper Unavailable", systemImage: "photo.badge.exclamationmark")
        }
    }

    private func copyIdentifier(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    @ViewBuilder
    private var actionNotice: some View {
        if case let .succeeded(message) = marketplace.reportState {
            Label(message, systemImage: "checkmark.circle.fill")
                .padding(12)
                .background(.regularMaterial, in: Capsule())
        } else {
            switch marketplace.actionState {
            case .idle:
                EmptyView()
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
            case let .succeeded(message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }
}

private struct WallpaperReportView: View {
    @Environment(\.dismiss) private var dismiss
    let state: WALIMarketplaceActionState
    let submit: (CatalogReportKind, String) -> Void

    @State private var kind: CatalogReportKind = .technicalIssue
    @State private var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Report Wallpaper")
                .font(.title2.weight(.semibold))
            Text("Reports go to WALI reviewers. Do not include passwords, account tokens, or private contact details.")
                .foregroundStyle(.secondary)
            Picker("Reason", selection: $kind) {
                ForEach(CatalogReportKind.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            TextField("What should reviewers know?", text: $detail, axis: .vertical)
                .lineLimit(4...8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(state == .working)
                Button("Submit Report") { submit(kind, detail) }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || detail.count > 2_000
                            || detail.utf8.count > 8_000
                            || state == .working
                    )
            }
            switch state {
            case .working:
                ProgressView("Submitting securely…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .idle, .succeeded:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityIdentifier("WALI.Marketplace.Report")
    }
}
