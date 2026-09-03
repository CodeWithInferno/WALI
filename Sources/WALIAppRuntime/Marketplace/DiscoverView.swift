import AppKit
import SwiftUI
import WALIUI

struct DiscoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.waliOverlayLeadingBleed) private var overlayLeadingBleed

    @Bindable var marketplace: WALIMarketplaceModel
    let onRetry: () -> Void
    let onOpen: (String) -> Void

    @State private var featuredID: String?
    @State private var isCarouselPaused = false

    var body: some View {
        Group {
            switch marketplace.homeState {
            case .idle, .loading:
                ProgressView("Loading Discover…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "Marketplace Coming Online",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Published wallpapers will appear here as the catalog is populated.")
                )
            case .offline:
                ContentUnavailableView {
                    Label("Marketplace Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Your installed wallpapers still work. Reconnect to browse new ones.")
                } actions: {
                    Button("Try Again", action: onRetry)
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Load Discover", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: onRetry)
                }
            case .ready:
                readyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WALI.Marketplace.Discover")
    }

    private var readyContent: some View {
        GeometryReader { geometry in
            let reportedSafeArea = geometry.safeAreaInsets.leading
            let leadingBleed = WALIDiscoverLayout.extendsHeroUnderChrome
                ? WALIDiscoverLayout.leadingBleed(
                    reportedSafeArea: reportedSafeArea,
                    overlayFallback: overlayLeadingBleed
                )
                : 0
            let fullWidth = geometry.size.width
            let columnWidth = max(0, fullWidth - leadingBleed)
            ZStack(alignment: .top) {
                DiscoverAmbientWash(posterURL: featuredPosterURL)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(marketplace.homeSections.enumerated()), id: \.element.id) { index, section in
                            DiscoverSectionView(
                                section: section,
                                featuredID: $featuredID,
                                heroHeight: geometry.size.height * WALIDiscoverLayout.heroViewportFraction,
                                fullWidth: fullWidth,
                                columnWidth: columnWidth,
                                leadingBleed: leadingBleed,
                                followsHero: index > 0 && marketplace.homeSections[index - 1].layout == .hero,
                                onCarouselHover: { isCarouselPaused = $0 },
                                onOpen: onOpen
                            )
                        }
                    }
                    .frame(width: fullWidth, alignment: .leading)
                    .padding(.bottom, 28)
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.all, 0, for: .scrollContent)
                .scrollClipDisabled(WALIDiscoverLayout.rowsBleedUnderSidebar)
                .waliHiddenTopScrollEdge(WALIDiscoverLayout.hidesTopScrollEdgeEffect)
                .ignoresSafeArea(edges: [.top, .leading])
            }
        }
        .ignoresSafeArea(edges: [.top, .leading])
        .onAppear(perform: seedFeaturedID)
        .onChange(of: marketplace.homeSections) { _, _ in
            seedFeaturedID()
        }
        .task(id: carouselTaskID) {
            await runCarousel()
        }
    }

    private var heroSection: WALICatalogSectionPresentation? {
        marketplace.homeSections.first { section in
            section.layout == .hero
        }
    }

    private var heroIDs: [String] {
        heroSection?.cards.map(\.id) ?? []
    }

    private var featuredPosterURL: URL? {
        guard WALIDiscoverLayout.heroAmbienceFollowsFeatured else { return nil }
        return heroSection?.cards.first { card in
            card.id == featuredID.map(WALIDiscoverLayout.logicalCarouselID)
        }?.posterURL ?? heroSection?.cards.first?.posterURL
    }

    private var carouselTaskID: String {
        "\(reduceMotion)-\(heroIDs.joined(separator: ","))"
    }

    private func seedFeaturedID() {
        let ids = heroIDs
        if WALIDiscoverLayout.isValidCarouselPage(featuredID, logicalIDs: ids) == false {
            featuredID = ids.first
        }
    }

    private func runCarousel() async {
        guard WALIDiscoverLayout.carouselAdvancesAutomatically(reduceMotion: reduceMotion) else { return }
        guard heroIDs.count > 1 else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: WALIDiscoverLayout.heroCarouselInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if isCarouselPaused { continue }
            featuredID = WALIDiscoverLayout.nextLoopingPageID(after: featuredID, logicalIDs: heroIDs)
        }
    }
}

