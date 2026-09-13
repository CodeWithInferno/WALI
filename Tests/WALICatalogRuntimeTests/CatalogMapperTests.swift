import CryptoKit
import Foundation
import WALICatalog
@testable import WALICatalogRuntime
import XCTest

final class CatalogMapperTests: XCTestCase {
    func testMarketplaceIsDisabledUnlessTheBundleFlagIsExplicitlyTrue() {
        XCTAssertFalse(CatalogEnvironment.isMarketplaceEnabled(infoDictionary: [:]))
        XCTAssertFalse(CatalogEnvironment.isMarketplaceEnabled(infoDictionary: [
            "WALIMarketplaceEnabled": false,
        ]))
        XCTAssertFalse(CatalogEnvironment.isMarketplaceEnabled(infoDictionary: [
            "WALIMarketplaceEnabled": "yes",
        ]))
        XCTAssertTrue(CatalogEnvironment.isMarketplaceEnabled(infoDictionary: [
            "WALIMarketplaceEnabled": true,
        ]))
        XCTAssertTrue(CatalogEnvironment.isMarketplaceEnabled(infoDictionary: [
            "WALIMarketplaceEnabled": "YES",
        ]))
    }
    func testBrowseRequestRejectsUnboundedInput() throws {
        XCTAssertThrowsError(
            try CatalogBrowseRequest(tags: (0..<11).map { "tag-\($0)" })
        )
        XCTAssertThrowsError(
            try CatalogBrowseRequest(cursor: String(repeating: "a", count: 1_025))
        )
    }

    func testSearchRequestAcceptsBoundedProductFilters() throws {
        let request = try CatalogSearchRequest(
            query: "aurora",
            category: "nature",
            tags: ["night", "sky"],
            ratingCeiling: "everyone",
            minimumDurationMilliseconds: 1_000,
            maximumDurationMilliseconds: 30_000,
            limit: 24
        )
        XCTAssertEqual(request.query, "aurora")
        XCTAssertEqual(request.tags, ["night", "sky"])
    }

    func testCatalogPreferencesRejectMalformedAndOversizedOwnerState() throws {
        let subject = "11111111-1111-4111-8111-111111111111"
        let category = "22222222-2222-4222-8222-222222222222"
        XCTAssertThrowsError(try CatalogPreferences(userID: "another user", categoryIDs: [], ratingCeiling: "teen", personalizationOptOut: false, revision: 1))
        XCTAssertThrowsError(try CatalogPreferences(userID: subject, categoryIDs: [category, category], ratingCeiling: "teen", personalizationOptOut: false, revision: 1))
        XCTAssertThrowsError(try CatalogPreferences(userID: subject, categoryIDs: [], ratingCeiling: "adult", personalizationOptOut: false, revision: 1))
        XCTAssertThrowsError(try CatalogPreferences(userID: subject, categoryIDs: [], ratingCeiling: "teen", personalizationOptOut: false, revision: 9_007_199_254_740_992))
        XCTAssertThrowsError(try CatalogPreferences(userID: subject, categoryIDs: (0..<13).map { _ in UUID().uuidString.lowercased() }, ratingCeiling: "teen", personalizationOptOut: false, revision: 1))
    }

    func testCatalogPreferenceDTOUsesExactServerFieldNamesAndExplicitChoices() throws {
        let data = Data(#"{"user_id":"11111111-1111-4111-8111-111111111111","category_ids":["33333333-3333-4333-8333-333333333333","22222222-2222-4222-8222-222222222222"],"rating_ceiling":"everyone","personalization_opt_out":true,"revision":8,"replayed":true}"#.utf8)
        let value = try JSONDecoder().decode(CatalogPreferencesDTO.self, from: data).validated()
        XCTAssertEqual(value.categoryIDs, ["22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"])
        XCTAssertEqual(value.ratingCeiling, "everyone")
        XCTAssertTrue(value.personalizationOptOut)
        XCTAssertEqual(value.revision, 8)
    }

    func testRemoteErrorNeverStoresUnderlyingSDKDescription() {
        let error = CatalogRemoteError(
            code: "temporarily_unavailable",
            safeMessage: nil,
            retryable: true
        )
        XCTAssertNil(error.safeMessage)
        XCTAssertEqual(error.code, "temporarily_unavailable")
    }

    func testMapperRejectsCatalogMediaOutsideConfiguredCDN() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let mapper = CatalogMapper(remoteURLPolicy: policy)
        let summary = wallpaperSummary(mediaHost: "127.0.0.1")

        XCTAssertThrowsError(try mapper.home(CatalogHomeDTO(sections: [
            HomeSectionDTO(id: "featured", title: "Featured", kind: "editorial", cursor: nil, items: [summary])
        ])))
    }

