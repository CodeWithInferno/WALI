import SwiftUI
import WALICatalogRuntime
import WALIUI

struct BrowseView: View {
    @Bindable var marketplace: WALIMarketplaceModel
    @Binding var sort: CatalogBrowseSort
    let query: String
    let onLoad: (CatalogBrowseSort) -> Void
    let onOpen: (String) -> Void
    let onLoadMore: () -> Void

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !normalizedQuery.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WALIPageHeader(isSearching ? "Search Results" : "Browse") {
                if !isSearching { CatalogFiltersView(sort: $sort) }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { onLoad(sort) }
        .onChange(of: sort) { _, value in onLoad(value) }
        .accessibilityIdentifier("WALI.Marketplace.Browse")
    }

    @ViewBuilder
    private var content: some View {
        switch marketplace.browseState {
        case .idle, .loading:
            ProgressView("Finding wallpapers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            if isSearching {
                ContentUnavailableView.search(text: normalizedQuery)
            } else {
                ContentUnavailableView("No Wallpapers Yet", systemImage: "photo.on.rectangle.angled")
            }
        case .offline:
            ContentUnavailableView {
                Label("Marketplace Offline", systemImage: "wifi.slash")
            } description: {
                Text("Browsing needs a connection; your Library remains available.")
            } actions: {
                Button("Try Again") { onLoad(sort) }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t Load Wallpapers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { onLoad(sort) }
            }
        case .ready:
            GeometryReader { geometry in
                let items = isSearching ? marketplace.searchItems : marketplace.browseItems
                let columnCount = WALIBrowseLayout.columnCount(forAvailableWidth: geometry.size.width)
                ScrollView {
                    WALIMasonryLayout(columnCount: columnCount, gutter: WALIBrowseLayout.gutter) {
                        ForEach(items) { card in
                            BrowseBentoTile(card: card) { onOpen(card.id) }
                                .onAppear {
                                    if card.id == items.last?.id { onLoadMore() }
                                }
                        }
                    }
                    .padding(.horizontal, WALIBrowseLayout.chromeInset)
                    .padding(.bottom, 24)
                    if let message = marketplace.browsePageError {
                        HStack {
                            Text(message).foregroundStyle(.secondary)
                            Button("Try Again", action: onLoadMore)
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}

struct CatalogFiltersView: View {
    @Binding var sort: CatalogBrowseSort

    var body: some View {
        Picker("Sort", selection: $sort) {
            Text("Featured").tag(CatalogBrowseSort.featured)
            Text("Trending").tag(CatalogBrowseSort.trending)
            Text("Newest").tag(CatalogBrowseSort.newest)
            Text("Most Installed").tag(CatalogBrowseSort.mostInstalled)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("WALI.Marketplace.Sort")
    }
}

struct CatalogSearchView: View {
    let results: [WALICatalogCardPresentation]
    let query: String
    let onOpen: (String) -> Void

    var body: some View {
        ForEach(results) { card in
            CatalogCardView(card: card) { onOpen(card.id) }
                .accessibilityHint("Opens details for \(card.title)")
        }
        .accessibilityLabel("Search results for \(query)")
    }
}

struct BrowseBentoTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: WALICatalogCardPresentation
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showsPreview = false

    private var artworkAspect: CGFloat {
        WALIBrowseLayout.artworkAspect(width: card.pixelWidth, height: card.pixelHeight)
    }

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(artworkAspect, contentMode: .fit)
                .overlay {
                    posterMedia
                }
                .overlay(alignment: .bottom) {
                    if isHovering {
                        hoverCaption
                    }
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: WALIBrowseLayout.cornerRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: WALIBrowseLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            guard !reduceMotion else { return }
            if hovering {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard isHovering else { return }
                    showsPreview = true
                }
            } else {
                showsPreview = false
            }
        }
        .accessibilityLabel("\(card.title), published by \(card.creator), \(card.verifiedInstallCount) verified installs")
    }

    private var hoverCaption: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 88)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Published by \(card.creator)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var posterMedia: some View {
        if showsPreview, !reduceMotion, let previewURL = card.previewURL {
            LoopingVideoView(url: previewURL, cornerRadius: WALIBrowseLayout.cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let posterURL = card.posterURL {
            AsyncImage(url: posterURL, transaction: .init(animation: .smooth)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    posterPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

struct CatalogCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: WALICatalogCardPresentation
    var artworkAspect: CGFloat = WALIPosterLayout.aspectRatio
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showsPreview = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .aspectRatio(artworkAspect, contentMode: .fit)
                        .overlay {
                            posterMedia
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: WALIPosterLayout.cornerRadius, style: .continuous)
                        )
                        .clipped()

                    Label(
                        card.verifiedInstallCount.formatted(.number.notation(.compactName)),
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Published by \(card.creator)  ·  \(card.category)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            guard !reduceMotion else { return }
            if hovering {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard isHovering else { return }
                    showsPreview = true
                }
            } else {
                showsPreview = false
            }
        }
        .accessibilityLabel("\(card.title), published by \(card.creator), \(card.verifiedInstallCount) verified installs")
    }

    @ViewBuilder
    private var posterMedia: some View {
        if showsPreview, !reduceMotion, let previewURL = card.previewURL {
            LoopingVideoView(url: previewURL, cornerRadius: WALIPosterLayout.cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let posterURL = card.posterURL {
            AsyncImage(url: posterURL, transaction: .init(animation: .smooth)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    posterPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}
