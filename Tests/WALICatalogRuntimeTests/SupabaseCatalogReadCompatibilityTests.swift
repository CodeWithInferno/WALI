import Foundation
import Supabase
import Synchronization
import XCTest
import WALICatalog
@testable import WALICatalogRuntime

final class SupabaseCatalogReadCompatibilityTests: XCTestCase {
    func testHomeMapsCompleteLegacyV1PayloadAfterMissingV2() async throws { try await assertLegacy(.home) }
    func testBrowseMapsCompleteLegacyV1PayloadAfterMissingV2() async throws { try await assertLegacy(.browse) }
    func testSearchMapsCompleteLegacyV1PayloadAfterMissingV2() async throws { try await assertLegacy(.search) }
    func testDetailMapsCompleteLegacyV1PayloadAfterMissingV2() async throws { try await assertLegacy(.detail) }
    func testSavedMapsCompleteLegacyV1PayloadAfterMissingV2() async throws { try await assertLegacy(.saved) }

    func testV2SuccessDoesNotCallLegacyRPC() async throws {
        for route in CatalogReadRoute.allCases {
            let fixture = try CatalogReadFixture(responses: [.success(route.payload(legacy: false))])
            defer { fixture.close() }
            try await exercise(route, gateway: fixture.gateway)
            XCTAssertEqual(fixture.requests.map(\.path), [route.v2])
        }
    }