    func testMapperRejectsResponseForDifferentRequest() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let mapper = CatalogMapper(remoteURLPolicy: policy)
        let expectedRequestID = "11111111-1111-4111-8111-111111111111"
        let envelope = CatalogFunctionEnvelope<String>(
            apiVersion: "catalog.v1",
            requestID: "22222222-2222-4222-8222-222222222222",
            data: "unexpected",
            error: nil
        )

        XCTAssertThrowsError(try mapper.payload(
            envelope,
            apiVersion: "catalog.v1",
            expectedRequestID: expectedRequestID
        ))
    }

    func testMapperAcceptsCanonicalPlaybackArtifactOnDetail() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let mapper = CatalogMapper(remoteURLPolicy: policy)
        let summary = wallpaperSummary(mediaHost: "cdn.wali.example")
        let videoDefault = ArtifactSummaryDTO(
            role: "video_default",
            url: URL(string: "https://cdn.wali.example/video-default.mp4")!,
            sha256: String(repeating: "c", count: 64),
            byteCount: 100,
            mediaType: "video/mp4",
            width: 3840,
            height: 2160,
            durationMilliseconds: 24_200
        )
        let dto = WallpaperDetailDTO(
            wallpaper: summary,
            description: "A test wallpaper.",
            edition: 1,
            rightsHolder: "Artist",
            attributionText: nil,
            sourceURL: nil,
            license: LicenseDTO(
                code: "CC0-1.0",
                name: "CC0 1.0",
                termsURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!,
                attributionRequired: false,
                commercialUseAllowed: true,
                derivativesAllowed: true,
                redistributionAllowed: true,
                termsRevision: 1
            ),
            media: CatalogMediaDTO(kind: "video", width: 3840, height: 2160, artifact: videoDefault,
                                   durationMilliseconds: 24_200, frameRateNumerator: 60, frameRateDenominator: 1),
            related: [],
            isFavorite: false,
            favoriteRevision: 0,
            isSaved: false,
            savedRevision: 0
        )

        let detail = try mapper.detail(dto)

        XCTAssertEqual(detail.media.artifact.role, .videoDefault)
        XCTAssertEqual(detail.width, 3840)
        XCTAssertEqual(detail.height, 2160)
        XCTAssertEqual(detail.framesPerSecond, 60)
    }

    func testV2StillMediaHasNoSyntheticVideoMetadata() throws {
        let bytes = Data(#"{"kind":"still","width":3840,"height":2160,"artifact":{"role":"image_default","url":"https://cdn.wali.example/image.png","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","byte_count":8192,"media_type":"image/png","width":3840,"height":2160,"duration_ms":0}}"#.utf8)
        let value = try JSONDecoder().decode(CatalogMediaDTO.self, from: bytes)
        XCTAssertEqual(value.kind, "still")
        XCTAssertNil(value.durationMilliseconds)
        XCTAssertNil(value.frameRateNumerator)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for injected in [",\"duration_ms\":0", ",\"frame_rate_numerator\":0", ",\"kind_hint\":\"video\""] {
            let wrong = Data((String(text.dropLast()) + injected + "}").utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(CatalogMediaDTO.self, from: wrong))
        }
        let missingKind = Data(text.replacingOccurrences(of: "\"kind\":\"still\",", with: "").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogMediaDTO.self, from: missingKind))
    }

    func testV2SummaryRequiresExplicitKindAndRejectsVideoPreviewOnStill() throws {
        let policy = try CatalogRemoteURLPolicy(supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
                                                approvedCDNHosts: ["cdn.wali.example"])
        let mapper = CatalogMapper(remoteURLPolicy: policy)
        var summary = wallpaperSummary(mediaHost: "cdn.wali.example")
        summary.mediaKind = "still"
        XCTAssertThrowsError(try mapper.page(.init(items: [summary], nextCursor: nil)))
        summary.mediaKind = "future"
        XCTAssertThrowsError(try mapper.page(.init(items: [summary], nextCursor: nil)))
    }

    func testMapperAcceptsSupabasePostgresTimestamp() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )
        let mapper = CatalogMapper(remoteURLPolicy: policy)
        var summary = wallpaperSummary(mediaHost: "cdn.wali.example")
        summary = WallpaperSummaryDTO(
            id: summary.id,
            slug: summary.slug,
            title: summary.title,
            creator: summary.creator,
            contentRating: summary.contentRating,
            primaryCategory: summary.primaryCategory,
            approvedTags: summary.approvedTags,
            poster: summary.poster,
            preview: summary.preview,
            currentReleaseID: summary.currentReleaseID,
            revision: summary.revision,
            publishedAt: "2026-09-01T23:04:22.105012+00:00",
            verifiedInstallCount: summary.verifiedInstallCount,
            favoriteCount: summary.favoriteCount,
            saveCount: summary.saveCount
        )

        let home = try mapper.home(CatalogHomeDTO(sections: [
            HomeSectionDTO(id: "featured", title: "Featured", kind: "editorial", cursor: nil, items: [summary])
        ]))

        XCTAssertEqual(home.sections.first?.items.first?.title, "Test")
    }

    private func wallpaperSummary(mediaHost: String) -> WallpaperSummaryDTO {
        let poster = ArtifactSummaryDTO(
            role: "poster",
            url: URL(string: "https://\(mediaHost)/poster.jpg")!,
            sha256: String(repeating: "a", count: 64),
            byteCount: 100,
            mediaType: "image/jpeg",
            width: 100,
            height: 100,
            durationMilliseconds: 0
        )
        let preview = ArtifactSummaryDTO(
            role: "preview",
            url: URL(string: "https://\(mediaHost)/preview.mp4")!,
            sha256: String(repeating: "b", count: 64),
            byteCount: 100,
            mediaType: "video/mp4",
            width: 100,
            height: 100,
            durationMilliseconds: 1_000
        )
        return WallpaperSummaryDTO(
            id: "11111111-1111-4111-8111-111111111111",
            slug: "test",
            title: "Test",
            creator: CreatorSummaryDTO(
                id: "22222222-2222-4222-8222-222222222222",
                handle: "artist",
                displayName: "Artist",
                avatarURL: nil,
                verificationStatus: "verified"
            ),
            contentRating: "everyone",
            primaryCategory: TaxonomySummaryDTO(
                id: "33333333-3333-4333-8333-333333333333",
                name: "Nature",
                slug: "nature"
            ),
            approvedTags: [],
            poster: poster,
            preview: preview,
            currentReleaseID: "44444444-4444-4444-8444-444444444444",
            revision: 1,
            publishedAt: "2026-09-01T12:00:00Z",
            verifiedInstallCount: 0,
            favoriteCount: 0,
            saveCount: 0
        )
    }
}

