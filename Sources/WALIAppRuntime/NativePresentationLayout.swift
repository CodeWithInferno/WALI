import Foundation
import SwiftUI
import WALIUI

/// Shared poster metrics for Discover lockups and catalog cards.
/// Library uses `WALILibraryLayout`. Browse uses `WALIBrowseLayout`.
enum WALIPosterLayout {
    static let aspectRatio: CGFloat = 2.0 / 3.0
    static let heroAspectRatio: CGFloat = 16.0 / 9.0
    /// Discover shelves match a Mac display, not a movie-poster crop.
    static let rowLockupAspectRatio: CGFloat = 16.0 / 10.0
    static let catalogRowPosterWidth: CGFloat = 168
    static let catalogGridMinimum: CGFloat = 140
    static let catalogGridMaximum: CGFloat = 196
    static let cornerRadius: CGFloat = 12
}

/// Library is a display-shaped grid that fills the column, not a 2:3 movie-poster strip.
enum WALILibraryLayout {
    static let gutter: CGFloat = 16
    static let chromeInset: CGFloat = 24
    static let minimumColumnWidth: CGFloat = 240
    static let maximumColumnCount = 4
    static let minimumColumnCount = 2
    static let artworkAspect: CGFloat = 16.0 / 10.0
    static let cornerRadius: CGFloat = 12

    static func columnCount(forAvailableWidth width: CGFloat) -> Int {
        let usable = max(minimumColumnWidth, width - chromeInset * 2)
        let counted = Int(floor((usable + gutter) / (minimumColumnWidth + gutter)))
        return min(maximumColumnCount, max(minimumColumnCount, counted))
    }
}

/// Import names often arrive as hash-prefixed filenames. Library shows a readable title.
enum WALILibraryItemTitle {
    static func displayName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        let hexCount = trimmed.prefix(while: \.isHexDigit).count
        guard hexCount >= 8, hexCount < trimmed.count else { return trimmed }
        let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: hexCount)
        let separator = trimmed[separatorIndex]
        guard separator == "_" || separator == "-" else { return trimmed }
        let rest = trimmed[trimmed.index(after: separatorIndex)...]
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let words = rest.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { return trimmed }
        return words.map(\.localizedCapitalized).joined(separator: " ")
    }
}

/// Browse is a VSCO-style masonry of native-aspect artwork, not a 2:3 poster grid.
enum WALIBrowseLayout {
    static let gutter: CGFloat = 8
    static let chromeInset: CGFloat = 20
    static let minimumColumnWidth: CGFloat = 168
    static let maximumColumnCount = 6
    static let minimumColumnCount = 3
    static let cornerRadius: CGFloat = 12
    static let minimumArtworkAspect: CGFloat = 0.55
    static let maximumArtworkAspect: CGFloat = 2.2
    static let fallbackArtworkAspect: CGFloat = 16.0 / 10.0

    static func columnCount(forAvailableWidth width: CGFloat) -> Int {
        let usable = max(minimumColumnWidth, width - chromeInset * 2)
        let counted = Int(floor((usable + gutter) / (minimumColumnWidth + gutter)))
        return min(maximumColumnCount, max(minimumColumnCount, counted))
    }

    static func artworkAspect(width: UInt32, height: UInt32) -> CGFloat {
        guard width > 0, height > 0 else { return fallbackArtworkAspect }
        let ratio = CGFloat(width) / CGFloat(height)
        return min(maximumArtworkAspect, max(minimumArtworkAspect, ratio))
    }

    static func shortestColumnIndex(heights: [CGFloat]) -> Int {
        heights.enumerated().min { left, right in
            if left.element == right.element { return left.offset < right.offset }
            return left.element < right.element
        }?.offset ?? 0
    }

    static func columnWidth(forAvailableWidth width: CGFloat, columnCount: Int) -> CGFloat {
        let gutters = gutter * CGFloat(max(0, columnCount - 1))
        return max(1, (width - gutters) / CGFloat(max(1, columnCount)))
    }

    static func pack(
        heights: [CGFloat],
        availableWidth: CGFloat,
        columnCount: Int
    ) -> (origins: [CGPoint], size: CGSize) {
        let columns = max(1, columnCount)
        let width = columnWidth(forAvailableWidth: availableWidth, columnCount: columns)
        var columnHeights = Array(repeating: CGFloat(0), count: columns)
        var origins: [CGPoint] = []
        origins.reserveCapacity(heights.count)
        for height in heights {
            let index = shortestColumnIndex(heights: columnHeights)
            origins.append(CGPoint(x: CGFloat(index) * (width + gutter), y: columnHeights[index]))
            columnHeights[index] += height + gutter
        }
        let tallest = columnHeights.max() ?? 0
        let totalHeight = heights.isEmpty ? 0 : max(0, tallest - gutter)
        return (origins, CGSize(width: availableWidth, height: totalHeight))
    }
}

