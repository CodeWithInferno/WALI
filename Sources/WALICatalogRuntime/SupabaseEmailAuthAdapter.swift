import Foundation
import Supabase
import Synchronization

/// SDK AuthLocalStorage is synchronous. Mutex makes the small in-memory attempt store safely
/// Sendable without unchecked conformance; no attempt ever uses the shared Keychain service.
final class CatalogMemoryAuthStorage: AuthLocalStorage {
    private let values = Mutex<[String: Data]>([:])
    func store(key: String, value: Data) throws {
        guard key.utf8.count <= 256, value.count <= 262_144 else { throw CatalogEmailAuthError.unavailable }
        try values.withLock { values in
            guard values[key] != nil || values.count < 8 else { throw CatalogEmailAuthError.unavailable }
            values[key] = value
        }
    }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws { values.withLock { $0[key] = nil } }
    func removeAll() { values.withLock { $0.removeAll() } }
}

/// Every request carries the current foreground epoch through transport and decoding. A session
/// response authorizes one bounded storage write; admission/sign-out invalidates old authorizations.
/// This also covers the SDK's independent background refresh task, whose result can arrive late.
final class CatalogCheckedAuthStorage: AuthLocalStorage {
    static let sessionKey = "wali.marketplace.session"
    struct RequestTicket: Sendable {
        fileprivate let epoch: UInt64
        fileprivate let accessToken: String?
        fileprivate let refreshToken: String?
    }
    private struct AuthorizedWrite {
        let session: Session
        let ticket: RequestTicket
    }
    private struct Admission {
        let accessToken: String
        let original: Data?
        var staged: Data?
    }
    private struct State {
        var epoch: UInt64 = 0
        var admission: Admission?
        var authorizedWrites: [AuthorizedWrite] = []
        var allowsRemoval = false
        var signOutAccessToken: String?
        var blocked = false
    }
    private let underlying: any AuthLocalStorage
    private let state = Mutex(State())

    init(underlying: any AuthLocalStorage) { self.underlying = underlying }

    func store(key: String, value: Data) throws {
        guard value.count <= 262_144 else { throw CatalogEmailAuthError.admissionFailed }
        try state.withLock { state in
            guard !state.blocked else { throw CatalogEmailAuthError.admissionFailed }
            guard key == Self.sessionKey else { return try underlying.store(key: key, value: value) }
            let session = try JSONDecoder().decode(Session.self, from: value)
            if let admission = state.admission {
                guard session.accessToken == admission.accessToken else { throw CatalogEmailAuthError.superseded }
                state.admission?.staged = value
                return
            }
            // SDK migrations and user metadata updates may rewrite the same credentials. A new
            // credential pair needs an authorization from a response in this exact epoch.
            let current = try underlying.retrieve(key: key).flatMap { try JSONDecoder().decode(Session.self, from: $0) }
            let sameCredentials = current.map {
                $0.accessToken == session.accessToken && $0.refreshToken == session.refreshToken && $0.user.id == session.user.id
            } ?? false
            let authorizedIndex = state.authorizedWrites.firstIndex { $0.session == session }
            guard sameCredentials || authorizedIndex != nil else { throw CatalogEmailAuthError.superseded }
            if let authorizedIndex {
                let authorization = state.authorizedWrites.remove(at: authorizedIndex)
                guard try matches(authorization.ticket, state: state) else { throw CatalogEmailAuthError.superseded }
            }
            try underlying.store(key: key, value: value)
        }
    }

    func retrieve(key: String) throws -> Data? {
        try state.withLock { state in
            guard !state.blocked else { throw CatalogEmailAuthError.admissionFailed }
            if key == Self.sessionKey, let admission = state.admission { return admission.original }
            return try underlying.retrieve(key: key)
        }
    }

    func remove(key: String) throws {
        try state.withLock { state in
            guard !state.blocked else { throw CatalogEmailAuthError.admissionFailed }
            if key == Self.sessionKey {
                // SDK API-error cleanup has no request identity. Complete it atomically in
                // finishRequest instead, and deny a later stale, context-free SDK removal.
                guard state.allowsRemoval, state.admission == nil else { throw CatalogEmailAuthError.superseded }
            }
            try underlying.remove(key: key)
        }
    }

