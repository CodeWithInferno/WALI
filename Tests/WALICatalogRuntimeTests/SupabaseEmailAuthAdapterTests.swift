import Foundation
import Supabase
import Synchronization
import XCTest
@testable import WALICatalogRuntime

final class SupabaseEmailAuthAdapterTests: XCTestCase {
    func testPinnedSDKRequestsSignupAndVerifiesEmailCodeWithoutRedirect() async throws {
        let recorder = EmailRequestRecorder(session: makeSession())
        let attempt = SupabaseEmailAttempt(environment: try environment(), fetch: { try await recorder.fetch($0) })
        try await attempt.requestCode(email: "person@example.com")
        let candidate = try await attempt.verifyCode(email: "person@example.com", code: "123456")
        let requests = await recorder.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/auth/v1/otp", "/auth/v1/verify"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.query == nil && $0.httpMethod == "POST" })
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(request["email"] as? String, "person@example.com")
        XCTAssertEqual(request["create_user"] as? Bool, true)
        let verification = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(verification["type"] as? String, "email")
        XCTAssertEqual(verification["token"] as? String, "123456")
        XCTAssertEqual(candidate.state.userID, makeSession().user.id.uuidString.lowercased())
        await attempt.discard()
    }

    func testUserOnlyVerificationResponseCannotEstablishSession() async throws {
        let user = makeSession().user
        let data = try AuthClient.Configuration.jsonEncoder.encode(user)
        let attempt = SupabaseEmailAttempt(environment: try environment(), fetch: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await attempt.verifyCode(email: "person@example.com", code: "123456")
            XCTFail("User-only response authenticated")
        } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .invalidOrExpiredCode) }
        await attempt.discard()
    }

    func testSDKErrorBodiesDoNotEscapeSafeMapping() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: nil))
        let error = AuthError.api(message: "private server detail", errorCode: .overEmailSendRateLimit, underlyingData: Data("private body".utf8), underlyingResponse: response)
        XCTAssertEqual(SupabaseEmailAttempt.safeError(error), .rateLimited)
        XCTAssertEqual(SupabaseEmailAttempt.safeError(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(SupabaseEmailAttempt.safeError(URLError(.cancelled)), .cancelled)
    }

    func testAdmissionStagesSDKWritesUntilPersistenceIsAcknowledged() throws {
        let base = CatalogMemoryAuthStorage()
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let session = makeSession()
        let data = try JSONEncoder().encode(session)
        try storage.beginAdmission(accessToken: session.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: data)
        XCTAssertNil(try base.retrieve(key: CatalogCheckedAuthStorage.sessionKey))
        XCTAssertNil(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey))
        try storage.finishAdmission(session: session)
        XCTAssertEqual(try base.retrieve(key: CatalogCheckedAuthStorage.sessionKey), data)
    }

    func testFailedPersistenceRestoresExistingSessionWithoutGlobalSignOut() throws {
        let base = FailingAuthStorage()
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let original = makeSession(accessToken: "old-fixture-access")
        let originalData = try JSONEncoder().encode(original)
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: originalData)
        let new = makeSession()
        try storage.beginAdmission(accessToken: new.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(new))
        base.failNextStore()
        XCTAssertThrowsError(try storage.finishAdmission(session: new))
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), originalData)
    }

    func testStaleRefreshCannotOverwriteStagedAdmission() throws {
        let storage = CatalogCheckedAuthStorage(underlying: CatalogMemoryAuthStorage())
        let new = makeSession()
        let admittedData = try JSONEncoder().encode(new)
        try storage.beginAdmission(accessToken: new.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: admittedData)
        XCTAssertThrowsError(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(makeSession(accessToken: "obsolete-fixture-access"))))
        try storage.finishAdmission(session: new)
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), admittedData)
    }

    func testAcknowledgementFailureAndFailedRollbackFailClosed() throws {
        let base = FailingAuthStorage()
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let session = makeSession()
        try storage.beginAdmission(accessToken: session.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(session))
        base.failReadsAndRemoves()
        XCTAssertThrowsError(try storage.finishAdmission(session: session))
        XCTAssertThrowsError(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey))
        XCTAssertThrowsError(try storage.beginAdmission(accessToken: "another-fixture"))
    }

    func testSignOutCannotClaimSuccessIfSessionStillPersisted() throws {
        let base = CatalogMemoryAuthStorage()
        let storage = CatalogCheckedAuthStorage(underlying: base)
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(makeSession()))
        XCTAssertThrowsError(try storage.verifySignedOut())
        try storage.beginSignOut()
        try storage.remove(key: CatalogCheckedAuthStorage.sessionKey)
        storage.endSignOut()
        XCTAssertNoThrow(try storage.verifySignedOut())
    }

    private func environment() throws -> CatalogEnvironment {
        try CatalogEnvironment(supabaseURL: URL(string: "https://example.com")!, publishableKey: "test-public-key", approvedCDNHosts: ["example.com"], signingKeyID: "fixture", signingPublicKey: Data(repeating: 1, count: 32))
    }

    private func makeSession(accessToken: String = "new-fixture-access") -> Session {
        Session(accessToken: accessToken, tokenType: "bearer", expiresIn: 3600, expiresAt: 4_000_000_000, refreshToken: "fixture-refresh", user: User(id: UUID(uuidString: "ca53dd4a-f487-482a-99ed-3ac29ee1cd5f")!, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000)))
    }
}

private actor EmailRequestRecorder {
    let session: Session
    private(set) var requests: [URLRequest] = []
    init(session: Session) { self.session = session }
    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let data = request.url?.lastPathComponent == "otp" ? Data("{}".utf8) : try AuthClient.Configuration.jsonEncoder.encode(session)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class FailingAuthStorage: AuthLocalStorage {
    private struct State {
        var values: [String: Data] = [:]
        var failStore = false
        var failReads = false
        var failRemoves = false
    }
    private let state = Mutex(State())
    func store(key: String, value: Data) throws {
        try state.withLock {
            if $0.failStore { $0.failStore = false; throw CatalogEmailAuthError.admissionFailed }
            $0.values[key] = value
        }
    }
    func retrieve(key: String) throws -> Data? {
        try state.withLock {
            if $0.failReads { throw CatalogEmailAuthError.admissionFailed }
            return $0.values[key]
        }
    }
    func remove(key: String) throws {
        try state.withLock {
            if $0.failRemoves { throw CatalogEmailAuthError.admissionFailed }
            $0.values[key] = nil
        }
    }
    func failNextStore() { state.withLock { $0.failStore = true } }
    func failReadsAndRemoves() { state.withLock { $0.failReads = true; $0.failRemoves = true } }
}