final class CatalogRemoteURLPolicyTests: XCTestCase {
    func testMediaRequiresConfiguredCDNHostAndCanonicalHTTPSURL() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )

        XCTAssertTrue(policy.allowsMedia(URL(string: "https://cdn.wali.example/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://evil.example/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://127.0.0.1/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://localhost/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://service.internal/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://user@cdn.wali.example/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://cdn.wali.example:443/media/poster.jpg")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://cdn.wali.example/media/poster.jpg?q=1")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://cdn.wali.example/media/poster.jpg#x")!))
    }

    func testUploadAndControlPlaneAllowOnlySupabaseOrConfiguredCDNHosts() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.wali.example"]
        )

        XCTAssertTrue(policy.allowsControlPlane(URL(
            string: "https://project.supabase.co/functions/v1/catalog-security-state"
        )!))
        XCTAssertTrue(policy.allowsUpload(URL(string: "https://cdn.wali.example/upload/session")!))
        XCTAssertFalse(policy.allowsUpload(URL(string: "https://uploads.attacker.example/session")!))
        XCTAssertFalse(policy.allowsControlPlane(URL(
            string: "https://[::1]/functions/v1/catalog-security-state"
        )!))
        XCTAssertTrue(policy.allowsSignedAccountExport(URL(
            string: "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/account.json?token=signed"
        )!))
        XCTAssertTrue(policy.allowsSignedAccountExport(
            URL(string: "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/account.json?token=signed")!,
            subjectID: "11111111-1111-4111-8111-111111111111",
            exportID: "22222222-2222-4222-8222-222222222222"
        ))
        XCTAssertFalse(policy.allowsSignedAccountExport(
            URL(string: "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/33333333-3333-4333-8333-333333333333/22222222-2222-4222-8222-222222222222/account.json?token=signed")!,
            subjectID: "11111111-1111-4111-8111-111111111111",
            exportID: "22222222-2222-4222-8222-222222222222"
        ))
        XCTAssertFalse(policy.allowsSignedAccountExport(
            URL(string: "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/11111111-1111-4111-8111-111111111111/33333333-3333-4333-8333-333333333333/account.json?token=signed")!,
            subjectID: "11111111-1111-4111-8111-111111111111",
            exportID: "22222222-2222-4222-8222-222222222222"
        ))
        XCTAssertFalse(policy.allowsSignedAccountExport(URL(
            string: "https://project.supabase.co/storage/v1/object/sign/exports-private/exports/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/account.json?token=signed&next=https://evil.example"
        )!))
        XCTAssertFalse(policy.allowsSignedAccountExport(URL(
            string: "https://evil.example/storage/v1/object/sign/exports-private/exports/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/account.json?token=signed"
        )!))
    }
}