    func beginRequest(_ request: URLRequest, publicKey: String? = nil) throws -> RequestTicket {
        try state.withLock { state in
            guard !state.blocked else { throw CatalogEmailAuthError.admissionFailed }
            var accessToken: String?
            if let authorization = request.value(forHTTPHeaderField: "Authorization") {
                guard authorization.hasPrefix("Bearer "), authorization.utf8.count <= 16_391 else {
                    throw CatalogEmailAuthError.superseded
                }
                let token = String(authorization.dropFirst(7))
                if token != publicKey { accessToken = token }
            }
            var refreshToken: String?
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            if query?.contains(where: { $0.name == "grant_type" && $0.value == "refresh_token" }) == true {
                guard state.admission == nil, !state.allowsRemoval,
                      let data = request.httpBody, data.count <= 16_384,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["refresh_token"] as? String,
                      let currentData = try underlying.retrieve(key: Self.sessionKey),
                      let current = try? JSONDecoder().decode(Session.self, from: currentData),
                      current.refreshToken == token
                else { throw CatalogEmailAuthError.superseded }
                refreshToken = token
            }
            let ticket = RequestTicket(epoch: state.epoch, accessToken: accessToken, refreshToken: refreshToken)
            guard try matches(ticket, state: state) else { throw CatalogEmailAuthError.superseded }
            return ticket
        }
    }

    func finishRequest(_ ticket: RequestTicket, data: Data, response: URLResponse) throws {
        guard data.count <= 262_144 else { throw CatalogEmailAuthError.admissionFailed }
        try state.withLock { state in
            guard !state.blocked, try matches(ticket, state: state) else { throw CatalogEmailAuthError.superseded }
            guard let response = response as? HTTPURLResponse else { throw CatalogEmailAuthError.networkUnavailable }
            if (200..<300).contains(response.statusCode) {
                if let session = try? AuthClient.Configuration.jsonDecoder.decode(Session.self, from: data) {
                    if ticket.accessToken != nil || ticket.refreshToken != nil {
                        let current = try underlying.retrieve(key: Self.sessionKey)
                            .flatMap { try JSONDecoder().decode(Session.self, from: $0) }
                        guard current?.user.id == session.user.id else { throw CatalogEmailAuthError.superseded }
                    }
                    guard state.authorizedWrites.count < 8 else { throw CatalogEmailAuthError.admissionFailed }
                    state.authorizedWrites.append(AuthorizedWrite(session: session, ticket: ticket))
                }
            } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = (object["code"] ?? object["error_code"]) as? String,
                      ["session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used"].contains(code) {
                // Revalidate and remove under the same lock, before the SDK's unscoped cleanup.
                if state.admission == nil, ticket.accessToken != nil || ticket.refreshToken != nil {
                    try underlying.remove(key: Self.sessionKey)
                    state.epoch &+= 1
                    state.authorizedWrites.removeAll()
                }
            }
        }
    }

    func beginReplacement() throws {
        try state.withLock { state in
            guard !state.blocked, state.admission == nil else { throw CatalogEmailAuthError.admissionFailed }
            state.epoch &+= 1
            state.authorizedWrites.removeAll()
        }
    }

    func beginSignOut() throws {
        try state.withLock { state in
            guard !state.blocked, state.admission == nil else { throw CatalogEmailAuthError.admissionFailed }
            state.epoch &+= 1
            state.authorizedWrites.removeAll()
            state.signOutAccessToken = try underlying.retrieve(key: Self.sessionKey)
                .flatMap { try JSONDecoder().decode(Session.self, from: $0).accessToken }
            state.allowsRemoval = true
        }
    }

    func endSignOut() { state.withLock { $0.allowsRemoval = false; $0.signOutAccessToken = nil } }

