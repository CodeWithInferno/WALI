import CryptoKit
import Foundation
import WALICatalog
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
final class CatalogInstallFlowTests: XCTestCase {
    func testSelectedCatalogWallpaperUsesVerifiedOpaqueAgentHandoff() async throws {
        let source = Data("catalog-source".utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        let metadata = Data(Self.metadataJSON.utf8)
        let manifest = Data(Self.manifestJSON(
            sourceDigest: Self.sha256(source),
            sourceByteCount: source.count,
            metadataDigest: Self.sha256(metadata)
        ).utf8)
        let signature = Self.base64URL(try privateKey.signature(for: manifest))
        let grant = CatalogInstallGrant(
            manifestBody: manifest,
            metadataBody: metadata,
            signatureBase64URL: signature,
            keyID: "catalog-test",
            receipt: "opaque-install-receipt",
            expiresAt: Date().addingTimeInterval(300)
        )
        let events = CatalogInstallEvents()
        let revocationBody = Data(
            #"{"schema":{"epoch":1,"revision":0},"key_id":"catalog-test","revision":1,"issued_at":"2026-09-01T16:00:00Z","revocations":[]}"#.utf8
        )
        let security = CatalogSecurityState(
            trustTransition: nil,
            revocations: CatalogSignedDocument(
                revision: 1,
                canonicalBody: revocationBody,
                signatureBase64URL: Self.base64URL(try privateKey.signature(for: revocationBody)),
                keyID: "catalog-test"
            )
        )
        let gateway = InstallGateway(
            detail: Self.detail(),
            grant: grant,
            security: security,
            events: events
        )
        let transfer = TemporaryCatalogDownload(source: source)
        let downloader = try CatalogDownloader(
            transport: transfer,
            approvedHosts: ["catalog.wali.example"]
        )
        let quarantine = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: quarantine) }
        let environment = try CatalogEnvironment(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            publishableKey: "public-test-key",
            approvedCDNHosts: ["catalog.wali.example"],
            signingKeyID: "catalog-test",
            signingPublicKey: privateKey.publicKey.rawRepresentation
        )
        let preparer = try CatalogInstallPreparer(
            environment: environment,
            downloader: downloader,
            quarantineDirectory: quarantine
        )
        let securityStore = try CatalogSecurityStateStore(environment: environment)
        var received: PreparedCatalogInstall?
        let coordinator = MarketplaceCoordinator(
            gateway: gateway,
            installPreparer: preparer,
            securityStore: securityStore,
            installHandler: { install in
                received = install
                await events.append("agent")
            },
            securityHandler: { _ in
                await events.append("security")
            }
        )
        coordinator.model.accountState = .signedIn(userID: "test-user")
        coordinator.loadDetail(wallpaperID: Self.wallpaperID)
        guard try await waitForState("selected detail", coordinator: coordinator, events: events, until: {
            coordinator.model.detailState == .ready && coordinator.model.selectedDetail?.id == Self.wallpaperID
        }) else { return }

        coordinator.installSelectedWallpaper()
        guard try await waitForState("completed install and metric", coordinator: coordinator, events: events, until: {
            let recordedEvents = await events.values
            return coordinator.model.catalogInstall?.phase == .completed && recordedEvents.contains("metric")
        }) else { return }

