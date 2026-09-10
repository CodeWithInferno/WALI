import Foundation
import Supabase
import Synchronization
import XCTest
@testable import WALICatalogRuntime

final class SupabaseSessionAuthorityTests: XCTestCase {
    func testRealSDKLateRefreshCannotOverwriteNewAdmission() async throws {
        let fixture = try SDKSessionFixture()
        let refresh = Task { try await fixture.auth.refreshSession(refreshToken: fixture.original.refreshToken) }
        await fixture.server.refreshStarted.wait()
        _ = try await fixture.shared.admit(fixture.candidate)
        await fixture.server.resumeRefresh()
        do { _ = try await refresh.value; XCTFail("Old refresh survived new admission") }
        catch { XCTAssertEqual(error as? CatalogEmailAuthError, .superseded) }
        XCTAssertEqual(fixture.auth.currentSession?.accessToken, fixture.admitted.accessToken)
        XCTAssertEqual(fixture.auth.currentSession?.user.id, fixture.admitted.user.id)
        await fixture.auth.stopAutoRefresh()
    }

    func testRealSDKLateRefreshCannotRestoreSignedOutSession() async throws {
        let fixture = try SDKSessionFixture()
        let refresh = Task { try await fixture.auth.refreshSession(refreshToken: fixture.original.refreshToken) }
        await fixture.server.refreshStarted.wait()
        try await fixture.shared.signOut()
        await fixture.server.resumeRefresh()
        do { _ = try await refresh.value; XCTFail("Old refresh survived sign-out") }
        catch { XCTAssertEqual(error as? CatalogEmailAuthError, .superseded) }
        XCTAssertNil(fixture.auth.currentSession)
        XCTAssertNil(try fixture.base.retrieve(key: CatalogCheckedAuthStorage.sessionKey))
        await fixture.auth.stopAutoRefresh()
    }

