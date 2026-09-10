import SwiftUI

struct MarketplaceUnavailableView: View {
    static let title = "Marketplace Unavailable in This Build"

    var body: some View {
        ContentUnavailableView(
            Self.title,
            systemImage: "sparkles.rectangle.stack",
            description: Text("Discover, accounts, and creator tools are unavailable in this build. You can import and play your own wallpapers from Library.")
        )
        .accessibilityIdentifier("WALI.Marketplace.Unavailable")
    }
}