    func beginAdmission(accessToken: String) throws {
        try state.withLock { state in
            guard !state.blocked, state.admission == nil else { throw CatalogEmailAuthError.admissionFailed }
            let original = try underlying.retrieve(key: Self.sessionKey)
            state.epoch &+= 1
            state.authorizedWrites.removeAll()
            state.admission = Admission(accessToken: accessToken, original: original)
        }
    }

    func finishAdmission(session: Session) throws {
        try state.withLock { state in
            guard let admission = state.admission, let data = admission.staged,
                  let staged = try? JSONDecoder().decode(Session.self, from: data), staged == session,
                  session.accessToken == admission.accessToken else { throw CatalogEmailAuthError.admissionFailed }
            do {
                try underlying.store(key: Self.sessionKey, value: data)
                guard try underlying.retrieve(key: Self.sessionKey) == data else { throw CatalogEmailAuthError.admissionFailed }
                state.admission = nil
            } catch {
                do {
                    if let original = admission.original { try underlying.store(key: Self.sessionKey, value: original) }
                    else { try underlying.remove(key: Self.sessionKey) }
                    guard try underlying.retrieve(key: Self.sessionKey) == admission.original else { throw CatalogEmailAuthError.admissionFailed }
                } catch { state.blocked = true }
                state.admission = nil
                throw CatalogEmailAuthError.admissionFailed
            }
        }
    }

    func abandonAdmission() { state.withLock { $0.admission = nil } }

    func verifySignedOut() throws {
        try state.withLock { state in
            guard !state.blocked, state.admission == nil,
                  try underlying.retrieve(key: Self.sessionKey) == nil else { throw CatalogEmailAuthError.admissionFailed }
        }
    }

    private func matches(_ ticket: RequestTicket, state: State) throws -> Bool {
        guard ticket.epoch == state.epoch else { return false }
        let current = try underlying.retrieve(key: Self.sessionKey)
            .flatMap { try JSONDecoder().decode(Session.self, from: $0) }
        if let refreshToken = ticket.refreshToken, current?.refreshToken != refreshToken { return false }
        if let accessToken = ticket.accessToken,
           current?.accessToken != accessToken,
           state.admission?.accessToken != accessToken,
           !(state.allowsRemoval && state.signOutAccessToken == accessToken) { return false }
        return true
    }
}

/// The API client deliberately has no auth-event listener. Only this standalone AuthClient owns
/// session persistence; the API client's supported accessToken callback reads accepted authority.
enum SupabaseSharedAuth {
    static func makeClient(
        environment: CatalogEnvironment,
        storage: CatalogCheckedAuthStorage,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) -> AuthClient {
        AuthClient(
            url: environment.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["Apikey": environment.publishableKey, "Authorization": "Bearer \(environment.publishableKey)"],
            storageKey: CatalogCheckedAuthStorage.sessionKey,
            localStorage: storage,
            fetch: { request in
                let ticket = try storage.beginRequest(request, publicKey: environment.publishableKey)
                let result = try await fetch(request)
                try storage.finishRequest(ticket, data: result.0, response: result.1)
                return result
            },
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: true
        )
    }

    static func makeDataClient(
        environment: CatalogEnvironment,
        authSessionStore: AuthSessionStore,
        session: URLSession
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: environment.supabaseURL,
            supabaseKey: environment.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: CatalogMemoryAuthStorage(),
                    autoRefreshToken: false,
                    accessToken: { await authSessionStore.accessToken() }
                ),
                global: .init(session: session)
            )
        )
    }
}

final class SupabaseEmailAttempt: CatalogEmailAttemptTransport {
    private let client: AuthClient
    private let storage: CatalogMemoryAuthStorage
    private let transport: URLSession

    init(
        environment: CatalogEnvironment,
        fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let transport = CatalogURLSessionFactory.redirectRejecting(configuration: configuration)
        let storage = CatalogMemoryAuthStorage()
        self.transport = transport
        self.storage = storage
        client = AuthClient(
            url: environment.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["Apikey": environment.publishableKey, "Authorization": "Bearer \(environment.publishableKey)"],
            storageKey: "wali.email.attempt",
            localStorage: storage,
            fetch: fetch ?? { try await transport.data(for: $0) },
            autoRefreshToken: false,
            emitLocalSessionAsInitialSession: true
        )
    }

