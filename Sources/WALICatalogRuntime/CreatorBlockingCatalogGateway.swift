import Foundation

/// Enforces current foreground preferences before catalog bytes reach presentation.
/// Authenticated filtering is also enforced independently by the server.
@MainActor
public final class CreatorBlockingCatalogGateway: CatalogGateway {
    private let base: any CatalogGateway
    private let blocking: CreatorBlockingModel
    public init(base: any CatalogGateway, blocking: CreatorBlockingModel) { self.base = base; self.blocking = blocking }
    private func read<Value: Sendable>(_ operation: () async throws -> Value) async throws -> (Value, CreatorBlockingModel.Snapshot) {
        let snapshot = try await blocking.refresh()
        let value = try await operation()
        try Task.checkCancellation(); try await blocking.validateAfterPendingRefresh(snapshot)
        return (value, snapshot)
    }
    private func items(_ values: [CatalogWallpaperSummary], _ snapshot: CreatorBlockingModel.Snapshot) -> [CatalogWallpaperSummary] {
        values.filter { !snapshot.blockedCreatorIDs.contains($0.creator.id) }
    }
    public func categories() async throws -> [CatalogTaxonomySummary] { try await read { try await base.categories() }.0 }
    public func tags() async throws -> [CatalogTaxonomySummary] { try await read { try await base.tags() }.0 }
    public func savedWallpapers(cursor: String?) async throws -> CatalogPage {
        let (page, snapshot) = try await read { try await base.savedWallpapers(cursor: cursor) }
        return CatalogPage(items: items(page.items, snapshot), nextCursor: page.nextCursor)
    }
    public func home(locale: String, ratingCeiling: String) async throws -> CatalogHome {
        let (home, snapshot) = try await read { try await base.home(locale: locale, ratingCeiling: ratingCeiling) }
        return CatalogHome(sections: home.sections.compactMap { section in
            let visible = items(section.items, snapshot)
            return visible.isEmpty ? nil : CatalogHomeSection(id: section.id, title: section.title, kind: section.kind, cursor: section.cursor, items: visible)
        })
    }
    public func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage {
        let (page, snapshot) = try await read { try await base.browse(request) }
        return CatalogPage(items: items(page.items, snapshot), nextCursor: page.nextCursor)
    }
    public func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage {
        let (result, snapshot) = try await read { try await base.search(request) }
        return CatalogSearchPage(page: CatalogPage(items: items(result.page.items, snapshot), nextCursor: result.page.nextCursor), rankingExplanation: result.rankingExplanation)
    }
    public func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail {
        let (value, snapshot) = try await read { try await base.detail(wallpaperID: wallpaperID) }
        guard !snapshot.blockedCreatorIDs.contains(value.summary.creator.id) else { throw CreatorBlockingError.blocked }
        return CatalogWallpaperDetail(summary: value.summary, description: value.description, edition: value.edition,
            rightsHolder: value.rightsHolder, attributionText: value.attributionText, sourceURL: value.sourceURL,
            license: value.license, media: value.media, related: items(value.related, snapshot), isFavorite: value.isFavorite,
            favoriteRevision: value.favoriteRevision, isSaved: value.isSaved, savedRevision: value.savedRevision)
    }
    private func positiveActionSnapshot(wallpaperID: String) async throws -> CreatorBlockingModel.Snapshot {
        let (detail, snapshot) = try await read { try await base.detail(wallpaperID: wallpaperID) }
        guard !snapshot.blockedCreatorIDs.contains(detail.summary.creator.id) else { throw CreatorBlockingError.blocked }
        return snapshot
    }
    public func setFavorite(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult {
        let snapshot = desired ? try await positiveActionSnapshot(wallpaperID: wallpaperID) : nil
        let value = try await base.setFavorite(wallpaperID: wallpaperID, desired: desired, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey)
        if let snapshot { try await blocking.validateAfterPendingRefresh(snapshot) }; return value
    }
    public func setSaved(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult {
        let snapshot = desired ? try await positiveActionSnapshot(wallpaperID: wallpaperID) : nil
        let value = try await base.setSaved(wallpaperID: wallpaperID, desired: desired, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey)
        if let snapshot { try await blocking.validateAfterPendingRefresh(snapshot) }; return value
    }
    public func requestInstall(wallpaperID: String, releaseID: String, mediaKind: CatalogMediaKind, expectedWallpaperRevision: UInt64, idempotencyKey: String) async throws -> CatalogInstallGrant {
        let snapshot = try await positiveActionSnapshot(wallpaperID: wallpaperID)
        let grant = try await base.requestInstall(wallpaperID: wallpaperID, releaseID: releaseID, mediaKind: mediaKind, expectedWallpaperRevision: expectedWallpaperRevision, idempotencyKey: idempotencyKey)
        try await blocking.validateAfterPendingRefresh(snapshot); return grant
    }
    public func recordInstall(receipt: String, manifestDigest: String, releaseID: String, idempotencyKey: String) async throws {
        try await base.recordInstall(receipt: receipt, manifestDigest: manifestDigest, releaseID: releaseID, idempotencyKey: idempotencyKey)
    }
    public func securityState() async throws -> CatalogSecurityState { try await base.securityState() }
    public func catalogPreferences() async throws -> CatalogPreferences { try await base.catalogPreferences() }
    public func setCatalogPreferences(categoryIDs: [String], ratingCeiling: String, personalizationOptOut: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogPreferences {
        try await base.setCatalogPreferences(categoryIDs: categoryIDs, ratingCeiling: ratingCeiling, personalizationOptOut: personalizationOptOut, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey)
    }
}