private struct DiscoverSectionView: View {
    let section: WALICatalogSectionPresentation
    @Binding var featuredID: String?
    let heroHeight: CGFloat
    let fullWidth: CGFloat
    let columnWidth: CGFloat
    let leadingBleed: CGFloat
    let followsHero: Bool
    let onCarouselHover: (Bool) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        if section.layout == .hero {
            DiscoverHeroBand(
                section: section,
                featuredID: $featuredID,
                leadingBleed: leadingBleed,
                onCarouselHover: onCarouselHover,
                onOpen: onOpen
            )
            .frame(width: fullWidth, height: max(heroHeight, 420), alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                    .padding(.leading, WALIDiscoverLayout.rowLeadingContentMargin(leadingBleed: leadingBleed))
                    .padding(.trailing, WALIDiscoverLayout.rowChromeInset)
                posterRow
            }
            .padding(.top, followsHero ? -36 : 28)
            .frame(width: fullWidth, alignment: .leading)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private var posterRow: some View {
        let lockupWidth = WALIDiscoverLayout.rowLockupWidth(visibleColumnWidth: columnWidth)
        let restInset = WALIDiscoverLayout.rowLeadingContentMargin(leadingBleed: leadingBleed)
        return ScrollView(.horizontal) {
            HStack(spacing: WALIDiscoverLayout.rowGutter) {
                ForEach(section.cards) { card in
                    CatalogCardView(
                        card: card,
                        artworkAspect: WALIPosterLayout.rowLockupAspectRatio
                    ) { onOpen(card.id) }
                        .frame(width: lockupWidth, alignment: .top)
                }
            }
            .padding(.leading, restInset)
            .padding(.trailing, WALIDiscoverLayout.rowChromeInset)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled(WALIDiscoverLayout.rowsBleedUnderSidebar)
    }
}

private enum DiscoverSurface {
    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

private struct DiscoverAmbientWash: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let posterURL: URL?
    @State private var currentURL: URL?
    @State private var previousURL: URL?

    private var allowsAmbience: Bool {
        WALIDiscoverLayout.heroAmbienceFollowsFeatured
            && !reduceTransparency
            && colorSchemeContrast != .increased
    }

    var body: some View {
        ZStack {
            DiscoverSurface.background
            if allowsAmbience {
                if let previousURL {
                    washImage(previousURL)
                        .id("ambient-back-\(previousURL.absoluteString)")
                }
                if let currentURL {
                    washImage(currentURL)
                        .id("ambient-front-\(currentURL.absoluteString)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            currentURL = posterURL
        }
        .onChange(of: posterURL) { _, newURL in
            previousURL = currentURL
            currentURL = newURL
            if reduceMotion || allowsAmbience == false {
                previousURL = nil
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: WALIDiscoverLayout.heroAmbienceCrossfadeSeconds),
            value: currentURL
        )
    }

    private func washImage(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 78)
                    .scaleEffect(1.2)
            default:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            Color.black.opacity(colorScheme == .dark ? 0.5 : 0.16)
        }
        .overlay {
            DiscoverSurface.background.opacity(colorScheme == .dark ? 0.2 : 0.5)
        }
        .clipped()
        .transition(.opacity)
    }
}

private struct DiscoverHeroBand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let section: WALICatalogSectionPresentation
    @Binding var featuredID: String?
    let leadingBleed: CGFloat
    let onCarouselHover: (Bool) -> Void
    let onOpen: (String) -> Void
    @State private var loopSettleGeneration = 0

    private var featuredLogicalID: String? {
        featuredID.map(WALIDiscoverLayout.logicalCarouselID)
    }

    private var featuredCard: WALICatalogCardPresentation? {
        section.cards.first { card in
            card.id == featuredLogicalID
        } ?? section.cards.first
    }

    private var loopingPages: [WALIDiscoverCarouselPage] {
        WALIDiscoverLayout.loopingPages(logicalIDs: section.cards.map(\.id))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            artworkPages
                .mask(alignment: .center) {
                    artworkDissolve
                }
            fade
            chrome
        }
        .onHover { hovering in
            onCarouselHover(hovering)
        }
        .onAppear {
            if featuredID == nil {
                featuredID = section.cards.first?.id
            }
        }
        .onChange(of: section.cards) { _, cards in
            let logicalIDs = cards.map(\.id)
            let logical = featuredLogicalID
            if logical == nil || logical.map(logicalIDs.contains) != true {
                featuredID = cards.first?.id
            }
        }
        .onChange(of: featuredID) { _, newID in
            settleForwardLoopIfNeeded(newID)
        }
    }

    private func settleForwardLoopIfNeeded(_ pageID: String?) {
        guard let pageID, WALIDiscoverLayout.isLoopClone(pageID) else { return }
        let settled = WALIDiscoverLayout.logicalCarouselID(from: pageID)
        loopSettleGeneration += 1
        let generation = loopSettleGeneration
        Task { @MainActor in
            try? await Task.sleep(for: WALIDiscoverLayout.heroCarouselAdvanceDuration + .milliseconds(80))
            guard loopSettleGeneration == generation else { return }
            guard featuredID == pageID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                featuredID = settled
            }
        }
    }

