import Foundation
import Supabase
import XCTest
@testable import WALICatalogRuntime

final class SupabaseMFASessionTests: XCTestCase {
    func testNewEnrollmentVerifiesImmediatelyDespiteEmptySDKFactorCache() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        let enrollment = try await fixture.store.beginTOTPEnrollment()
        XCTAssertEqual(fixture.auth.currentSession?.user.factors, [])

        let status = try await fixture.store.verifyTOTP(factorID: enrollment.factorID, code: "123456")

        XCTAssertEqual(status.subjectID, MFASDKFixture.subject.uuidString.lowercased())
        XCTAssertEqual(status.verifiedTOTPFactorID, enrollment.factorID)
        XCTAssertEqual(status.currentLevel, .aal2)
        XCTAssertTrue(status.isFresh())
        let requests = await fixture.server.requests
        XCTAssertTrue(requests.contains("POST /auth/v1/factors/\(enrollment.factorID)/challenge"))
        XCTAssertTrue(requests.contains("POST /auth/v1/factors/\(enrollment.factorID)/verify"))
    }

    func testNewEnrollmentCancelsImmediatelyDespiteEmptySDKFactorCache() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        let enrollment = try await fixture.store.beginTOTPEnrollment()
        XCTAssertEqual(fixture.auth.currentSession?.user.factors, [])

        try await fixture.store.cancelTOTPEnrollment(factorID: enrollment.factorID)

        let requests = await fixture.server.requests
        XCTAssertTrue(requests.contains("DELETE /auth/v1/factors/\(enrollment.factorID)"))
        let remaining = await fixture.server.factorIDs
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReenrollmentReconcilesAndRemovesExistingUnverifiedServerFactor() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        let old = try await fixture.store.beginTOTPEnrollment()

        let replacement = try await fixture.store.beginTOTPEnrollment()

        XCTAssertNotEqual(old.factorID, replacement.factorID)
        let requests = await fixture.server.requests
        XCTAssertTrue(requests.contains("DELETE /auth/v1/factors/\(old.factorID)"))
        let remaining = await fixture.server.factorIDs
        XCTAssertEqual(remaining, [replacement.factorID])
    }

    func testDifferentServerSubjectCannotAuthorizeVerificationOrCancellation() async throws {
        for verifying in [true, false] {
            let fixture = try MFASDKFixture()
            defer { Task { await fixture.auth.stopAutoRefresh() } }
            let enrollment = try await fixture.store.beginTOTPEnrollment()
            await fixture.server.returnDifferentSubject()
            do {
                if verifying {
                    _ = try await fixture.store.verifyTOTP(factorID: enrollment.factorID, code: "123456")
                } else {
                    try await fixture.store.cancelTOTPEnrollment(factorID: enrollment.factorID)
                }
                XCTFail("A different server subject authorized an MFA mutation")
            } catch {
                XCTAssertTrue(error is CatalogMappingError)
            }
            let requests = await fixture.server.requests
            XCTAssertFalse(requests.contains(where: { $0.contains("/challenge") || $0.contains("/verify") || $0.hasPrefix("DELETE ") }))
        }
    }

    func testCancellationUsesCurrentVerifiedStatusInsteadOfCachedUnverifiedStatus() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        let enrollment = try await fixture.store.beginTOTPEnrollment()
        await fixture.server.markVerified(enrollment.factorID)

        do {
            try await fixture.store.cancelTOTPEnrollment(factorID: enrollment.factorID)
            XCTFail("A verified server factor was treated as an unfinished enrollment")
        } catch {
            XCTAssertTrue(error is CatalogRequestError)
        }
        let requests = await fixture.server.requests
        XCTAssertFalse(requests.contains(where: { $0.hasPrefix("DELETE ") }))
    }
}

private struct MFASDKFixture: Sendable {
    static let subject = UUID(uuidString: "887b9e94-b5d2-4132-b014-430c2ac8bb3f")!
    let auth: AuthClient
    let store: AuthSessionStore
    let server: MFASDKServer

