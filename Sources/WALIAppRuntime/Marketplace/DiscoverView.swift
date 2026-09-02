import SwiftUI
import WALIUI

struct DiscoverView: View {
    @Bindable var marketplace: WALIMarketplaceModel
    let onRetry: () -> Void
    let onOpen: (String) -> Void

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        ForEach(marketplace.homeSections) { section in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(section.title)
                                    .font(.title2.weight(.semibold))
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: 16) {
                                        ForEach(section.cards) { card in
                                            CatalogCardView(card: card) { onOpen(card.id) }
                                                .frame(width: 310)
                                        }
                                    }
                                    .scrollTargetLayout()
                                }
                                .scrollIndicators(.hidden)
                                .scrollTargetBehavior(.viewAligned)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WALI.Marketplace.Discover")
    }
}