    private var artworkPages: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(loopingPages) { page in
                    if let card = section.cards.first(where: { $0.id == page.logicalID }) {
                        Button {
                            onOpen(card.id)
                        } label: {
                            heroArtwork(card)
                        }
                        .buttonStyle(.plain)
                        .containerRelativeFrame(.horizontal)
                        .id(page.id)
                        .accessibilityLabel("\(card.title), by \(card.creator)")
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $featuredID)
        .animation(
            reduceMotion ? nil : .smooth(duration: WALIDiscoverLayout.heroCarouselAdvanceSeconds),
            value: featuredID
        )
    }

    private var artworkDissolve: some View {
        LinearGradient(
            stops: WALIDiscoverLayout.heroArtworkFadesToTransparent
                ? [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: WALIDiscoverLayout.heroFadeStart),
                    .init(color: .black.opacity(0.45), location: 0.78),
                    .init(color: .clear, location: 1)
                ]
                : [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: WALIDiscoverLayout.heroFadeStart),
                .init(
                    color: .black.opacity(WALIDiscoverLayout.heroScrimMidOpacity),
                    location: 0.7
                ),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 16) {
                if let featuredCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.86))
                        Text(featuredCard.title)
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(2)
                        Text("\(featuredCard.creator)  ·  \(featuredCard.category)")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
                    .contentTransition(.opacity)
                    .frame(minHeight: 84, alignment: .bottomLeading)
                }
                Spacer(minLength: 12)
                if let featuredCard {
                    viewButton(featuredCard)
                }
            }
            if section.cards.count > 1 {
                pageIndicator
            }
        }
        .padding(.leading, 28 + leadingBleed)
        .padding(.trailing, 28)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    @ViewBuilder
    private func viewButton(_ card: WALICatalogCardPresentation) -> some View {
        let button = Button("View Wallpaper") {
            onOpen(card.id)
        }
        .controlSize(.large)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(section.cards) { card in
                Button {
                    featuredID = WALIDiscoverLayout.pageID(
                        selecting: card.id,
                        from: featuredID,
                        logicalIDs: section.cards.map(\.id)
                    )
                } label: {
                    Circle()
                        .fill(.white.opacity(card.id == featuredCard?.id ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.title)
                .accessibilityAddTraits(card.id == featuredCard?.id ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured wallpapers")
    }

    @ViewBuilder
    private func heroArtwork(_ card: WALICatalogCardPresentation) -> some View {
        artworkFill(card)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    @ViewBuilder
    private func artworkFill(_ card: WALICatalogCardPresentation) -> some View {
        if !reduceMotion, let previewURL = card.previewURL {
            LoopingVideoView(
                url: previewURL,
                cornerRadius: 0,
                fadesOutAtBottom: WALIDiscoverLayout.heroArtworkFadesToTransparent
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let posterURL = card.posterURL {
            AsyncImage(url: posterURL, transaction: .init(animation: .smooth)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    DiscoverSurface.background
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiscoverSurface.background
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

