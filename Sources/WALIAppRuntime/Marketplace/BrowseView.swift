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

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18, alignment: .top)
    ]

    var body: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ContentUnavailableView.search(text: query)
        case .offline:
            ContentUnavailableView(
                "Marketplace Offline",
                systemImage: "wifi.slash",
                description: Text("Browsing needs a connection; your Library remains available.")
            )
        case let .failed(message):
            ContentUnavailableView(
                "Couldn’t Load Wallpapers",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .ready:
            ScrollView {
                let items = query.isEmpty ? marketplace.browseItems : marketplace.searchItems
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(items) { card in
                        CatalogCardView(card: card) { onOpen(card.id) }
                            .onAppear {
                                if card.id == items.last?.id { onLoadMore() }
                            }
                    }
                }
                .padding(24)
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

struct CatalogCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: WALICatalogCardPresentation
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showsPreview = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if showsPreview, !reduceMotion, let previewURL = card.previewURL {
                            LoopingVideoView(url: previewURL, cornerRadius: 14)
                        } else if let posterURL = card.posterURL {
                            AsyncImage(url: posterURL, transaction: .init(animation: .smooth)) { phase in
                                switch phase {
                                case let .success(image):
                                    image.resizable().scaledToFill()
                                default:
                                    Rectangle()
                                        .fill(.quaternary)
                                        .overlay {
                                            Image(systemName: "photo.on.rectangle.angled")
                                                .font(.title2)
                                                .foregroundStyle(.tertiary)
                                        }
                                }
                            }
                        } else {
                            Rectangle()
                                .fill(.quaternary)
                                .overlay {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Label(
                        card.verifiedInstallCount.formatted(.number.notation(.compactName)),
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(card.creator)  ·  \(card.category)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .accessibilityLabel("\(card.title), by \(card.creator), \(card.verifiedInstallCount) verified installs")
    }
}