    func testAuthenticationForbiddenOtherMissingAndMalformedFailuresDoNotFallback() async throws {
        let failures: [CatalogReadResponse] = [
            .failure(status: 401, code: "PGRST301"), .failure(status: 401, code: "PGRST303"),
            .failure(status: 403, code: "42501"), .failure(status: 404, code: "42P01"),
            .failure(status: 400, code: "PGRST200"), .failure(status: 400, code: "P0001"),
            .init(status: 404, body: Data(#"{"code":"PGRST202"}"#.utf8)),
            .init(status: 200, body: Data(#"{"items":"malformed"}"#.utf8)),
        ]
        for route in CatalogReadRoute.allCases {
            for failure in failures {
                let fixture = try CatalogReadFixture(responses: [failure])
                defer { fixture.close() }
                do { try await exercise(route, gateway: fixture.gateway); XCTFail("Failed V2 response was accepted") }
                catch {}
                XCTAssertEqual(fixture.requests.map(\.path), [route.v2])
            }
        }
    }

    func testMalformedLegacyPayloadRemainsAnErrorWithoutAnotherFallback() async throws {
        for route in CatalogReadRoute.allCases {
            let fixture = try CatalogReadFixture(responses: [.missing, .init(status: 200, body: Data("{}".utf8))])
            defer { fixture.close() }
            do { try await exercise(route, gateway: fixture.gateway); XCTFail("Malformed V1 response was accepted") }
            catch { XCTAssertEqual(error as? CatalogMappingError, .invalidResponse) }
            XCTAssertEqual(fixture.requests.map(\.path), [route.v2, route.v1])
        }
    }

    func testNextReadTriesV2AgainInsteadOfCachingMissingCapability() async throws {
        let route = CatalogReadRoute.home
        let fixture = try CatalogReadFixture(responses: [.missing, .success(route.payload(legacy: true)),
                                                         .success(route.payload(legacy: false))])
        defer { fixture.close() }
        try await exercise(route, gateway: fixture.gateway)
        try await exercise(route, gateway: fixture.gateway)
        XCTAssertEqual(fixture.requests.map(\.path), [route.v2, route.v1, route.v2])
    }

    func testFallbackRetainsOriginalAuthenticationWhenAccountChangesDuringV2() async throws {
        let route = CatalogReadRoute.home
        let fixture = try CatalogReadFixture(responses: [.missing, .success(route.payload(legacy: true))],
                                             switchAccountBeforeFirstReply: true)
        defer { fixture.close() }
        try await exercise(route, gateway: fixture.gateway)
        XCTAssertEqual(fixture.currentSubject, CatalogReadFixture.nextSubject)
        XCTAssertEqual(fixture.requests.map(\.authorization), Array(repeating: "Bearer " + fixture.original.accessToken, count: 2))
        XCTAssertEqual(fixture.requests.map(\.path), [route.v2, route.v1])
    }

    func testVideoInstallSelectsV1BeforeRequestAndAcceptsLegacyGrant() async throws {
        let fixture = try CatalogReadFixture(responses: [.grant(apiVersion: "catalog.v1", mediaKind: nil)])
        defer { fixture.close() }
        let grant = try await fixture.gateway.requestInstall(
            wallpaperID: CatalogReadRoute.wallpaperID, releaseID: CatalogReadRoute.releaseID, mediaKind: .video,
            expectedWallpaperRevision: 7, idempotencyKey: "video-install-fixture"
        )
        XCTAssertEqual(grant.mediaKind, .video)
        XCTAssertEqual(grant.manifestBody, Data("fixture-manifest".utf8))
        XCTAssertEqual(grant.metadataBody, Data("fixture-metadata".utf8))
        XCTAssertEqual(fixture.requests.map(\.path), ["/functions/v1/request-install"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(body["api_version"] as? String, "catalog.v1")
        XCTAssertEqual(body["idempotency_key"] as? String, "video-install-fixture")
        XCTAssertEqual(body["wallpaper_id"] as? String, CatalogReadRoute.wallpaperID)
        XCTAssertEqual(body["release_id"] as? String, CatalogReadRoute.releaseID)
        XCTAssertEqual(body["expected_wallpaper_revision"] as? Int, 7)
    }

    func testStillInstallSelectsV2BeforeRequestAndRequiresStillGrant() async throws {
        let fixture = try CatalogReadFixture(responses: [.grant(apiVersion: "catalog.v2", mediaKind: "still")])
        defer { fixture.close() }
        let grant = try await fixture.gateway.requestInstall(
            wallpaperID: CatalogReadRoute.wallpaperID, releaseID: CatalogReadRoute.releaseID, mediaKind: .still,
            expectedWallpaperRevision: 7, idempotencyKey: "still-install-fixture"
        )
        XCTAssertEqual(grant.mediaKind, .still)
        XCTAssertEqual(fixture.requests.map(\.path), ["/functions/v1/request-install"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(body["api_version"] as? String, "catalog.v2")
        XCTAssertEqual(body["idempotency_key"] as? String, "still-install-fixture")
    }

    func testInstallVersionNeverRetriesOnMissingFunctionForbiddenOrMalformedGrant() async throws {
        let scenarios: [(CatalogMediaKind, CatalogReadResponse)] = [
            (.video, try .grant(apiVersion: "catalog.v1", mediaKind: "still")),
            (.still, try .grant(apiVersion: "catalog.v2", mediaKind: nil)),
            (.still, try .grant(apiVersion: "catalog.v2", mediaKind: "video")),
            (.still, try .grant(apiVersion: "catalog.v2", mediaKind: "future")),
            (.still, try .grant(apiVersion: "catalog.v1", mediaKind: "still")),
            (.video, .missing), (.still, .missing),
            (.video, .failure(status: 403, code: "42501")),
            (.still, .failure(status: 401, code: "PGRST301")),
            (.video, .init(status: 200, body: Data("{}".utf8))),
        ]
        for (kind, response) in scenarios {
            let fixture = try CatalogReadFixture(responses: [response])
            defer { fixture.close() }
            do {
                _ = try await fixture.gateway.requestInstall(
                    wallpaperID: CatalogReadRoute.wallpaperID, releaseID: CatalogReadRoute.releaseID, mediaKind: kind,
                    expectedWallpaperRevision: 7, idempotencyKey: "rejected-install-fixture"
                )
                XCTFail("Invalid install reply was accepted")
            } catch {}
            XCTAssertEqual(fixture.requests.map(\.path), ["/functions/v1/request-install"])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.requests.first?.body)) as? [String: Any])
            XCTAssertEqual(body["api_version"] as? String, kind == .video ? "catalog.v1" : "catalog.v2")
        }
    }

    func testInstallRejectsWrongRequestCorrelationAndMalformedEncodedBody() async throws {
        let valid = try CatalogReadResponse.grant(apiVersion: "catalog.v1", mediaKind: nil)
        let text = try XCTUnwrap(String(data: valid.body, encoding: .utf8))
        let badBodies = [
            text.replacingOccurrences(of: "fixture-request-id", with: "77777777-7777-4777-8777-777777777777"),
            text.replacingOccurrences(of: "Zml4dHVyZS1tYW5pZmVzdA", with: "%invalid%"),
        ]
        for body in badBodies {
            let fixture = try CatalogReadFixture(responses: [.init(status: 200, body: Data(body.utf8))])
            defer { fixture.close() }
            do {
                _ = try await fixture.gateway.requestInstall(
                    wallpaperID: CatalogReadRoute.wallpaperID, releaseID: CatalogReadRoute.releaseID, mediaKind: .video,
                    expectedWallpaperRevision: 7, idempotencyKey: "malformed-install-fixture"
                )
                XCTFail("Unbound or malformed grant was accepted")
            } catch { XCTAssertEqual(error as? CatalogMappingError, .invalidResponse) }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    private func assertLegacy(_ route: CatalogReadRoute) async throws {
        let fixture = try CatalogReadFixture(responses: [.missing, .success(route.payload(legacy: true))])
        defer { fixture.close() }
        try await exercise(route, gateway: fixture.gateway)
        let requests = fixture.requests
        XCTAssertEqual(requests.map(\.path), [route.v2, route.v1])
        XCTAssertEqual(requests.map(\.authorization), Array(repeating: "Bearer " + fixture.original.accessToken, count: 2))
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.body)) as? NSDictionary)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.body)) as? NSDictionary)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, route.parameters as NSDictionary)
    }

