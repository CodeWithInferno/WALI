import SwiftUI
import WALIUI
import XCTest
@testable import WALIAppRuntime

final class NativePresentationLayoutTests: XCTestCase {
    func testPosterAspectRatioIsPortraitTwoByThree() {
        XCTAssertEqual(WALIPosterLayout.aspectRatio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(WALIPosterLayout.heroAspectRatio, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testNoticeBannersAnchorBottomTrailing() {
        XCTAssertEqual(WALIChromeLayout.noticeAlignment, .bottomTrailing)
        XCTAssertTrue(WALIChromeLayout.noticeShowsDismissControl)
        XCTAssertEqual(WALIChromeLayout.noticeMaxWidth, 400, accuracy: 0.0001)
        XCTAssertEqual(WALIChromeLayout.noticeCornerRadius, 14, accuracy: 0.0001)
        let notice = WALINoticePresentation(
            kind: .warning,
            title: "Desktop Wallpaper Applied",
            message: "Lock Screen continuity could not update."
        )
        XCTAssertEqual(
            notice.dismissalKey,
            "Desktop Wallpaper Applied\u{1e}Lock Screen continuity could not update."
        )
    }

    func testWindowChromeLeavesTheSharedHeaderEmpty() {
        XCTAssertEqual(WALIChromeLayout.searchHome, .sidebar)
        XCTAssertFalse(WALIChromeLayout.showsToolbarUtilityActions)
        XCTAssertFalse(WALIChromeLayout.usesFlexibleToolbarSpacer)
        XCTAssertTrue(WALIChromeLayout.importLivesInSidebar)
        XCTAssertTrue(WALIChromeLayout.hidesTitlebarSeparator)
        XCTAssertFalse(WALIChromeLayout.hidesWindowToolbar)
        XCTAssertTrue(WALIChromeLayout.showsSidebarToggleBesideTrafficLights)
        XCTAssertTrue(WALIChromeLayout.catalogBackLivesBesideSidebarToggle)
        XCTAssertEqual(WALIChromeLayout.catalogBackTitlebarSpacing, 2, accuracy: 0.0001)
        XCTAssertTrue(WALIChromeLayout.usesFullSizeContentTitlebar)
        XCTAssertTrue(WALIChromeLayout.hidesSplitToolbarHandle)
        XCTAssertTrue(WALIChromeLayout.hidesToolbarSharedBackground)
        XCTAssertTrue(WALIChromeLayout.overlaysSidebarOnDetail)
        XCTAssertEqual(WALIChromeLayout.sidebarIdealWidth, 220, accuracy: 0.0001)
    }

    func testDiscoverHeroIsFullBleedEditorialBand() {
        XCTAssertFalse(WALIDiscoverLayout.heroUsesRoundedCardChrome)
        XCTAssertTrue(WALIDiscoverLayout.extendsHeroUnderChrome)
        XCTAssertFalse(WALIDiscoverLayout.usesMirroredBackgroundExtension)
        XCTAssertTrue(WALIDiscoverLayout.heroArtworkFadesToTransparent)
        XCTAssertTrue(WALIDiscoverLayout.hidesTopScrollEdgeEffect)
        XCTAssertFalse(WALIDiscoverLayout.heroFadeLandsOnWindowBackground)
        XCTAssertTrue(WALIDiscoverLayout.heroAmbienceFollowsFeatured)
        XCTAssertEqual(WALIDiscoverLayout.heroViewportFraction, 0.88, accuracy: 0.001)
        XCTAssertGreaterThan(WALIDiscoverLayout.heroFadeStart, 0)
        XCTAssertLessThan(WALIDiscoverLayout.heroFadeStart, 0.5)
        XCTAssertGreaterThan(WALIDiscoverLayout.heroScrimMidOpacity, 0)
        XCTAssertLessThan(WALIDiscoverLayout.heroScrimMidOpacity, 1)
    }

    func testDiscoverHeroCarouselAutoAdvancesUntilReducedMotion() {
        XCTAssertTrue(WALIDiscoverLayout.heroCarouselAutoAdvances)
        XCTAssertEqual(WALIDiscoverLayout.heroCarouselInterval, .seconds(6))
        XCTAssertEqual(WALIDiscoverLayout.heroCarouselAdvanceSeconds, 0.85, accuracy: 0.001)
        XCTAssertTrue(WALIDiscoverLayout.heroCarouselWrapsForward)
        XCTAssertTrue(WALIDiscoverLayout.carouselAdvancesAutomatically(reduceMotion: false))
        XCTAssertFalse(WALIDiscoverLayout.carouselAdvancesAutomatically(reduceMotion: true))
    }

    func testDiscoverCarouselAdvancesForwardWhenWrapping() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(WALIDiscoverLayout.nextLoopingPageID(after: "a", logicalIDs: ids), "b")
        XCTAssertEqual(
            WALIDiscoverLayout.nextLoopingPageID(after: "c", logicalIDs: ids),
            WALIDiscoverLayout.trailingCloneID(for: "a")
        )
        XCTAssertEqual(
            WALIDiscoverLayout.nextLoopingPageID(
                after: WALIDiscoverLayout.trailingCloneID(for: "a"),
                logicalIDs: ids
            ),
            "b"
        )
        XCTAssertEqual(WALIDiscoverLayout.logicalCarouselID(from: "discover-loop-next:a"), "a")
        XCTAssertEqual(
            WALIDiscoverLayout.nextLoopingPageID(
                after: WALIDiscoverLayout.leadingCloneID(for: "c"),
                logicalIDs: ids
            ),
            "a"
        )
        XCTAssertEqual(
            WALIDiscoverLayout.loopingPages(logicalIDs: ids).map(\.id),
            [
                WALIDiscoverLayout.leadingCloneID(for: "c"),
                "a",
                "b",
                "c",
                WALIDiscoverLayout.trailingCloneID(for: "a")
            ]
        )
        XCTAssertEqual(
            WALIDiscoverLayout.pageID(selecting: "a", from: "c", logicalIDs: ids),
            WALIDiscoverLayout.trailingCloneID(for: "a")
        )
        XCTAssertEqual(
            WALIDiscoverLayout.pageID(selecting: "c", from: "a", logicalIDs: ids),
            WALIDiscoverLayout.leadingCloneID(for: "c")
        )
        XCTAssertEqual(WALIDiscoverLayout.pageID(selecting: "b", from: "a", logicalIDs: ids), "b")
        XCTAssertEqual(
            WALIDiscoverLayout.pageID(
                selecting: "a",
                from: WALIDiscoverLayout.trailingCloneID(for: "a"),
                logicalIDs: ids
            ),
            WALIDiscoverLayout.trailingCloneID(for: "a")
        )
        XCTAssertEqual(
            WALIDiscoverLayout.pageID(
                selecting: "a",
                from: WALIDiscoverLayout.leadingCloneID(for: "c"),
                logicalIDs: ids
            ),
            "a"
        )
        XCTAssertEqual(
            WALIDiscoverLayout.pageID(
                selecting: "c",
                from: WALIDiscoverLayout.trailingCloneID(for: "a"),
                logicalIDs: ids
            ),
            "c"
        )
        XCTAssertTrue(
            WALIDiscoverLayout.isValidCarouselPage(
                WALIDiscoverLayout.trailingCloneID(for: "a"),
                logicalIDs: ids
            )
        )
        XCTAssertFalse(WALIDiscoverLayout.isValidCarouselPage("missing", logicalIDs: ids))
    }

    func testDiscoverPosterTilesStayPortraitRoundedCards() {
        XCTAssertEqual(WALIPosterLayout.cornerRadius, 12, accuracy: 0.0001)
        XCTAssertEqual(WALIPosterLayout.aspectRatio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(WALIPosterLayout.rowLockupAspectRatio, 16.0 / 10.0, accuracy: 0.0001)
        XCTAssertEqual(WALIPosterLayout.catalogRowPosterWidth, 168, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.rowGutter, 40, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.rowLockupCount, 3)
        XCTAssertEqual(WALIDiscoverLayout.rowChromeInset, 24, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.heroAmbienceCrossfadeSeconds, 0.9, accuracy: 0.001)
        XCTAssertTrue(WALIDiscoverLayout.rowsBleedUnderSidebar)
        XCTAssertEqual(WALIChromeLayout.sidebarIdealWidth, 220, accuracy: 0.0001)
        XCTAssertEqual(
            WALIChromeLayout.overlayLeadingBleed(columnVisibility: .all),
            220,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIChromeLayout.overlayLeadingBleed(columnVisibility: .detailOnly),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(WALIDiscoverLayout.leadingBleed(reportedSafeArea: 0, overlayFallback: 200), 200)
        XCTAssertEqual(WALIDiscoverLayout.leadingBleed(reportedSafeArea: 220, overlayFallback: 200), 220)
        XCTAssertEqual(
            WALIDiscoverLayout.fullBleedWidth(readerWidth: 1528, leadingBleed: 220),
            1748,
            accuracy: 0.0001
        )
        XCTAssertEqual(WALIDiscoverLayout.originShift(leadingBleed: 220), -220, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.originShift(leadingBleed: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.rowLockupWidth(visibleColumnWidth: 880), 250, accuracy: 0.0001)
        XCTAssertEqual(WALIDiscoverLayout.rowLeadingContentMargin(leadingBleed: 220), 244, accuracy: 0.0001)
    }

    func testDiscoverCarouselGathersUniqueWallpapersAcrossHomeSections() {
        let result = WALIDiscoverLayout.carouselItems(
            from: [
                [CarouselProbe(id: "rick")],
                [CarouselProbe(id: "rick"), CarouselProbe(id: "aurora")],
                [CarouselProbe(id: "forest")]
            ]
        )
        XCTAssertEqual(result.map(\.id), ["rick", "aurora", "forest"])
    }

    func testDiscoverCarouselStopsAtCapacity() {
        let cards = (1...12).map { index in
            CarouselProbe(id: "\(index)")
        }
        XCTAssertEqual(
            WALIDiscoverLayout.carouselItems(from: [cards]).map(\.id),
            (1...WALIDiscoverLayout.heroCarouselCapacity).map(String.init)
        )
    }

    func testDiscoverCarouselIsAComposedHeroAbovePosterRows() {
        XCTAssertEqual(WALIDiscoverLayout.heroSectionID, "discover-carousel")
        XCTAssertEqual(WALIDiscoverLayout.heroSectionLayout, .hero)
        XCTAssertEqual(WALIDiscoverLayout.catalogSectionLayout, .row)
        XCTAssertEqual(WALIDiscoverLayout.heroCarouselCapacity, 8)
    }

    func testAccountAvatarInitialsUseGivenAndFamilyName() {
        XCTAssertEqual(WALIAccountAvatar.initials(from: "Wallpaper Maker"), "WM")
    }

    func testAccountAvatarInitialsUseSingleName() {
        XCTAssertEqual(WALIAccountAvatar.initials(from: "Pratham"), "P")
    }

    func testAccountAvatarInitialsIgnoreBlankNames() {
        XCTAssertEqual(WALIAccountAvatar.initials(from: "   "), "")
    }

    func testLibraryGridFillsTheColumnWithDisplayLockups() {
        XCTAssertEqual(WALILibraryLayout.artworkAspect, 16.0 / 10.0, accuracy: 0.0001)
        XCTAssertEqual(WALILibraryLayout.gutter, 16, accuracy: 0.0001)
        XCTAssertEqual(WALILibraryLayout.minimumColumnCount, 2)
        XCTAssertEqual(WALILibraryLayout.maximumColumnCount, 4)
        XCTAssertEqual(WALILibraryLayout.columnCount(forAvailableWidth: 500), 2)
        XCTAssertEqual(WALILibraryLayout.columnCount(forAvailableWidth: 900), 3)
        XCTAssertEqual(WALILibraryLayout.columnCount(forAvailableWidth: 1_400), 4)
    }

    func testLibraryItemTitleStripsHashPrefixedFilenames() {
        XCTAssertEqual(
            WALILibraryItemTitle.displayName(
                from: "5baac92b81_tanjiro-kamado-crimson-moon-live-wallpaper"
            ),
            "Tanjiro Kamado Crimson Moon Live Wallpaper"
        )
        XCTAssertEqual(
            WALILibraryItemTitle.displayName(from: "Herobrine Minecraft"),
            "Herobrine Minecraft"
        )
        XCTAssertEqual(WALILibraryItemTitle.displayName(from: "   "), "   ")
    }

    func testMarketplaceDetailHeroFillsTheViewportUnderChrome() {
        XCTAssertEqual(WALIMarketplaceDetailLayout.heroViewportFraction, 1.0, accuracy: 0.0001)
        XCTAssertTrue(WALIMarketplaceDetailLayout.extendsHeroUnderChrome)
        XCTAssertTrue(WALIMarketplaceDetailLayout.hidesTopScrollEdgeEffect)
        XCTAssertEqual(WALIMarketplaceDetailLayout.chromeInset, 34, accuracy: 0.0001)
        XCTAssertTrue(WALIMarketplaceDetailLayout.hidesDestinationNavigationHeader)
        XCTAssertTrue(WALIMarketplaceDetailLayout.hidesWindowToolbarBackground)
        XCTAssertEqual(WALIMarketplaceDetailLayout.heroHeight(viewportHeight: 1_000), 1_000, accuracy: 0.0001)
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.heroHeight(viewportHeight: 1_000, topSafeArea: 52),
            1_052,
            accuracy: 0.0001
        )
        XCTAssertEqual(WALIMarketplaceDetailLayout.descriptionLineLimit, 2)
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.chromeTopInset(reportedSafeArea: 0),
            64,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.leadingBleed(reportedSafeArea: 0, overlayFallback: 220),
            220,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.leadingBleed(reportedSafeArea: 220, overlayFallback: 200),
            220,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.chromeLeadingInset(leadingBleed: 220),
            254,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIMarketplaceDetailLayout.chromeLeadingInset(leadingBleed: 0),
            34,
            accuracy: 0.0001
        )
    }

    func testBrowseMasonryUsesNativeAspectAndDenseGutters() {
        XCTAssertEqual(WALIBrowseLayout.gutter, 8, accuracy: 0.0001)
        XCTAssertEqual(WALIBrowseLayout.chromeInset, 20, accuracy: 0.0001)
        XCTAssertEqual(WALIBrowseLayout.minimumColumnCount, 3)
        XCTAssertEqual(WALIBrowseLayout.maximumColumnCount, 6)
        XCTAssertEqual(WALIBrowseLayout.cornerRadius, 12, accuracy: 0.0001)
        XCTAssertEqual(WALIBrowseLayout.columnCount(forAvailableWidth: 400), 3)
        XCTAssertEqual(WALIBrowseLayout.columnCount(forAvailableWidth: 1_200), 6)
        XCTAssertEqual(WALIBrowseLayout.columnCount(forAvailableWidth: 1_800), 6)
    }

    func testBrowseArtworkAspectUsesPosterPixelsAndClampsExtremes() {
        XCTAssertEqual(
            WALIBrowseLayout.artworkAspect(width: 1_920, height: 1_080),
            1_920.0 / 1_080.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIBrowseLayout.artworkAspect(width: 1_000, height: 4_000),
            WALIBrowseLayout.minimumArtworkAspect,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIBrowseLayout.artworkAspect(width: 4_000, height: 100),
            WALIBrowseLayout.maximumArtworkAspect,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WALIBrowseLayout.artworkAspect(width: 0, height: 0),
            WALIBrowseLayout.fallbackArtworkAspect,
            accuracy: 0.0001
        )
    }

    func testBrowseMasonryPacksTheNextTileIntoTheShortestColumn() {
        let packed = WALIBrowseLayout.pack(
            heights: [62.5, 150, 100],
            availableWidth: 208,
            columnCount: 2
        )
        XCTAssertEqual(packed.origins.count, 3)
        XCTAssertEqual(packed.origins[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(packed.origins[0].y, 0, accuracy: 0.0001)
        XCTAssertEqual(packed.origins[1].x, 108, accuracy: 0.0001)
        XCTAssertEqual(packed.origins[1].y, 0, accuracy: 0.0001)
        XCTAssertEqual(packed.origins[2].x, 0, accuracy: 0.0001)
        XCTAssertEqual(packed.origins[2].y, 70.5, accuracy: 0.0001)
        XCTAssertEqual(packed.size.width, 208, accuracy: 0.0001)
        XCTAssertEqual(packed.size.height, 170.5, accuracy: 0.0001)
        XCTAssertEqual(WALIBrowseLayout.shortestColumnIndex(heights: [162.5, 158]), 1)
    }
}

private struct CarouselProbe: Identifiable {
    let id: String
}