    func testResponseAuthorizationExpiresBeforeLateSDKWrite() throws {
        let base = CatalogMemoryAuthStorage()
        let old = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "old")
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(old))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let request = URLRequest(url: URL(string: "https://example.com/auth/v1/token")!)
        let ticket = try storage.beginRequest(request)
        let refreshed = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "refreshed")
        try storage.finishRequest(ticket, data: AuthClient.Configuration.jsonEncoder.encode(refreshed), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let admitted = SDKSessionFixture.session(subject: SDKSessionFixture.secondID, suffix: "new")
        try storage.beginAdmission(accessToken: admitted.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(admitted))
        try storage.finishAdmission(session: admitted)
        XCTAssertThrowsError(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(refreshed)))
        XCTAssertThrowsError(try storage.remove(key: CatalogCheckedAuthStorage.sessionKey))
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), try JSONEncoder().encode(admitted))
    }

    func testRealSDKCurrentRefreshPersistsAndRestarts() async throws {
        let fixture = try SDKSessionFixture()
        await fixture.server.resumeRefresh()
        let refreshed = try await fixture.auth.refreshSession(refreshToken: fixture.original.refreshToken)
        XCTAssertEqual(refreshed.accessToken, fixture.refreshed.accessToken)
        XCTAssertEqual(fixture.auth.currentSession?.accessToken, fixture.refreshed.accessToken)
        await fixture.auth.stopAutoRefresh()
        let restartedStorage = CatalogCheckedAuthStorage(underlying: fixture.base)
        let restarted = SupabaseSharedAuth.makeClient(environment: try SDKSessionFixture.environment(), storage: restartedStorage) { _ in
            XCTFail("A valid restored session should not require transport")
            throw URLError(.notConnectedToInternet)
        }
        let restored = try await restarted.session
        XCTAssertEqual(restored.accessToken, fixture.refreshed.accessToken)
        await restarted.stopAutoRefresh()
    }

    func testRetryCannotBorrowNewEpochWithObsoleteBearerOrRefreshToken() throws {
        let original = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "old")
        let admitted = SDKSessionFixture.session(subject: SDKSessionFixture.secondID, suffix: "new")
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(original))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        try storage.beginAdmission(accessToken: admitted.accessToken)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(admitted))
        try storage.finishAdmission(session: admitted)
        var oldBearer = URLRequest(url: URL(string: "https://api-fixture.example/auth/v1/user")!)
        oldBearer.setValue("Bearer " + original.accessToken, forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try storage.beginRequest(oldBearer))
        var oldRefresh = URLRequest(url: URL(string: "https://api-fixture.example/auth/v1/token?grant_type=refresh_token")!)
        oldRefresh.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": original.refreshToken])
        XCTAssertThrowsError(try storage.beginRequest(oldRefresh))
        oldBearer.setValue("Bearer " + admitted.accessToken, forHTTPHeaderField: "Authorization")
        XCTAssertNoThrow(try storage.beginRequest(oldBearer))
    }

    func testSameEpochResponseCannotOverwriteNewerMFAOrRefreshCredentials() throws {
        let old = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "old")
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(old))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        var request = URLRequest(url: URL(string: "https://api-fixture.example/auth/v1/factors/fixture/verify")!)
        request.setValue("Bearer " + old.accessToken, forHTTPHeaderField: "Authorization")
        let firstTicket = try storage.beginRequest(request)
        let secondTicket = try storage.beginRequest(request)
        let first = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "first")
        let second = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "second")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try storage.finishRequest(firstTicket, data: AuthClient.Configuration.jsonEncoder.encode(first), response: response)
        try storage.finishRequest(secondTicket, data: AuthClient.Configuration.jsonEncoder.encode(second), response: response)
        try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(second))
        XCTAssertThrowsError(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(first)))
        let expired = Data("{\"code\":\"session_expired\"}".utf8)
        XCTAssertThrowsError(try storage.finishRequest(firstTicket, data: expired, response: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!))
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), try JSONEncoder().encode(second))
        var metadataUpdate = second
        metadataUpdate.user.email = "changed@example.com"
        XCTAssertNoThrow(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(metadataUpdate)))
    }

    func testExistingCredentialsCannotAcceptDifferentSubjectInSessionResponse() throws {
        let original = SDKSessionFixture.session(subject: SDKSessionFixture.firstID, suffix: "original")
        let different = SDKSessionFixture.session(subject: SDKSessionFixture.secondID, suffix: "different")
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(original))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        var bearerRequest = URLRequest(url: URL(string: "https://api-fixture.example/auth/v1/factors/fixture/verify")!)
        bearerRequest.setValue("Bearer " + original.accessToken, forHTTPHeaderField: "Authorization")
        var refreshRequest = URLRequest(url: URL(string: "https://api-fixture.example/auth/v1/token?grant_type=refresh_token")!)
        refreshRequest.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": original.refreshToken])
        for request in [bearerRequest, refreshRequest] {
            let ticket = try storage.beginRequest(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try storage.finishRequest(ticket, data: AuthClient.Configuration.jsonEncoder.encode(different), response: response))
        }
        XCTAssertThrowsError(try storage.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(different)))
        XCTAssertEqual(try storage.retrieve(key: CatalogCheckedAuthStorage.sessionKey), try JSONEncoder().encode(original))
    }

    func testFailedPersistenceNeverAuthorizesActualSDKFunctionsRequest() async throws {
        let base = SDKFailingStore()
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let admitted = SDKSessionFixture.session(subject: SDKSessionFixture.secondID, suffix: "new")
        let environment = try SDKSessionFixture.environment()
        let auth = SupabaseSharedAuth.makeClient(environment: environment, storage: storage) { request in
            let data = try AuthClient.Configuration.jsonEncoder.encode(admitted.user)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let authStore = AuthSessionStore(auth: auth, storage: storage, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKFunctionsCaptureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); Task { await auth.stopAutoRefresh() } }
        let dataClient = SupabaseSharedAuth.makeDataClient(environment: environment, authSessionStore: authStore, session: transport)
        _ = dataClient.functions
        let shared = SupabaseSharedSession(auth: auth, storage: storage)
        base.failNextStore()
        do {
            _ = try await shared.admit(SDKSessionFixture.candidate(admitted))
            XCTFail("Persistence failure authenticated")
        } catch { XCTAssertEqual(error as? CatalogEmailAuthError, .admissionFailed) }
        XCTAssertNil(auth.currentSession)
        let endpoint = "anonymous-" + UUID().uuidString.lowercased()
        try await dataClient.functions.invoke(endpoint)
        let request = try XCTUnwrap(SDKFunctionsCaptureProtocol.request(for: endpoint))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Apikey"), environment.publishableKey)
        let accepted = await authStore.currentState()
        XCTAssertNil(accepted)
    }

    func testActualGatewayDeletionRetryCannotRetargetNewAccount() async throws {
        let fixture = try SDKSessionFixture()
        let environment = try SDKSessionFixture.environment()
        let authStore = AuthSessionStore(auth: fixture.auth, storage: try XCTUnwrap(fixture.shared.storage), environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKFunctionsCaptureProtocol.self]
        let transport = URLSession(configuration: configuration)
        let scenario = SDKRetryScenario()
        SDKFunctionsCaptureProtocol.install(scenario, for: "request-account-deletion")
        defer {
            SDKFunctionsCaptureProtocol.install(nil, for: "request-account-deletion")
            transport.invalidateAndCancel()
            Task { await fixture.auth.stopAutoRefresh() }
        }
        let gateway = try SupabaseCatalogGateway(environment: environment, authSessionStore: authStore, session: transport)
        let request = Task {
            try await gateway.requestAccountDeletion(expectedProfileRevision: 1, confirmation: "DELETE MY WALI", idempotencyKey: UUID().uuidString.lowercased())
        }
        await scenario.firstRequest.wait()
        _ = try await fixture.shared.admit(fixture.candidate)
        await scenario.releaseFailure.signal()
        do { _ = try await request.value; XCTFail("Fixture deliberately supplies no successful deletion envelope") }
        catch {}
        let requests = await scenario.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, Array(repeating: "Bearer " + fixture.original.accessToken, count: 2))
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != "Bearer " + fixture.admitted.accessToken })
        XCTAssertEqual(fixture.auth.currentSession?.user.id, fixture.admitted.user.id)
    }

    func testNestedScopeRetainsOriginalAccountAndAnonymousOrExpiredScopeCannotUseNewAccount() async throws {
        let fixture = try SDKSessionFixture()
        let environment = try SDKSessionFixture.environment()
        let authStore = AuthSessionStore(auth: fixture.auth, storage: try XCTUnwrap(fixture.shared.storage), environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKFunctionsCaptureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); Task { await fixture.auth.stopAutoRefresh() } }
        let dataClient = SupabaseSharedAuth.makeDataClient(environment: environment, authSessionStore: authStore, session: transport)
        let nested = "nested-" + UUID().uuidString.lowercased()
        try await CatalogRequestAuthentication.withSnapshot(for: authStore) {
            _ = try await fixture.shared.admit(fixture.candidate)
            try await CatalogRequestAuthentication.withSnapshot(for: authStore) {
                try await dataClient.functions.invoke(nested)
            }
        }
        XCTAssertEqual(SDKFunctionsCaptureProtocol.request(for: nested)?.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixture.original.accessToken)
        let anonymous = "anonymous-scope-" + UUID().uuidString.lowercased()
        let anonymousScope = CatalogRequestAuthentication.Snapshot(ownerID: ObjectIdentifier(authStore), session: nil)
        try await CatalogRequestAuthentication.$snapshot.withValue(anonymousScope) {
            try await dataClient.functions.invoke(anonymous)
        }
        let anonymousRequest = try XCTUnwrap(SDKFunctionsCaptureProtocol.request(for: anonymous))
        XCTAssertNil(anonymousRequest.value(forHTTPHeaderField: "Authorization"))
        var expired = fixture.original
        expired.expiresAt = 1
        let expiredName = "expired-scope-" + UUID().uuidString.lowercased()
        let expiredScope = CatalogRequestAuthentication.Snapshot(ownerID: ObjectIdentifier(authStore), session: expired)
        try await CatalogRequestAuthentication.$snapshot.withValue(expiredScope) {
            try await dataClient.functions.invoke(expiredName)
        }
        let expiredRequest = try XCTUnwrap(SDKFunctionsCaptureProtocol.request(for: expiredName))
        XCTAssertNil(expiredRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(fixture.auth.currentSession?.user.id, fixture.admitted.user.id)
    }
}