    private func exercise(_ route: CatalogReadRoute, gateway: SupabaseCatalogGateway) async throws {
        let summary: CatalogWallpaperSummary
        switch route {
        case .home:
            let value = try await gateway.home(locale: "en-US", ratingCeiling: "teen")
            XCTAssertEqual(value.sections.count, 1)
            let section = try XCTUnwrap(value.sections.first)
            XCTAssertEqual(section.id, "new")
            XCTAssertEqual(section.title, "New")
            XCTAssertEqual(section.kind, .new)
            XCTAssertEqual(section.cursor, "next-page")
            summary = try XCTUnwrap(section.items.first)
        case .browse:
            let value = try await gateway.browse(.init(category: "nature", tags: ["night"], sort: .newest,
                                                       cursor: "request-cursor", limit: 12))
            XCTAssertEqual(value.nextCursor, "next-page")
            summary = try XCTUnwrap(value.items.first)
        case .search:
            let value = try await gateway.search(.init(query: "Ocean", category: "nature", tags: ["night"],
                                                       ratingCeiling: "teen", sort: .newest,
                                                       minimumDurationMilliseconds: 1_000, maximumDurationMilliseconds: 20_000,
                                                       cursor: "request-cursor", limit: 12))
            XCTAssertEqual(value.page.nextCursor, "next-page")
            XCTAssertEqual(value.rankingExplanation.formulaRevision, "ranking-v1")
            XCTAssertEqual(value.rankingExplanation.modelRevision, "model-v1")
            summary = try XCTUnwrap(value.page.items.first)
        case .saved:
            let value = try await gateway.savedWallpapers(cursor: "request-cursor")
            XCTAssertEqual(value.nextCursor, "next-page")
            summary = try XCTUnwrap(value.items.first)
        case .detail:
            let value = try await gateway.detail(wallpaperID: CatalogReadRoute.wallpaperID)
            XCTAssertEqual(value.description, "A calm ocean loop.")
            XCTAssertEqual(value.edition, 2)
            XCTAssertEqual(value.rightsHolder, "Original Artist")
            XCTAssertEqual(value.attributionText, "Original Artist; supplied with permission.")
            XCTAssertEqual(value.sourceURL?.absoluteString, "https://artist.example/source")
            XCTAssertEqual(value.license.code, "wallpaper-use")
            XCTAssertEqual(value.license.termsURL.absoluteString, "https://artist.example/license")
            XCTAssertTrue(value.license.attributionRequired)
            XCTAssertFalse(value.license.commercialUseAllowed)
            XCTAssertFalse(value.license.derivativesAllowed)
            XCTAssertTrue(value.license.redistributionAllowed)
            XCTAssertEqual(value.license.termsRevision, 3)
            XCTAssertEqual(value.width, 1920)
            XCTAssertEqual(value.height, 1080)
            XCTAssertEqual(value.durationMilliseconds, 12_000)
            XCTAssertEqual(value.framesPerSecond, 24)
            XCTAssertEqual(value.media.artifact.role.rawValue, "video_default")
            XCTAssertEqual(value.related.count, 1)
            XCTAssertTrue(value.isFavorite)
            XCTAssertEqual(value.favoriteRevision, 5)
            XCTAssertTrue(value.isSaved)
            XCTAssertEqual(value.savedRevision, 6)
            summary = value.summary
        }
        XCTAssertEqual(summary.id, CatalogReadRoute.wallpaperID)
        XCTAssertEqual(summary.title, "Ocean")
        XCTAssertEqual(summary.slug, "ocean")
        XCTAssertEqual(summary.mediaKind, .video)
        XCTAssertEqual(summary.creator.handle, "original_artist")
        XCTAssertEqual(summary.creator.displayName, "Original Artist")
        XCTAssertEqual(summary.creator.verification, .unverified)
        XCTAssertEqual(summary.primaryCategory.slug, "nature")
        XCTAssertEqual(summary.approvedTags.map(\.slug), ["night"])
        XCTAssertEqual(summary.poster.role.rawValue, "poster")
        XCTAssertEqual(summary.preview?.role.rawValue, "preview")
        XCTAssertEqual(summary.currentReleaseID, CatalogReadRoute.releaseID)
        XCTAssertEqual(summary.revision, 7)
        XCTAssertEqual(summary.verifiedInstallCount, 11)
        XCTAssertEqual(summary.favoriteCount, 12)
        XCTAssertEqual(summary.saveCount, 13)
    }
}