    deinit { transport.invalidateAndCancel() }

    func requestCode(email: String) async throws {
        do {
            // Account creation is explicitly part of this flow; no request-only sign-in.
            try await client.signInWithOTP(email: email, shouldCreateUser: true)
        } catch { throw Self.safeError(error) }
    }

    func verifyCode(email: String, code: String) async throws -> CatalogEmailSessionCandidate {
        do {
            let response = try await client.verifyOTP(email: email, token: code, type: .email)
            guard let session = response.session,
                  (1...16_384).contains(session.accessToken.utf8.count),
                  (1...8_192).contains(session.refreshToken.utf8.count),
                  session.tokenType.lowercased() == "bearer",
                  let state = Self.activeState(session)
            else { throw CatalogEmailAuthError.invalidOrExpiredCode }
            return CatalogEmailSessionCandidate(accessToken: session.accessToken, refreshToken: session.refreshToken, state: state)
        } catch { throw Self.safeError(error) }
    }

    func discard() async {
        transport.invalidateAndCancel()
        storage.removeAll()
    }

    static func activeState(_ session: Session) -> CatalogAuthState? {
        let expiry = Date(timeIntervalSince1970: session.expiresAt)
        guard session.expiresAt.isFinite, expiry > .now else { return nil }
        return CatalogAuthState(userID: session.user.id.uuidString.lowercased(), expiresAt: expiry)
    }

    static func safeError(_ error: any Error) -> CatalogEmailAuthError {
        if let error = error as? CatalogEmailAuthError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .timedOut { return .timedOut }
            if error.code == .cancelled { return .cancelled }
            return .networkUnavailable
        }
        if case let AuthError.api(_, code, _, response) = error {
            if response.statusCode == 429 || code == .overRequestRateLimit || code == .overEmailSendRateLimit {
                return .rateLimited
            }
            if code == .otpExpired || response.statusCode == 400 || response.statusCode == 403 {
                return .invalidOrExpiredCode
            }
        }
        return .networkUnavailable
    }
}

struct SupabaseSharedSession: CatalogSharedSessionAdapter {
    let auth: AuthClient
    let storage: CatalogCheckedAuthStorage?

    func currentState() async -> CatalogAuthState? {
        // Shared SDK refresh events are observed separately. Avoid initiating an extra refresh
        // merely to process a queued event; network operations already use the SDK session API.
        auth.currentSession.flatMap(SupabaseEmailAttempt.activeState)
    }

    func changes() async -> AsyncStream<Void> {
        let changes = auth.authStateChanges
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await _ in changes {
                    if Task.isCancelled { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func admit(_ candidate: CatalogEmailSessionCandidate) async throws -> CatalogAuthState {
        guard let storage, candidate.state.expiresAt > .now else { throw CatalogEmailAuthError.admissionFailed }
        try storage.beginAdmission(accessToken: candidate.accessToken)
        do {
            let session = try await auth.setSession(accessToken: candidate.accessToken, refreshToken: candidate.refreshToken)
            guard let state = SupabaseEmailAttempt.activeState(session),
                  state.userID == candidate.state.userID,
                  session.accessToken == candidate.accessToken,
                  session.refreshToken == candidate.refreshToken else {
                throw CatalogEmailAuthError.admissionFailed
            }
            try storage.finishAdmission(session: session)
            return state
        } catch {
            storage.abandonAdmission()
            throw CatalogEmailAuthError.admissionFailed
        }
    }

    func signOut() async throws {
        do {
            try storage?.beginSignOut()
            defer { storage?.endSignOut() }
            try await auth.signOut(scope: .global)
            try storage?.verifySignedOut()
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw CatalogRemoteError(code: "sign_out_failed", safeMessage: nil, retryable: true) }
    }
}