private struct SDKSessionFixture: Sendable {
    static let firstID = UUID(uuidString: "ca53dd4a-f487-482a-99ed-3ac29ee1cd5f")!
    static let secondID = UUID(uuidString: "ca53dd4a-f487-482a-99ed-3ac29ee1cd5e")!
    let base = CatalogMemoryAuthStorage()
    let original: Session
    let refreshed: Session
    let admitted: Session
    let server: SDKPausedServer
    let auth: AuthClient
    let shared: SupabaseSharedSession
    var candidate: CatalogEmailSessionCandidate { Self.candidate(admitted) }

    init() throws {
        original = Self.session(subject: Self.firstID, suffix: "original")
        refreshed = Self.session(subject: Self.firstID, suffix: "refreshed")
        admitted = Self.session(subject: Self.secondID, suffix: "admitted")
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(original))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        let server = SDKPausedServer(refreshed: refreshed, admitted: admitted)
        self.server = server
        auth = SupabaseSharedAuth.makeClient(environment: try Self.environment(), storage: storage) { try await server.fetch($0) }
        shared = SupabaseSharedSession(auth: auth, storage: storage)
    }

    static func environment() throws -> CatalogEnvironment {
        try CatalogEnvironment(supabaseURL: URL(string: "https://api-fixture.example")!, publishableKey: "sb_publishable_unit_fixture", approvedCDNHosts: ["api-fixture.example"], signingKeyID: "fixture", signingPublicKey: Data(repeating: 1, count: 32), authenticationMethod: .emailOTP)
    }

    static func candidate(_ session: Session) -> CatalogEmailSessionCandidate {
        CatalogEmailSessionCandidate(accessToken: session.accessToken, refreshToken: session.refreshToken, state: CatalogAuthState(userID: session.user.id.uuidString.lowercased(), expiresAt: Date(timeIntervalSince1970: session.expiresAt)))
    }

    static func session(subject: UUID, suffix: String) -> Session {
        func segment(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // Synthetic, unsigned fixture. The intercepted user endpoint is the sole test authority.
        let jwt = segment("{\"alg\":\"HS256\"}") + "." + segment("{\"exp\":4000000000,\"sub\":\"\(subject.uuidString.lowercased())\",\"fixture\":\"\(suffix)\"}") + ".fixture"
        return Session(accessToken: jwt, tokenType: "bearer", expiresIn: 3600, expiresAt: 4_000_000_000, refreshToken: "fixture-refresh-" + suffix, user: User(id: subject, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000)))
    }
}