final class CatalogSecurityStateTests: XCTestCase {
    func testPersistsAndRestoresLastKnownGoodSignedStateOffline() async throws {
        let fixture = try SecurityFixture()
        let cache = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let store = try CatalogSecurityStateStore(environment: fixture.environment, cacheURL: cache)

        let accepted = try await store.accept(fixture.state(revocationRevision: 4))
        XCTAssertEqual(accepted.trustTransition?.revision, 2)
        XCTAssertEqual(accepted.revocations.revision, 4)
        XCTAssertEqual(accepted.trustedKeys.count, 2)

        let offlineStore = try CatalogSecurityStateStore(environment: fixture.environment, cacheURL: cache)
        let restored = try await offlineStore.lastKnownGood()
        XCTAssertEqual(restored, accepted)
    }

    func testCorruptCacheFailsClosed() async throws {
        let fixture = try SecurityFixture()
        let cache = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: cache)
        let store = try CatalogSecurityStateStore(environment: fixture.environment, cacheURL: cache)

        do {
            _ = try await store.lastKnownGood()
            XCTFail("Expected corrupt security state to fail closed")
        } catch let error as CatalogSecurityStateError {
            XCTAssertEqual(error, .corruptCache)
        }
    }

    func testRejectsRevocationRollbackAndEqualRevisionEquivocation() async throws {
        let fixture = try SecurityFixture()
        let store = try CatalogSecurityStateStore(environment: fixture.environment, cacheURL: nil)
        _ = try await store.accept(fixture.state(revocationRevision: 4))

        await XCTAssertThrowsErrorAsync {
            _ = try await store.accept(fixture.state(revocationRevision: 3))
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.accept(
                fixture.state(revocationRevision: 4, revokedDigest: String(repeating: "9", count: 64))
            )
        }
    }

    func testRejectsTrustTransitionEquivocation() async throws {
        let fixture = try SecurityFixture()
        let store = try CatalogSecurityStateStore(environment: fixture.environment, cacheURL: nil)
        _ = try await store.accept(fixture.state(revocationRevision: 4))

        await XCTAssertThrowsErrorAsync {
            _ = try await store.accept(
                fixture.state(revocationRevision: 4, operationalStatus: "retired")
            )
        }
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("catalog-security.json", isDirectory: false)
    }
}

private struct SecurityFixture {
    let root: Curve25519.Signing.PrivateKey
    let operational: Curve25519.Signing.PrivateKey
    let environment: CatalogEnvironment

    init() throws {
        root = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
        )
        operational = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        environment = try CatalogEnvironment(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "public-test-key",
            approvedCDNHosts: ["cdn.wali.example"],
            signingKeyID: "catalog-root-2026",
            signingPublicKey: root.publicKey.rawRepresentation
        )
    }

    func state(
        revocationRevision: UInt64,
        revokedDigest: String = String(repeating: "4", count: 64),
        operationalStatus: String = "active"
    ) -> CatalogSecurityState {
        let transition = transitionBody(status: operationalStatus)
        let revocations = revocationBody(revision: revocationRevision, digest: revokedDigest)
        return CatalogSecurityState(
            trustTransition: CatalogSignedDocument(
                revision: 2,
                canonicalBody: transition,
                signatureBase64URL: try! root.signature(for: transition).base64URL,
                keyID: "catalog-root-2026"
            ),
            revocations: CatalogSignedDocument(
                revision: revocationRevision,
                canonicalBody: revocations,
                signatureBase64URL: try! operational.signature(for: revocations).base64URL,
                keyID: "catalog-operational-2026"
            )
        )
    }

    private func transitionBody(status: String) -> Data {
        Data(#"{"schema":"wali.catalog.trust-transition.v1","revision":2,"issued_at":"2026-09-01T12:00:00Z","keys":[{"key_id":"catalog-operational-2026","public_key":"\#(operational.publicKey.rawRepresentation.base64URL)","valid_from":"2026-01-01T00:00:00Z","valid_until":"2030-01-01T00:00:00Z","status":"\#(status)"},{"key_id":"catalog-root-2026","public_key":"\#(root.publicKey.rawRepresentation.base64URL)","valid_from":"1970-01-01T00:00:00Z","valid_until":"2100-01-01T00:00:00Z","status":"active"}]}"#.utf8)
    }

    private func revocationBody(revision: UInt64, digest: String) -> Data {
        Data(#"{"schema":{"epoch":1,"revision":0},"key_id":"catalog-operational-2026","revision":\#(revision),"issued_at":"2026-09-01T12:00:00Z","revocations":[{"release_id":"22222222-2222-4222-8222-222222222222","artifact_sha256":"\#(digest)","reason":"critical_security","issued_at":"2026-09-01T12:00:00Z"}]}"#.utf8)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