struct WALIMasonryLayout: Layout {
    var columnCount: Int
    var gutter: CGFloat = WALIBrowseLayout.gutter

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let packed = WALIBrowseLayout.pack(
            heights: tileHeights(subviews: subviews, availableWidth: width),
            availableWidth: width,
            columnCount: columnCount
        )
        return packed.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let packed = WALIBrowseLayout.pack(
            heights: tileHeights(subviews: subviews, availableWidth: bounds.width),
            availableWidth: bounds.width,
            columnCount: columnCount
        )
        let columnWidth = WALIBrowseLayout.columnWidth(
            forAvailableWidth: bounds.width,
            columnCount: max(1, columnCount)
        )
        for (subview, origin) in zip(subviews, packed.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: columnWidth, height: nil)
            )
        }
    }

    private func tileHeights(subviews: Subviews, availableWidth: CGFloat) -> [CGFloat] {
        let columnWidth = WALIBrowseLayout.columnWidth(
            forAvailableWidth: availableWidth,
            columnCount: max(1, columnCount)
        )
        return subviews.map { subview in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
    }
}

/// Window chrome that must stay put as the selected sidebar page changes.
/// The shared content header stays empty; search and import live in the sidebar.
enum WALIChromeLayout {
    enum SearchHome: Equatable {
        case sidebar
    }

    static let noticeAlignment: Alignment = .bottomTrailing
    static let noticeMaxWidth: CGFloat = 400
    static let noticeCornerRadius: CGFloat = 14
    static let noticeShowsDismissControl = true
    static let searchHome: SearchHome = .sidebar
    static let showsToolbarUtilityActions = false
    static let usesFlexibleToolbarSpacer = false
    static let importLivesInSidebar = true
    static let hidesTitlebarSeparator = true
    /// Hiding the window toolbar splits traffic lights into a separate titlebar
    /// and drops the sidebar so it no longer runs under them.
    static let hidesWindowToolbar = false
    static let showsSidebarToggleBesideTrafficLights = true
    /// Marketplace wallpaper detail puts Back in that same titlebar item row.
    static let catalogBackLivesBesideSidebarToggle = true
    static let catalogBackTitlebarSpacing: CGFloat = 2
    /// Content may draw under the unified titlebar; Liquid Glass sits on top.
    static let usesFullSizeContentTitlebar = true
    /// The split-view tracking separator is the vertical glass capsule in the
    /// unified titlebar. Hide it; the sidebar toggle still collapses the column.
    static let hidesSplitToolbarHandle = true
    /// WWDC 25: `sharedBackgroundVisibility(.hidden)` removes the Liquid Glass
    /// grouping behind a toolbar item so it is not drawn as its own capsule.
    static let hidesToolbarSharedBackground = true
    /// macOS 26: overlay the sidebar on the detail item so artwork can sit
    /// under the glass instead of being mirrored beside it.
    static let overlaysSidebarOnDetail = true
    /// Matches `navigationSplitViewColumnWidth(ideal:)` when the overlay
    /// sidebar does not publish a leading safe-area inset.
    static let sidebarIdealWidth: CGFloat = 220

    static func overlayLeadingBleed(columnVisibility: NavigationSplitViewVisibility) -> CGFloat {
        guard overlaysSidebarOnDetail else { return 0 }
        if columnVisibility == .detailOnly { return 0 }
        return sidebarIdealWidth
    }

    static var searchFieldPlacement: SearchFieldPlacement {
        switch searchHome {
        case .sidebar:
            .sidebar
        }
    }
}

private struct WALIOverlayLeadingBleedKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var waliOverlayLeadingBleed: CGFloat {
        get { self[WALIOverlayLeadingBleedKey.self] }
        set { self[WALIOverlayLeadingBleedKey.self] = newValue }
    }
}