    init() throws {
        let environment = try CatalogEnvironment(
            supabaseURL: URL(string: "https://mfa-fixture.example")!,
            publishableKey: "sb_publishable_mfa_fixture",
            approvedCDNHosts: ["mfa-fixture.example"], signingKeyID: "fixture",
            signingPublicKey: Data(repeating: 1, count: 32), authenticationMethod: .emailOTP
        )
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(Self.session(factors: [], aal2: false)))
        let checked = CatalogCheckedAuthStorage(underlying: base)
        let server = MFASDKServer()
        self.server = server
        let auth = SupabaseSharedAuth.makeClient(environment: environment, storage: checked) {
            try await server.fetch($0)
        }
        self.auth = auth
        store = AuthSessionStore(auth: auth, storage: checked, environment: environment)
    }

    static func user(factors: [Factor], id: UUID = subject) -> User {
        User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated",
             createdAt: Date(timeIntervalSince1970: 1_000_000),
             updatedAt: Date(timeIntervalSince1970: 1_000_000), factors: factors)
    }

    static func session(factors: [Factor], aal2: Bool) throws -> Session {
        func segment(_ value: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: value).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let expiry = Date.now.timeIntervalSince1970 + 3600
        let payload: [String: Any] = [
            "exp": expiry, "sub": subject.uuidString.lowercased(), "aal": aal2 ? "aal2" : "aal1",
            "amr": [["method": aal2 ? "totp" : "otp", "timestamp": Int(Date.now.timeIntervalSince1970)]]
        ]
        // Unsigned fixture bytes accepted only by the intercepted, in-process SDK transport.
        let token = try segment(["alg": "HS256"]) + "." + segment(payload) + ".fixture"
        return Session(accessToken: token, tokenType: "bearer", expiresIn: 3600, expiresAt: expiry,
                       refreshToken: aal2 ? "fixture-mfa-refresh" : "fixture-original-refresh",
                       user: user(factors: factors))
    }
}

private actor MFASDKServer {
    private struct ServerFactor {
        let id: String
        var verified = false
    }
    private var factors: [ServerFactor] = []
    private var differentSubject = false
    private(set) var requests: [String] = []
    var factorIDs: [String] { factors.map(\.id) }

    func returnDifferentSubject() { differentSubject = true }
    func markVerified(_ id: String) {
        if let index = factors.firstIndex(where: { $0.id == id }) { factors[index].verified = true }
    }

    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url, url.host == "mfa-fixture.example", requests.count < 32 else {
            throw URLError(.unsupportedURL)
        }
        let method = request.httpMethod ?? "GET"
        requests.append("\(method) \(url.path)")
        let data: Data
        if method == "GET", url.path == "/auth/v1/user" {
            let user = MFASDKFixture.user(
                factors: try decodedFactors(),
                id: differentSubject ? UUID(uuidString: "57d7ddad-dd6f-4ef9-92d9-8b416da96d64")! : MFASDKFixture.subject
            )
            data = try AuthClient.Configuration.jsonEncoder.encode(user)
        } else if method == "POST", url.path == "/auth/v1/factors" {
            let id = UUID().uuidString.lowercased()
            factors.append(ServerFactor(id: id))
            data = try JSONSerialization.data(withJSONObject: [
                "id": id, "type": "totp",
                "totp": ["qr_code": "fixture", "secret": "JBSWY3DPEHPK3PXP",
                         "uri": "otpauth://totp/WALI:fixture?secret=JBSWY3DPEHPK3PXP&issuer=WALI"]
            ])
        } else {
            let parts = url.path.split(separator: "/")
            guard parts.count >= 4, parts[0] == "auth", parts[1] == "v1", parts[2] == "factors",
                  let index = factors.firstIndex(where: { $0.id == parts[3] }) else {
                throw URLError(.unsupportedURL)
            }
            if method == "DELETE", parts.count == 4 {
                let removed = factors.remove(at: index)
                data = try JSONSerialization.data(withJSONObject: ["id": removed.id])
            } else if method == "POST", parts.count == 5, parts[4] == "challenge" {
                data = try JSONSerialization.data(withJSONObject: [
                    "id": "b63f33d2-7aa6-490b-9ff5-3485e78c2ea2", "type": "totp",
                    "expires_at": Date.now.timeIntervalSince1970 + 60
                ])
            } else if method == "POST", parts.count == 5, parts[4] == "verify" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                guard body?["code"] as? String == "123456" else { throw URLError(.badServerResponse) }
                factors[index].verified = true
                data = try AuthClient.Configuration.jsonEncoder.encode(MFASDKFixture.session(factors: decodedFactors(), aal2: true))
            } else {
                throw URLError(.unsupportedURL)
            }
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }

    private func decodedFactors() throws -> [Factor] {
        let values = factors.map {
            ["id": $0.id, "friendly_name": "WALI account security", "factor_type": "totp",
             "status": $0.verified ? "verified" : "unverified",
             "created_at": "2026-09-10T00:00:00Z", "updated_at": "2026-09-10T00:00:00Z"]
        }
        return try AuthClient.Configuration.jsonDecoder.decode([Factor].self, from: JSONSerialization.data(withJSONObject: values))
    }
}
