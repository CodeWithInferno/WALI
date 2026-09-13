import Foundation
import Supabase

/// A bounded transport shared by the two foreground account-lifecycle endpoints.
/// It never follows redirects, persists cookies, caches responses, or logs bodies.
struct CatalogAccountHTTPTransport: Sendable {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = CatalogURLSessionFactory.redirectRejecting(configuration: configuration)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int = 4_096) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.url == request.url,
              response.expectedContentLength <= Int64(maximumResponseBytes)
        else { throw CatalogMappingError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw CatalogMappingError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

struct CatalogAppleAuthorizationBinder: Sendable {
    static let clientIDs: Set<String> = ["com.wali.store.WALI", "com.wali.store.development.WALI"]
    let environment: CatalogEnvironment
    let clientID: String
    private let transport = CatalogAccountHTTPTransport()

    func bind(session: Session, idToken: String, nonce: String, authorizationCode: String) async throws {
        guard Self.clientIDs.contains(clientID) else { throw CatalogRequestError.invalidConfiguration }
        let requestID = UUID().uuidString.lowercased()
        let subjectID = session.user.id.uuidString.lowercased()
        var request = URLRequest(url: environment.supabaseURL.appendingPathComponent("functions/v1/bind-apple-authorization"))
        request.httpMethod = "POST"
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(environment.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(requestID: requestID, clientID: clientID, idToken: idToken, nonce: nonce, authorizationCode: authorizationCode))
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CatalogRemoteError(code: "authentication_failed", safeMessage: nil, retryable: response.statusCode >= 500)
        }
        let envelope = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard envelope.apiVersion == "apple_authorization.v1", envelope.requestID == requestID,
              envelope.data.bound, envelope.data.subjectID == subjectID else { throw CatalogMappingError.invalidResponse }
    }
    private struct RequestBody: Encodable {
        let apiVersion = "apple_authorization.v1"
        let requestID: String
        let clientID: String
        let idToken: String
        let nonce: String
        let authorizationCode: String
        enum CodingKeys: String, CodingKey {
            case nonce
            case apiVersion = "api_version", requestID = "request_id", clientID = "client_id", idToken = "id_token", authorizationCode = "authorization_code"
        }
    }
    private struct ResponseBody: Decodable {
        let apiVersion: String
        let requestID: String
        let data: Binding
        struct Binding: Decodable {
            let bound: Bool
            let subjectID: String
            enum CodingKeys: String, CodingKey { case bound; case subjectID = "subject_id" }
        }
        enum CodingKeys: String, CodingKey { case data; case apiVersion = "api_version", requestID = "request_id" }
    }
}

/// Apple login uses isolated, memory-only SDK state until the server has retained
/// the revocation credential. Shared admission then uses the existing auth gate.
struct SupabaseAppleAttempt: Sendable {
    let environment: CatalogEnvironment
    let clientID: String?

    func signIn(idToken: String, nonce: String, authorizationCode: String) async throws -> CatalogEmailSessionCandidate {
        let memory = CatalogMemoryAuthStorage()
        let transport = CatalogAccountHTTPTransport()
        let client = AuthClient(url: environment.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["Apikey": environment.publishableKey, "Authorization": "Bearer \(environment.publishableKey)"],
            storageKey: "wali.apple.attempt", localStorage: memory,
            fetch: { request in
                let (data, response) = try await transport.send(request, maximumResponseBytes: 65_536)
                return (data, response)
            }, autoRefreshToken: false, emitLocalSessionAsInitialSession: true)
        defer { transport.session.invalidateAndCancel(); memory.removeAll() }
        let session = try await client.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
        guard let state = SupabaseEmailAttempt.activeState(session),
              (1...16_384).contains(session.accessToken.utf8.count),
              (1...8_192).contains(session.refreshToken.utf8.count), session.tokenType.lowercased() == "bearer"
        else { throw CatalogEmailAuthError.admissionFailed }
        if let clientID, CatalogAppleAuthorizationBinder.clientIDs.contains(clientID) {
            try await CatalogAppleAuthorizationBinder(environment: environment, clientID: clientID)
                .bind(session: session, idToken: idToken, nonce: nonce, authorizationCode: authorizationCode)
        }
        return CatalogEmailSessionCandidate(accessToken: session.accessToken, refreshToken: session.refreshToken, state: state)
    }
}