enum WALIDiscoverLayout {
    /// Fraction of the Discover column height occupied by the editorial hero.
    static let heroViewportFraction: CGFloat = 0.88
    /// Where the hero artwork starts dissolving, as a fraction of the hero height.
    static let heroFadeStart: CGFloat = 0.48
    /// Mid-scrim darkness over the artwork for title contrast.
    static let heroScrimMidOpacity: CGFloat = 0.38
    static let heroUsesRoundedCardChrome = false
    static let extendsHeroUnderChrome = true
    /// Mirrored `backgroundExtensionEffect` copies look like a reflection, not glass.
    static let usesMirroredBackgroundExtension = false
    /// The artwork itself fades to transparent so the page wash shows through.
    static let heroArtworkFadesToTransparent = true
    /// macOS 26 scroll-edge material is a dark strip between titlebar and artwork.
    static let hidesTopScrollEdgeEffect = true
    /// The hero dissolve reveals the featured-wallpaper wash, not a flat window fill.
    static let heroFadeLandsOnWindowBackground = false
    static let heroAmbienceFollowsFeatured = true
    static let heroCarouselAutoAdvances = true
    static let heroCarouselInterval: Duration = .seconds(6)
    static let heroCarouselAdvanceDuration: Duration = .milliseconds(850)
    static let heroCarouselAdvanceSeconds: TimeInterval = 0.85
    static let heroCarouselWrapsForward = true
    static let heroCarouselCapacity = 8
    static let heroAmbienceCrossfadeSeconds: TimeInterval = 0.9
    static let heroSectionID = "discover-carousel"
    static let heroSectionTitle = "Featured"
    static let heroSectionLayout: WALICatalogSectionLayout = .hero
    static let catalogSectionLayout: WALICatalogSectionLayout = .row
    /// Collection titles and the first lockup rest after the overlay sidebar.
    static let rowChromeInset: CGFloat = 24
    /// WWDC 24 media shelves: 40 pt between lockups.
    static let rowGutter: CGFloat = 40
    /// Landscape lockups: three fill the visible column, the next peeks on scroll.
    static let rowLockupCount = 3
    /// Horizontal rows keep scrolling under the glass after that rest inset.
    static let rowsBleedUnderSidebar = true

    static func leadingBleed(reportedSafeArea: CGFloat, overlayFallback: CGFloat) -> CGFloat {
        reportedSafeArea > 1 ? reportedSafeArea : overlayFallback
    }

    static func fullBleedWidth(readerWidth: CGFloat, leadingBleed: CGFloat) -> CGFloat {
        readerWidth + max(0, leadingBleed)
    }

    /// Pull the page left under the overlay sidebar. Rest insets on titles and
    /// lockups then place the first card after the glass.
    static func originShift(leadingBleed: CGFloat) -> CGFloat {
        rowsBleedUnderSidebar && leadingBleed > 1 ? -leadingBleed : 0
    }

    static func rowLockupWidth(visibleColumnWidth: CGFloat) -> CGFloat {
        let count = CGFloat(rowLockupCount)
        let usable = max(0, visibleColumnWidth - rowChromeInset * 2)
        let gutters = rowGutter * (count - 1)
        guard usable > gutters else { return 0 }
        return ((usable - gutters) / count).rounded(.down)
    }

    static func rowLeadingContentMargin(leadingBleed: CGFloat) -> CGFloat {
        (rowsBleedUnderSidebar ? max(0, leadingBleed) : 0) + rowChromeInset
    }

    static func carouselItems<Item: Identifiable>(
        from sections: [[Item]],
        capacity: Int = heroCarouselCapacity
    ) -> [Item] where Item.ID == String {
        var seen: Set<String> = []
        var items: [Item] = []
        for section in sections {
            for item in section {
                guard seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count == capacity { return items }
            }
        }
        return items
    }

    static func carouselAdvancesAutomatically(reduceMotion: Bool) -> Bool {
        heroCarouselAutoAdvances && !reduceMotion
    }

    static func trailingCloneID(for logicalID: String) -> String {
        "discover-loop-next:\(logicalID)"
    }

    static func leadingCloneID(for logicalID: String) -> String {
        "discover-loop-prev:\(logicalID)"
    }

    static func logicalCarouselID(from pageID: String) -> String {
        if let logical = pageID.stripPrefix("discover-loop-next:") {
            return logical
        }
        if let logical = pageID.stripPrefix("discover-loop-prev:") {
            return logical
        }
        return pageID
    }

    static func isLoopClone(_ pageID: String) -> Bool {
        pageID.hasPrefix("discover-loop-next:") || pageID.hasPrefix("discover-loop-prev:")
    }