private actor SDKPausedServer {
    let refreshed: Session
    let admitted: Session
    let refreshStarted = SDKTestSignal()
    private let refreshRelease = SDKTestSignal()
    init(refreshed: Session, admitted: Session) { self.refreshed = refreshed; self.admitted = admitted }
    func resumeRefresh() async { await refreshRelease.signal() }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let data: Data
        switch request.url?.lastPathComponent {
        case "token":
            await refreshStarted.signal()
            await refreshRelease.wait()
            data = try AuthClient.Configuration.jsonEncoder.encode(refreshed)
        case "user": data = try AuthClient.Configuration.jsonEncoder.encode(admitted.user)
        case "logout": data = Data("{}".utf8)
        default: throw URLError(.unsupportedURL)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SDKTestSignal {
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func wait() async {
        if ready { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(5))
                timeout(id)
            }
        }
    }
    func signal() { ready = true; let pending = waiters; waiters.removeAll(); pending.values.forEach { $0.resume() } }
    private func timeout(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        XCTFail("SDK test synchronization timed out")
        waiter.resume()
    }
}

private final class SDKFailingStore: AuthLocalStorage {
    private let values = CatalogMemoryAuthStorage()
    private let failure = Mutex(false)
    func failNextStore() { failure.withLock { $0 = true } }
    func store(key: String, value: Data) throws {
        let fail = failure.withLock { let prior = $0; $0 = false; return prior }
        if fail { throw CatalogEmailAuthError.admissionFailed }
        try values.store(key: key, value: value)
    }
    func retrieve(key: String) throws -> Data? { try values.retrieve(key: key) }
    func remove(key: String) throws { try values.remove(key: key) }
}

private actor SDKRetryScenario {
    let firstRequest = SDKTestSignal()
    let releaseFailure = SDKTestSignal()
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) async -> Bool {
        requests.append(request)
        if requests.count == 1 {
            await firstRequest.signal()
            await releaseFailure.wait()
            return true
        }
        return false
    }
}

// Foundation owns each URLProtocol callback lifecycle. The cancellable fixture task and shared
// tables are protected by Mutex; capture is bounded and asynchronous barriers time out in 5s.
private final class SDKFunctionsCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let requests = Mutex<[String: URLRequest]>([:])
    private static let scenarios = Mutex<[String: SDKRetryScenario]>([:])
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api-fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock {
            if $0.count >= 32 { $0.removeAll() }
            $0[request.url!.lastPathComponent] = request
        }
        if let scenario = Self.scenarios.withLock({ $0[request.url!.lastPathComponent] }) {
            let requestSnapshot = request
            let protocolHandler = self
            let pending = Task { @Sendable [protocolHandler, requestSnapshot, scenario] in
                let shouldFail = await scenario.record(requestSnapshot)
                guard !Task.isCancelled else { return }
                if shouldFail { protocolHandler.failConnection() }
                else { protocolHandler.complete() }
            }
            loadingTask.withLock { $0 = pending }
            return
        }
        complete()
    }
    private func failConnection() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    private func complete() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { loadingTask.withLock { $0?.cancel(); $0 = nil } }
    static func request(for name: String) -> URLRequest? { requests.withLock { $0.removeValue(forKey: name) } }
    static func install(_ scenario: SDKRetryScenario?, for name: String) { scenarios.withLock { $0[name] = scenario } }
}
