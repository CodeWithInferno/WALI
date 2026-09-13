import Foundation
import XCTest
import WALICatalog
@testable import WALICatalogRuntime

@MainActor
final class CreatorBlockingCatalogGatewayTests: XCTestCase {
    private let blocked = "11111111-1111-4111-8111-111111111111"
    private let visible = "22222222-2222-4222-8222-222222222222"

    func testAnonymousHomeBrowseSearchAndRelatedFilterBeforeHydration() async throws {
        let hidden = summary(creator: blocked), shown = summary(creator: visible)
        let base = BlockingCatalogProbe(items: [hidden, shown])
        let model = CreatorBlockingModel(gateway: nil, anonymousStore: GatewayAnonymousBlocks([blocked]))
        let gateway = CreatorBlockingCatalogGateway(base: base, blocking: model)
        let home = try await gateway.home(locale: "en", ratingCeiling: "mature")
        let browse = try await gateway.browse(CatalogBrowseRequest())
        let search = try await gateway.search(CatalogSearchRequest(query: "Wallpaper"))
        let saved = try await gateway.savedWallpapers(cursor: nil)
        let detail = try await gateway.detail(wallpaperID: shown.id)
        XCTAssertEqual(home.sections.flatMap(\.items).map(\.id), [shown.id])
        XCTAssertEqual(browse.items.map(\.id), [shown.id])
        XCTAssertEqual(search.page.items.map(\.id), [shown.id])
        XCTAssertEqual(saved.items.map(\.id), [shown.id])
        XCTAssertEqual(detail.related.map(\.id), [shown.id])
    }

    func testBlockedDetailAndPositiveActionsDoNotReachMutationButRemovalAndReceiptDo() async throws {
        let hidden = summary(creator: blocked)
        let base = BlockingCatalogProbe(items: [hidden])
        let gateway = CreatorBlockingCatalogGateway(base: base, blocking: CreatorBlockingModel(gateway: nil, anonymousStore: GatewayAnonymousBlocks([blocked])))
        do { _ = try await gateway.detail(wallpaperID: hidden.id); XCTFail("Blocked detail admitted") }
        catch { XCTAssertEqual(error as? CreatorBlockingError, .blocked) }
        do { _ = try await gateway.setSaved(wallpaperID: hidden.id, desired: true, expectedRevision: 0, idempotencyKey: "test"); XCTFail("Blocked save admitted") }
        catch { XCTAssertEqual(error as? CreatorBlockingError, .blocked) }
        do { _ = try await gateway.setFavorite(wallpaperID: hidden.id, desired: true, expectedRevision: 0, idempotencyKey: "test"); XCTFail("Blocked favorite admitted") }
        catch { XCTAssertEqual(error as? CreatorBlockingError, .blocked) }
        do { _ = try await gateway.requestInstall(wallpaperID: hidden.id, releaseID: hidden.currentReleaseID, mediaKind: .video, expectedWallpaperRevision: 1, idempotencyKey: "test"); XCTFail("Blocked install admitted") }
        catch { XCTAssertEqual(error as? CreatorBlockingError, .blocked) }
        XCTAssertEqual(base.positiveWrites, 0)
        _ = try await gateway.setSaved(wallpaperID: hidden.id, desired: false, expectedRevision: 1, idempotencyKey: "test")
        try await gateway.recordInstall(receipt: "previously-issued", manifestDigest: "digest", releaseID: hidden.currentReleaseID, idempotencyKey: "test")
        XCTAssertEqual(base.removals, 1)
        XCTAssertEqual(base.recordedReceipts, 1)
    }

    func testMetadataReturningAfterBlockCannotReachPresentation() async throws {
        let base = BlockingCatalogProbe(items: [summary(creator: blocked)])
        base.holdHome = true
        let model = CreatorBlockingModel(gateway: nil, anonymousStore: GatewayAnonymousBlocks())
        let gateway = CreatorBlockingCatalogGateway(base: base, blocking: model)
        let read = Task { try await gateway.home(locale: "en", ratingCeiling: "mature") }
        while base.homeContinuation == nil { await Task.yield() }
        try await model.setBlocked(creatorID: blocked, desired: true)
        base.releaseHome()
        do { _ = try await read.value; XCTFail("Metadata from the old generation was admitted") } catch is CancellationError {}
    }

