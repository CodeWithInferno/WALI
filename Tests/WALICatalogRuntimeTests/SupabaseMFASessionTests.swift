import Foundation
import Supabase
import XCTest
@testable import WALICatalogRuntime

final class SupabaseMFASessionTests: XCTestCase {
    func testEnrollmentAcceptsProductionSizedQRCodeThroughCheckedSDKTransport() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        await fixture.server.setEnrollmentRectangleCount(3_721)
        let originalSession = fixture.auth.currentSession

        let enrollment = try await fixture.store.beginTOTPEnrollment()

        XCTAssertEqual(enrollment.subjectID, MFASDKFixture.subject.uuidString.lowercased())
        XCTAssertEqual(enrollment.secret.count, 32)
        XCTAssertEqual(enrollment.uri.host, "totp")
        XCTAssertEqual(fixture.auth.currentSession, originalSession)
        let responseBytes = await fixture.server.enrollmentResponseByteCount
        XCTAssertGreaterThan(responseBytes, 262_144)
        XCTAssertLessThan(responseBytes, 1_048_576)
    }

    func testEnrollmentRejectsQRCodeResponseOverOneMiB() async throws {
        let fixture = try MFASDKFixture()
        defer { Task { await fixture.auth.stopAutoRefresh() } }
        await fixture.server.setEnrollmentRectangleCount(16_000)
        let originalSession = fixture.auth.currentSession

        do {
            _ = try await fixture.store.beginTOTPEnrollment()
            XCTFail("An oversized enrollment response passed checked transport")
        } catch {
            XCTAssertEqual((error as? CatalogRemoteError)?.code, "mfa_enrollment_failed")
        }

        let responseBytes = await fixture.server.enrollmentResponseByteCount
        XCTAssertGreaterThan(responseBytes, 1_048_576)
        XCTAssertEqual(fixture.auth.currentSession, originalSession)
    }

    func testLargeEnrollmentResponseAllowanceDoesNotApplyToOtherRequests() throws {
        let original = try MFASDKFixture.session(factors: [], aal2: false)
        let base = CatalogMemoryAuthStorage()
        let originalData = try JSONEncoder().encode(original)
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: originalData)
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let publicKey = "sb_publishable_mfa_fixture"
        let data = try MFASDKFixture.enrollmentResponse(rectangleCount: 3_721)
        XCTAssertGreaterThan(data.count, 262_144)
        let validBody = Data(#"{"factor_type":"totp","issuer":"WALI","friendly_name":"WALI account security"}"#.utf8)
        let cases: [(path: String, method: String, body: Data?, bearer: String?)] = [
            ("/auth/v1/user", "POST", validBody, original.accessToken),
            ("/auth/v1/token", "POST", validBody, original.accessToken),
            ("/auth/v1/factors/fixture/verify", "POST", validBody, original.accessToken),
            ("/auth/v1/factors", "GET", validBody, original.accessToken),
            ("/auth/v1/factors", "DELETE", validBody, original.accessToken),
            ("/auth/v1/factors", "POST", Data(#"{"factor_type":"phone"}"#.utf8), original.accessToken),
            ("/auth/v1/factors", "POST", Data(#"{"factor_type":"totp","issuer":false}"#.utf8), original.accessToken),
            ("/auth/v1/factors", "POST", Data(#"{"factor_type":"totp","unexpected":true}"#.utf8), original.accessToken),
            ("/auth/v1/factors", "POST", Data("invalid-json".utf8), original.accessToken),
            ("/auth/v1/factors", "POST", nil, original.accessToken),
            ("/auth/v1/factors", "POST", validBody, nil),
            ("/auth/v1/factors", "POST", validBody, publicKey)
        ]
        for value in cases {
            var request = URLRequest(url: URL(string: "https://mfa-fixture.example" + value.path)!)
            request.httpMethod = value.method
            request.httpBody = value.body
            if let bearer = value.bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            let ticket = try storage.beginRequest(request, publicKey: publicKey)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try storage.finishRequest(ticket, data: data, response: response), "\(value.method) \(value.path)") {
                XCTAssertEqual($0 as? CatalogEmailAuthError, .admissionFailed)
            }
        }
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), originalData)
        XCTAssertThrowsError(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: data)) {
            XCTAssertEqual($0 as? CatalogEmailAuthError, .admissionFailed)
        }
    }

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

    static func enrollmentResponse(
        factorID: String = "b25a41c6-0c01-4da3-9aaf-f6732faeb529", rectangleCount: Int
    ) throws -> Data {
        // GoTrue's QR.H SVG has 61 x 61 rectangles for a typical email enrollment.
        // Generate similarly sized valid SVG, not a checked-in blob or a real secret.
        let rectangle = #"<rect x="0" y="0" width="3" height="3" style="fill:rgb(0,0,0);stroke:none" />"# + "\n"
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="183" height="183">"#
            + String(repeating: rectangle, count: rectangleCount) + "</svg>"
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        return try JSONSerialization.data(withJSONObject: [
            "id": factorID, "type": "totp", "friendly_name": "WALI account security",
            "totp": ["qr_code": rectangleCount == 0 ? "fixture" : svg, "secret": secret,
                     "uri": "otpauth://totp/WALI:dummy@examples.io?algorithm=SHA1&digits=6&issuer=WALI&period=30&secret=\(secret)"]
        ])
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
    private var enrollmentRectangleCount = 0
    private(set) var enrollmentResponseByteCount = 0
    private(set) var requests: [String] = []
    var factorIDs: [String] { factors.map(\.id) }

    func returnDifferentSubject() { differentSubject = true }
    func setEnrollmentRectangleCount(_ value: Int) { enrollmentRectangleCount = value }
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
            data = try MFASDKFixture.enrollmentResponse(factorID: id, rectangleCount: enrollmentRectangleCount)
            enrollmentResponseByteCount = data.count
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