private enum CatalogReadRoute: CaseIterable {
    case home, browse, search, detail, saved
    static let wallpaperID = "33333333-3333-4333-8333-333333333333"
    static let releaseID = "44444444-4444-4444-8444-444444444444"
    var name: String {
        switch self {
        case .home: "catalog_home"
        case .browse: "catalog_browse"
        case .search: "catalog_search"
        case .detail: "catalog_wallpaper_detail"
        case .saved: "my_saved_wallpapers"
        }
    }
    var v1: String { "/rest/v1/rpc/" + name + "_v1" }
    var v2: String { "/rest/v1/rpc/" + name + "_v2" }
    var parameters: [String: Any] {
        switch self {
        case .home: ["locale": "en-US", "rating_ceiling": "teen"]
        case .browse: ["category": "nature", "tags": ["night"], "sort": "newest", "cursor": "request-cursor", "limit": 12]
        case .search: ["query": "Ocean", "filters": ["sort": "newest", "category_slug": "nature", "tag_slugs": ["night"],
                                                  "content_rating_ceiling": "teen", "minimum_duration_ms": 1000, "maximum_duration_ms": 20000],
                      "cursor": "request-cursor", "limit": 12]
        case .detail: ["wallpaper_id": Self.wallpaperID]
        case .saved: ["cursor": "request-cursor", "limit": 24]
        }
    }