    func testCatalogReadWaitsForOverlappingUnchangedPreferenceRefresh() async throws {
        let base = BlockingCatalogProbe(items: [summary(creator: visible)])
        base.holdHome = true
        let preferences = OverlappingPreferencesGateway(subject: blocked)
        let model = CreatorBlockingModel(gateway: preferences, anonymousStore: GatewayAnonymousBlocks())
        model.updateSubject(blocked)
        let gateway = CreatorBlockingCatalogGateway(base: base, blocking: model)
        var readFinished = false
        let read = Task { defer { readFinished = true }; return try await gateway.home(locale: "en", ratingCeiling: "mature") }
        while base.homeContinuation == nil { await Task.yield() }
        let refresh = Task { try await model.refresh() }
        await preferences.waitForSecondRead()
        base.releaseHome()
        while !base.homeReturned { await Task.yield() }
        await Task.yield()
        XCTAssertFalse(readFinished, "Unchanged concurrent refresh must not abandon the home load")
        await preferences.release()
        _ = try await refresh.value
        let home = try await read.value
        XCTAssertEqual(home.sections.flatMap(\.items).count, 1)
    }

    func testOverlappingChangedPreferencesStillRejectOldMetadata() async throws {
        let base = BlockingCatalogProbe(items: [summary(creator: visible)])
        base.holdHome = true
        let preferences = OverlappingPreferencesGateway(subject: blocked)
        let model = CreatorBlockingModel(gateway: preferences, anonymousStore: GatewayAnonymousBlocks())
        model.updateSubject(blocked)
        let gateway = CreatorBlockingCatalogGateway(base: base, blocking: model)
        let read = Task { try await gateway.home(locale: "en", ratingCeiling: "mature") }
        while base.homeContinuation == nil { await Task.yield() }
        let refresh = Task { try await model.refresh() }
        await preferences.waitForSecondRead()
        base.releaseHome()
        while !base.homeReturned { await Task.yield() }
        await preferences.release(blocking: visible)
        _ = try await refresh.value
        do { _ = try await read.value; XCTFail("Changed generation admitted old metadata") } catch is CancellationError {}
        XCTAssertEqual(model.blockedCreatorIDs, [visible])
    }

    private func summary(creator: String) -> CatalogWallpaperSummary {
        let poster = try! CatalogArtifact(role: .poster, url: URL(string: "https://catalog.wali.example/poster")!, sha256: String(repeating: "a", count: 64), byteCount: 1, mediaType: "image/jpeg", width: 1, height: 1, durationMilliseconds: 0)
        let video = try! CatalogArtifact(role: .preview, url: URL(string: "https://catalog.wali.example/preview")!, sha256: String(repeating: "b", count: 64), byteCount: 1, mediaType: "video/mp4", width: 1, height: 1, durationMilliseconds: 1_000)
        return CatalogWallpaperSummary(id: creator, slug: "wallpaper", title: "Wallpaper", creator: .init(id: creator, handle: "artist", displayName: "Artist", avatarURL: nil, verification: .verified), contentRating: .everyone, primaryCategory: .init(id: "44444444-4444-4444-8444-444444444444", name: "Nature", slug: "nature"), approvedTags: [], poster: poster, preview: video, currentReleaseID: "55555555-5555-4555-8555-555555555555", revision: 1, publishedAt: .now, verifiedInstallCount: 0, favoriteCount: 0, saveCount: 0)
    }
}

@MainActor
private final class GatewayAnonymousBlocks: AnonymousCreatorBlockStoring {
    var ids: Set<String>
    init(_ ids: Set<String> = []) { self.ids = ids }
    func load() throws -> Set<String> { ids }
    func save(_ ids: Set<String>) throws { self.ids = ids }
}