        XCTAssertEqual(received?.wallpaperID, Self.wallpaperID)
        XCTAssertEqual(received?.releaseID, Self.releaseID)
        XCTAssertNotNil(received?.quarantineReference)
        XCTAssertEqual(coordinator.model.actionState, .succeeded(message: "Added to Library"))
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["security", "agent", "metric"])
    }

    private func waitForState(
        _ description: String,
        coordinator: MarketplaceCoordinator,
        events: CatalogInstallEvents,
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @MainActor () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recordedEvents = await events.values
        XCTFail(
            "Timed out waiting for \(description): detail=\(coordinator.model.detailState), "
                + "install=\(String(describing: coordinator.model.catalogInstall?.phase)), "
                + "action=\(coordinator.model.actionState), events=\(recordedEvents)",
            file: file,
            line: line
        )
        return false
    }

    private static let wallpaperID = "11111111-1111-4111-8111-111111111111"
    private static let releaseID = "22222222-2222-4222-8222-222222222222"

    private static func detail() -> CatalogWallpaperDetail {
        let poster = try! CatalogArtifact(
            role: .poster,
            url: URL(string: "https://catalog.wali.example/poster")!,
            sha256: String(repeating: "b", count: 64),
            byteCount: 1,
            mediaType: "image/jpeg",
            width: 1,
            height: 1,
            durationMilliseconds: 0
        )
        let preview = try! CatalogArtifact(
            role: .preview,
            url: URL(string: "https://catalog.wali.example/preview")!,
            sha256: String(repeating: "c", count: 64),
            byteCount: 1,
            mediaType: "video/mp4",
            width: 1,
            height: 1,
            durationMilliseconds: 1_000
        )
        let summary = CatalogWallpaperSummary(
            id: wallpaperID,
            slug: "catalog-test",
            title: "Catalog Test",
            creator: CatalogCreatorSummary(
                id: "33333333-3333-4333-8333-333333333333",
                handle: "wali-artist",
                displayName: "WALI Artist",
                avatarURL: nil,
                verification: .verified
            ),
            contentRating: .everyone,
            primaryCategory: CatalogTaxonomySummary(
                id: "44444444-4444-4444-8444-444444444444",
                name: "Nature",
                slug: "nature"
            ),
            approvedTags: [],
            poster: poster,
            preview: preview,
            currentReleaseID: releaseID,
            revision: 1,
            publishedAt: Date(),
            verifiedInstallCount: 0,
            favoriteCount: 0,
            saveCount: 0
        )
        return CatalogWallpaperDetail(
            summary: summary,
            description: "A verified test wallpaper.",
            edition: 1,
            rightsHolder: "WALI Artist",
            attributionText: "Artwork by WALI Artist",
            sourceURL: nil,
            license: CatalogLicense(
                code: "CC0-1.0",
                name: "CC0 1.0",
                termsURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!,
                attributionRequired: false,
                commercialUseAllowed: true,
                derivativesAllowed: true,
                redistributionAllowed: true,
                termsRevision: 1
            ),
            durationMilliseconds: 1_000,
            width: 1,
            height: 1,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            videoDefault: preview,
            related: [],
            isFavorite: false,
            favoriteRevision: 0,
            isSaved: false,
            savedRevision: 0
        )
    }

    private static let metadataJSON = #"{"schema":"wali.catalog.install-metadata.v1","wallpaper_id":"11111111-1111-4111-8111-111111111111","release_id":"22222222-2222-4222-8222-222222222222","edition":1,"title":"Catalog Test","creator_name":"WALI Artist","creator_handle":"wali-artist","attribution_text":"Artwork by WALI Artist","rights_holder":"WALI Artist"}"#

    private static func manifestJSON(
        sourceDigest: String,
        sourceByteCount: Int,
        metadataDigest: String
    ) -> String {
        "{\"schema\":{\"epoch\":1,\"revision\":0},\"key_id\":\"catalog-test\","
            + "\"wallpaper_id\":\"\(wallpaperID)\",\"release_id\":\"\(releaseID)\","
            + "\"edition\":1,\"issued_at\":\"2026-09-01T16:00:00Z\",\"artifacts\":["
            + artifact("thumbnail", String(repeating: "a", count: 64), 1, "image/png", 0)
            + "," + artifact("poster", String(repeating: "b", count: 64), 1, "image/jpeg", 0)
            + "," + artifact("preview", String(repeating: "c", count: 64), 1, "video/mp4", 1_000)
            + "," + artifact("video_default", sourceDigest, sourceByteCount, "video/mp4", 1_000)
            + "],\"metadata_digest\":\"\(metadataDigest)\"}"
    }

    private static func artifact(_ role: String, _ digest: String, _ count: Int, _ type: String, _ duration: Int) -> String {
        "{\"role\":\"\(role)\",\"url\":\"https://catalog.wali.example/\(role)\","
            + "\"sha256\":\"\(digest)\",\"byte_count\":\(count),\"media_type\":\"\(type)\","
            + "\"width\":1,\"height\":1,\"duration_ms\":\(duration)}"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor InstallGateway: CatalogGateway {
    let detailValue: CatalogWallpaperDetail
    let grant: CatalogInstallGrant
    let security: CatalogSecurityState
    let events: CatalogInstallEvents

    init(
        detail: CatalogWallpaperDetail,
        grant: CatalogInstallGrant,
        security: CatalogSecurityState,
        events: CatalogInstallEvents
    ) {
        detailValue = detail
        self.grant = grant
        self.security = security
        self.events = events
    }

    func home(locale: String, ratingCeiling: String) async throws -> CatalogHome { .init(sections: []) }
    func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage { .init(items: [], nextCursor: nil) }
    func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage { throw CatalogRequestError.notConfigured }
    func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail { detailValue }
    func setFavorite(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult { throw CatalogRequestError.notConfigured }
    func setSaved(wallpaperID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CatalogInteractionResult { throw CatalogRequestError.notConfigured }
    func requestInstall(wallpaperID: String, releaseID: String, expectedWallpaperRevision: UInt64, idempotencyKey: String) async throws -> CatalogInstallGrant { grant }
    func securityState() async throws -> CatalogSecurityState { security }
    func recordInstall(receipt: String, manifestDigest: String, releaseID: String, idempotencyKey: String) async throws {
        await events.append("metric")
        throw CatalogRequestError.notConfigured
    }
}

private actor CatalogInstallEvents {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct TemporaryCatalogDownload: CatalogDownloadTransport {
    let source: Data

    func download(_ url: URL) async throws -> CatalogTransportDownload {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try source.write(to: temporary, options: [.withoutOverwriting])
        return CatalogTransportDownload(
            temporaryFileURL: temporary,
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(source.count)]
            )!
        )
    }
}
