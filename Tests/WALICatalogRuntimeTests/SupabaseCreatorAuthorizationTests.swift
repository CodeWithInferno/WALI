import Foundation
import Supabase
import Synchronization
import XCTest
@testable import WALICatalogRuntime

final class SupabaseCreatorAuthorizationTests: XCTestCase {
    func testNullTermsPreserveStaffGrantWithoutCreatorOrAAL1ReviewAccess() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: NSNull())
        defer { fixture.close() }
        let value = try await fixture.gateway.authorizationSnapshot()
        XCTAssertEqual(value.subjectID, CreatorAuthorizationFixture.subject.uuidString.lowercased())
        XCTAssertEqual(value.currentCreatorTermsVersion, "")
        XCTAssertEqual(value.moderatorGrantRevision, 7)
        XCTAssertFalse(value.canAccessCreatorStudio())
        XCTAssertFalse(value.canAccessModeration())
        XCTAssertEqual(fixture.paths, ["/rest/v1/rpc/creator_authorization_v1"])
    }

    func testNullTermsAllowOnlyActiveAAL2StaffReview() async throws {
        for (active, grant, expected) in [(true, true, true), (false, true, false), (true, false, false)] {
            let fixture = try CreatorAuthorizationFixture(terms: NSNull(), assurance: "aal2", active: active, staffGrant: grant)
            defer { fixture.close() }
            let value = try await fixture.gateway.authorizationSnapshot()
            XCTAssertEqual(value.canAccessModeration(), expected)
            XCTAssertFalse(value.canAccessCreatorStudio())
        }
    }

    func testPresentTermsRetainExactAcceptanceRequirement() async throws {
        for accepted in ["2026-09-01", "2026-08-01"] {
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-01", accepted: accepted)
            defer { fixture.close() }
            let value = try await fixture.gateway.authorizationSnapshot()
            XCTAssertEqual(value.currentCreatorTermsVersion, "2026-09-01")
            XCTAssertEqual(value.canAccessCreatorStudio(), accepted == "2026-09-01")
        }
    }

    func testPresentEmptyMalformedAndWrongTypeTermsStillFail() async throws {
        let invalid: [Any] = ["", "terms version", "\u{0000}", String(repeating: "x", count: 65), 42, true, ["2026-09-01"]]
        for terms in invalid {
            let fixture = try CreatorAuthorizationFixture(terms: terms)
            defer { fixture.close() }
            do {
                _ = try await fixture.gateway.authorizationSnapshot()
                XCTFail("Invalid present terms were accepted")
            } catch {}
        }
    }

    func testOmittedTermsFieldRemainsMalformed() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: NSNull(), omitTerms: true)
        defer { fixture.close() }
        do {
            _ = try await fixture.gateway.authorizationSnapshot()
            XCTFail("Missing terms field was accepted as an explicit null")
        } catch {}
    }
}

private struct CreatorAuthorizationFixture {
    static let subject = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let gateway: SupabaseCatalogGateway
    private let auth: AuthClient
    private let transport: URLSession
    private let host: String

    init(terms: Any, accepted: String? = nil, assurance: String = "aal1", active: Bool = true, staffGrant: Bool = true, omitTerms: Bool = false) throws {
        host = "creator-" + UUID().uuidString.lowercased() + ".example.test"
        let environment = try CatalogEnvironment(
            supabaseURL: URL(string: "https://" + host)!, publishableKey: "sb_publishable_unit_fixture",
            approvedCDNHosts: [host], signingKeyID: "fixture", signingPublicKey: Data(repeating: 1, count: 32),
            authenticationMethod: .emailOTP
        )
        func segment(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // Synthetic unsigned session; every HTTP request is intercepted below.
        let jwt = segment("{\"alg\":\"HS256\"}") + "." + segment("{\"exp\":4000000000,\"sub\":\"\(Self.subject.uuidString.lowercased())\"}") + ".fixture"
        let session = Session(accessToken: jwt, tokenType: "bearer", expiresIn: 3600, expiresAt: 4_000_000_000,
                              refreshToken: "fixture-refresh", user: User(id: Self.subject, appMetadata: [:], userMetadata: [:],
                              aud: "authenticated", createdAt: .distantPast, updatedAt: .distantPast))
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(session))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        auth = SupabaseSharedAuth.makeClient(environment: environment, storage: storage) { _ in
            throw URLError(.unsupportedURL)
        }
        let authStore = AuthSessionStore(auth: auth, storage: storage, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreatorAuthorizationProtocol.self]
        transport = URLSession(configuration: configuration)
        var body: [String: Any] = [
            "account_is_active": active,
            "session_expires_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: session.expiresAt)),
            "creator_grant_revision": 3,
            "accepted_creator_terms_version": accepted as Any? ?? NSNull(),
            "current_creator_terms_version": terms,
            "moderator_grant_revision": staffGrant ? 7 : NSNull(),
            "assurance_level": assurance,
        ]
        if omitTerms { body.removeValue(forKey: "current_creator_terms_version") }
        CreatorAuthorizationProtocol.install(try JSONSerialization.data(withJSONObject: body), host: host)
        gateway = try SupabaseCatalogGateway(environment: environment, authSessionStore: authStore, session: transport)
    }

    var paths: [String] { CreatorAuthorizationProtocol.paths(host: host) }
    func close() {
        transport.invalidateAndCancel()
        CreatorAuthorizationProtocol.remove(host: host)
        Task { await auth.stopAutoRefresh() }
    }
}

// Foundation invokes URLProtocol callbacks; all shared fixture data is protected by Mutex.
private final class CreatorAuthorizationProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry: Sendable { let body: Data; var paths: [String] = [] }
    private static let entries = Mutex<[String: Entry]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.entries.withLock { entries -> Data? in
            guard let host = request.url?.host, var entry = entries[host] else { return nil }
            entry.paths.append(request.url?.path ?? "")
            entries[host] = entry
            return entry.body
        }
        guard let body, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func install(_ body: Data, host: String) { entries.withLock { $0[host] = Entry(body: body) } }
    static func paths(host: String) -> [String] { entries.withLock { $0[host]?.paths ?? [] } }
    static func remove(host: String) { entries.withLock { _ = $0.removeValue(forKey: host) } }
}