    func payload(legacy: Bool) throws -> Data {
        func artifact(_ role: String, digest: Character, type: String, duration: Int) -> [String: Any] {
            ["role": role, "url": "https://cdn.fixture.example/" + role, "sha256": String(repeating: digest, count: 64),
             "byte_count": 4096, "media_type": type, "width": 1920, "height": 1080, "duration_ms": duration]
        }
        var summary: [String: Any] = [
            "id": Self.wallpaperID, "slug": "ocean", "title": "Ocean",
            "creator": ["id": "11111111-1111-4111-8111-111111111111", "handle": "original_artist", "display_name": "Original Artist",
                        "avatar_url": NSNull(), "verification_status": "unverified"],
            "content_rating": "everyone",
            "primary_category": ["id": "22222222-2222-4222-8222-222222222222", "name": "Nature", "slug": "nature"],
            "approved_tags": [["id": "55555555-5555-4555-8555-555555555555", "name": "Night", "slug": "night"]],
            "poster": artifact("poster", digest: "a", type: "image/jpeg", duration: 0),
            "preview": artifact("preview", digest: "b", type: "video/mp4", duration: 12_000),
            "current_release_id": Self.releaseID, "revision": 7, "published_at": "2026-09-01T12:00:00.000000+00:00",
            "verified_install_count": 11, "favorite_count": 12, "save_count": 13,
        ]
        if !legacy { summary["media_kind"] = "video" }
        var result: [String: Any]
        switch self {
        case .home:
            result = ["sections": [["id": "new", "title": "New", "kind": "new", "cursor": "next-page", "items": [summary]]]]
        case .browse, .saved:
            result = ["items": [summary], "next_cursor": "next-page"]
        case .search:
            result = ["items": [summary], "next_cursor": "next-page", "ranking_explanation": ["formula_revision": "ranking-v1", "model_revision": "model-v1"]]
        case .detail:
            result = ["wallpaper": summary, "description": "A calm ocean loop.", "edition": 2, "rights_holder": "Original Artist",
                      "attribution_text": "Original Artist; supplied with permission.", "source_url": "https://artist.example/source",
                      "license": ["code": "wallpaper-use", "name": "Wallpaper Use", "terms_url": "https://artist.example/license",
                                  "attribution_required": true, "commercial_use_allowed": false, "derivatives_allowed": false,
                                  "redistribution_allowed": true, "terms_revision": 3],
                      "related": [summary], "is_favorite": true, "favorite_revision": 5, "is_saved": true, "saved_revision": 6]
            let video = artifact("video_default", digest: "c", type: "video/mp4", duration: 12_000)
            if legacy {
                result.merge(["duration_ms": 12_000, "width": 1920, "height": 1080, "frame_rate_numerator": 24,
                              "frame_rate_denominator": 1, "video_default": video]) { _, new in new }
            } else {
                result["media"] = ["kind": "video", "width": 1920, "height": 1080, "duration_ms": 12_000,
                                   "frame_rate_numerator": 24, "frame_rate_denominator": 1, "artifact": video]
            }
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

private struct CatalogReadResponse: Sendable {
    let status: Int
    let body: Data
    static var missing: Self { .failure(status: 404, code: "PGRST202") }
    static func success(_ body: Data) -> Self { .init(status: 200, body: body) }
    static func grant(apiVersion: String, mediaKind: String?) throws -> Self {
        func encoded(_ value: String) -> String {
            Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // The gateway test covers transport/shape only; cryptographic verification remains
        // in CatalogInstallPreparer and its existing signed-manifest tests.
        var payload: [String: Any] = ["wallpaper_id": CatalogReadRoute.wallpaperID, "release_id": CatalogReadRoute.releaseID,
            "manifest_body": encoded("fixture-manifest"), "metadata_body": encoded("fixture-metadata"),
            "signature": encoded("fixture-signature"), "key_id": "fixture", "install_receipt": "fixture-receipt",
            "expires_at": "2096-01-01T00:00:00Z"]
        if let mediaKind { payload["media_kind"] = mediaKind }
        return .success(try JSONSerialization.data(withJSONObject: ["api_version": apiVersion,
            "request_id": "fixture-request-id", "data": payload, "error": NSNull()]))
    }
    static func failure(status: Int, code: String) -> Self {
        .init(status: status, body: Data("{\"code\":\"\(code)\",\"message\":\"Fixture provider failure\",\"details\":null,\"hint\":null}".utf8))
    }
}

private struct CatalogReadFixture {
    static let nextSubject = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let gateway: SupabaseCatalogGateway
    let original: Session
    private let auth: AuthClient
    private let transport: URLSession
    private let host: String
    var requests: [CatalogReadCaptureProtocol.CapturedRequest] { CatalogReadCaptureProtocol.requests(host: host) }
    var currentSubject: UUID? { auth.currentSession?.user.id }

    init(responses: [CatalogReadResponse], switchAccountBeforeFirstReply: Bool = false) throws {
        host = "catalog-read-" + UUID().uuidString.lowercased() + ".example.test"
        let environment = try CatalogEnvironment(supabaseURL: URL(string: "https://" + host)!,
            publishableKey: "sb_publishable_unit_fixture", approvedCDNHosts: ["cdn.fixture.example"],
            signingKeyID: "fixture", signingPublicKey: Data(repeating: 1, count: 32), authenticationMethod: .emailOTP)
        original = Self.session(subject: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let next = Self.session(subject: Self.nextSubject)
        let memory = CatalogMemoryAuthStorage()
        try memory.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(original))
        let storage = CatalogCheckedAuthStorage(underlying: memory)
        auth = SupabaseSharedAuth.makeClient(environment: environment, storage: storage) { request in
            guard request.url?.lastPathComponent == "user" else { throw URLError(.unsupportedURL) }
            return (try AuthClient.Configuration.jsonEncoder.encode(next.user),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let shared = SupabaseSharedSession(auth: auth, storage: storage)
        let beforeReply: (@Sendable () async throws -> Void)? = switchAccountBeforeFirstReply ? { @Sendable in
            _ = try await shared.admit(CatalogEmailSessionCandidate(accessToken: next.accessToken, refreshToken: next.refreshToken,
                state: .init(userID: next.user.id.uuidString.lowercased(), expiresAt: Date(timeIntervalSince1970: next.expiresAt))))
        } : nil
        CatalogReadCaptureProtocol.install(responses, host: host, beforeFirstReply: beforeReply)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogReadCaptureProtocol.self]
        transport = URLSession(configuration: configuration)
        gateway = try SupabaseCatalogGateway(environment: environment,
            authSessionStore: AuthSessionStore(auth: auth, storage: storage, environment: environment), session: transport)
    }

    func close() {
        transport.invalidateAndCancel()
        CatalogReadCaptureProtocol.remove(host: host)
        Task { await auth.stopAutoRefresh() }
    }

    private static func session(subject: UUID) -> Session {
        func segment(_ value: String) -> String {
            Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // Synthetic unsigned session, held only in memory; all HTTP is intercepted.
        let token = segment("{\"alg\":\"HS256\"}") + "." + segment("{\"exp\":4000000000,\"sub\":\"\(subject.uuidString.lowercased())\"}") + ".fixture"
        return Session(accessToken: token, tokenType: "bearer", expiresIn: 3600, expiresAt: 4_000_000_000,
            refreshToken: "fixture-refresh-" + subject.uuidString.lowercased(),
            user: User(id: subject, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: .distantPast, updatedAt: .distantPast))
    }
}

// URLProtocol callbacks and fixture registrations cross queues. Both shared state and
// the bounded response task are mutex-protected; no request leaves the process.
private final class CatalogReadCaptureProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedRequest: Sendable {
        let path: String
        let method: String?
        let authorization: String?
        let body: Data?
    }
    private struct Entry: Sendable {
        let responses: [CatalogReadResponse]
        let beforeFirstReply: (@Sendable () async throws -> Void)?
        var requests: [CapturedRequest] = []
    }
    private static let entries = Mutex<[String: Entry]>([:])
    private let responseTask = Mutex<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable && data.count <= 65_536 {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        } else { body = nil }
        let captured = CapturedRequest(path: request.url?.path ?? "", method: request.httpMethod,
                                       authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        let reply = Self.entries.withLock { values -> (CatalogReadResponse, (@Sendable () async throws -> Void)?)? in
            guard let host = request.url?.host, var entry = values[host] else { return nil }
            let index = entry.requests.count
            entry.requests.append(captured)
            values[host] = entry
            guard index < entry.responses.count else { return nil }
            return (entry.responses[index], index == 0 ? entry.beforeFirstReply : nil)
        }
        let work = Task {
            do {
                guard let (response, beforeReply) = reply, let url = request.url else { throw URLError(.unsupportedURL) }
                try await beforeReply?()
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                var responseBody = response.body
                if let body = captured.body,
                   let requestJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let requestID = requestJSON["request_id"] as? String,
                   let text = String(data: responseBody, encoding: .utf8) {
                    responseBody = Data(text.replacingOccurrences(of: "fixture-request-id", with: requestID).utf8)
                }
                client?.urlProtocol(self, didLoad: responseBody)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        responseTask.withLock { $0 = work }
    }
    override func stopLoading() { responseTask.withLock { $0?.cancel(); $0 = nil } }
    static func install(_ responses: [CatalogReadResponse], host: String, beforeFirstReply: (@Sendable () async throws -> Void)?) {
        entries.withLock { $0[host] = Entry(responses: responses, beforeFirstReply: beforeFirstReply) }
    }
    static func requests(host: String) -> [CapturedRequest] { entries.withLock { $0[host]?.requests ?? [] } }
    static func remove(host: String) { entries.withLock { _ = $0.removeValue(forKey: host) } }
}