    static func loopingPages(logicalIDs: [String]) -> [WALIDiscoverCarouselPage] {
        guard let first = logicalIDs.first, let last = logicalIDs.last, logicalIDs.count > 1 else {
            return logicalIDs.map { id in
                WALIDiscoverCarouselPage(id: id, logicalID: id)
            }
        }
        return [WALIDiscoverCarouselPage(id: leadingCloneID(for: last), logicalID: last)]
            + logicalIDs.map { id in
                WALIDiscoverCarouselPage(id: id, logicalID: id)
            }
            + [WALIDiscoverCarouselPage(id: trailingCloneID(for: first), logicalID: first)]
    }

    static func isValidCarouselPage(_ pageID: String?, logicalIDs: [String]) -> Bool {
        guard let pageID else { return false }
        return logicalIDs.contains(logicalCarouselID(from: pageID))
    }

    static func nextLoopingPageID(after current: String?, logicalIDs: [String]) -> String? {
        guard let first = logicalIDs.first else { return nil }
        guard logicalIDs.count > 1 else { return first }
        if let current, current.hasPrefix("discover-loop-next:") {
            return logicalIDs[1]
        }
        if let current, current.hasPrefix("discover-loop-prev:") {
            return first
        }
        let logical = current.map(logicalCarouselID) ?? first
        guard let index = logicalIDs.firstIndex(of: logical) else { return first }
        if index == logicalIDs.count - 1 {
            return trailingCloneID(for: first)
        }
        return logicalIDs[index + 1]
    }

    /// Dots jump to a logical card. Last→first and first→last keep traveling
    /// through the clone so the strip does not rewind.
    static func pageID(selecting logicalID: String, from current: String?, logicalIDs: [String]) -> String {
        guard heroCarouselWrapsForward,
              logicalIDs.count > 1,
              let first = logicalIDs.first,
              let last = logicalIDs.last
        else { return logicalID }
        guard let current else { return logicalID }
        let currentLogical = logicalCarouselID(from: current)
        if logicalID == currentLogical {
            return current
        }
        if logicalID == first, currentLogical == last {
            return current == leadingCloneID(for: last) ? first : trailingCloneID(for: first)
        }
        if logicalID == last, currentLogical == first {
            return current == trailingCloneID(for: first) ? last : leadingCloneID(for: last)
        }
        return logicalID
    }
}

struct WALIDiscoverCarouselPage: Identifiable, Equatable {
    let id: String
    let logicalID: String
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

enum WALIMarketplaceDetailLayout {
    /// First screen is the wallpaper itself: full window, including chrome.
    static let heroViewportFraction: CGFloat = 1.0
    static let extendsHeroUnderChrome = true
    static let hidesTopScrollEdgeEffect = true
    /// NavigationStack’s destination header is a solid strip above the hero.
    static let hidesDestinationNavigationHeader = true
    static let chromeInset: CGFloat = 34
    static let chromeBottomInset: CGFloat = 36
    static let descriptionLineLimit = 2
    static let titlebarFallback: CGFloat = 52
    static let backButtonTopPadding: CGFloat = 12
    /// The unified toolbar must not paint an opaque strip over the hero.
    static let hidesWindowToolbarBackground = true

    static func leadingBleed(reportedSafeArea: CGFloat, overlayFallback: CGFloat) -> CGFloat {
        guard extendsHeroUnderChrome else { return 0 }
        return reportedSafeArea > 1 ? reportedSafeArea : overlayFallback
    }

    static func heroHeight(viewportHeight: CGFloat, topSafeArea: CGFloat = 0) -> CGFloat {
        let extra = extendsHeroUnderChrome ? max(0, topSafeArea) : 0
        return max(0, viewportHeight * heroViewportFraction + extra)
    }

    static func chromeLeadingInset(leadingBleed: CGFloat) -> CGFloat {
        (extendsHeroUnderChrome ? max(0, leadingBleed) : 0) + chromeInset
    }

    static func chromeTopInset(reportedSafeArea: CGFloat) -> CGFloat {
        (reportedSafeArea > 1 ? reportedSafeArea : titlebarFallback) + backButtonTopPadding
    }
}

enum WALIAccountAvatar {
    /// Settings-style monogram: first letters of the first two name parts.
    static func initials(from displayName: String) -> String {
        let parts = displayName.split { character in
            character.isWhitespace || character.isPunctuation
        }
        let letters = parts.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}

extension View {
    @ViewBuilder
    func waliHiddenTopScrollEdge(_ hidden: Bool) -> some View {
        if #available(macOS 26.0, *), hidden {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func waliHiddenWindowToolbarBackground(_ hidden: Bool) -> some View {
        if hidden {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