@MainActor
private final class BlockingCatalogProbe: CatalogGateway {
    let items: [CatalogWallpaperSummary]
    var positiveWrites = 0
    var removals = 0
    var recordedReceipts = 0
    var holdHome = false
    var homeReturned = false
    var homeContinuation: CheckedContinuation<Void, Never>?
    init(items: [CatalogWallpaperSummary]) { self.items = items }
    func releaseHome() { homeContinuation?.resume(); homeContinuation = nil }
    func home(locale: String, ratingCeiling: String) async throws -> CatalogHome {
        if holdHome { await withCheckedContinuation { homeContinuation = $0 } }
        homeReturned = true
        return CatalogHome(sections: [.init(id: "featured", title: "Featured", kind: .editorial, cursor: nil, items: items)])
    }
    func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage { .init(items: items, nextCursor: nil) }
    func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage {
        .init(page: .init(items: items, nextCursor: nil), rankingExplanation: .init(formulaRevision: "test", modelRevision: nil))
    }
    func savedWallpapers(cursor: String?) async throws -> CatalogPage { .init(items: items, nextCursor: nil) }
    func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail {
        let item = try XCTUnwrap(items.first { $0.id == wallpaperID })
        return .init(summary: item, description: "Fixture", edition: 1, rightsHolder: "Artist", attributionText: nil, sourceURL: nil, license: .init(code: "test", name: "Fixture license", termsURL: URL(string: "https://catalog.wali.example/license")!, attributionRequired: false, commercialUseAllowed: false, derivativesAllowed: false, redistributionAllowed: false, termsRevision: 1), durationMilliseconds: 1_000, width: 1, height: 1, frameRateNumerator: 30, frameRateDenominator: 1, videoDefault: item.preview!, related: items, isFavorite: false, favoriteRevision: 0, isSaved: false, savedRevision: 0)
    }
    func setFavorite(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult {
        if desired { positiveWrites += 1 } else { removals += 1 }; return .init(desired: desired, revision: expectedRevision + 1, aggregateCount: 0)
    }
    func setSaved(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult { try await setFavorite(wallpaperID: wallpaperID, desired: desired, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey) }
    func requestInstall(wallpaperID: String, releaseID: String, mediaKind: CatalogMediaKind, expectedWallpaperRevision: UInt64, idempotencyKey: String) async throws -> CatalogInstallGrant { positiveWrites += 1; throw CatalogRequestError.notConfigured }
    func recordInstall(receipt: String, manifestDigest: String, releaseID: String, idempotencyKey: String) async throws { recordedReceipts += 1 }
}

private actor OverlappingPreferencesGateway: CreatorBlockingGateway {
    let subject: String
    var reads = 0
    var rows: [CreatorBlockRow] = []
    var generation: UInt64 = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(subject: String) { self.subject = subject }
    func waitForSecondRead() async { while continuation == nil { await Task.yield() } }
    func release(blocking creatorID: String? = nil) {
        if let creatorID { rows = [try! .init(creatorID: creatorID, active: true, revision: 1, displayName: nil, handle: nil)]; generation = 1 }
        continuation?.resume(); continuation = nil
    }
    func creatorBlocks(cursor: String?, selectedCreatorID: String?) async throws -> CreatorBlockPage {
        reads += 1
        if reads == 2 { await withCheckedContinuation { continuation = $0 } }
        return try .init(subjectID: subject, generation: generation, items: rows, nextCursor: nil)
    }
    func setCreatorBlock(creatorID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CreatorBlockResult { throw CreatorBlockingError.unavailable }
    func hiddenCreatorInteractions(cursor: String?) async throws -> CreatorHiddenInteractionPage { throw CreatorBlockingError.unavailable }
    func removeHiddenCreatorInteraction(_ value: CreatorHiddenInteraction, idempotencyKey: String) async throws { throw CreatorBlockingError.unavailable }
}
