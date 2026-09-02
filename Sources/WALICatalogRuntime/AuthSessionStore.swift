import Foundation
import Supabase

public struct CatalogAuthState: Sendable, Hashable {
    public let userID: String
    public let expiresAt: Date

    public init(userID: String, expiresAt: Date) {
        self.userID = userID
        self.expiresAt = expiresAt
    }
}

public protocol CatalogAuthSessionProviding: Sendable {
    func currentState() async -> CatalogAuthState?
    func stateChanges() async -> AsyncStream<CatalogAuthState?>
    func signOut() async throws
}

public enum CatalogAssuranceLevel: String, Sendable, Hashable {
    case aal1
    case aal2
}

public struct CatalogMFAStatus: Sendable, Hashable {
    public let subjectID: String
    public let currentLevel: CatalogAssuranceLevel
    public let verifiedTOTPFactorID: String?
    public let latestMFAAt: Date?

    public init(
        subjectID: String,
        currentLevel: CatalogAssuranceLevel,
        verifiedTOTPFactorID: String?,
        latestMFAAt: Date?
    ) {
        self.subjectID = subjectID
        self.currentLevel = currentLevel
        self.verifiedTOTPFactorID = verifiedTOTPFactorID
        self.latestMFAAt = latestMFAAt
    }

    public func isFresh(at date: Date = .now, maximumAge: TimeInterval = 300) -> Bool {
        guard currentLevel == .aal2, let latestMFAAt else { return false }
        let age = date.timeIntervalSince(latestMFAAt)
        return age >= -30 && age <= maximumAge
    }
}

public struct CatalogTOTPEnrollment: Sendable, Hashable {
    public let subjectID: String
    public let factorID: String
    public let secret: String
    public let uri: URL

    public init(subjectID: String, factorID: String, secret: String, uri: URL) {
        self.subjectID = subjectID
        self.factorID = factorID
        self.secret = secret
        self.uri = uri
    }
}

public protocol AccountMFASessionProviding: Sendable {
    func mfaStatus() async throws -> CatalogMFAStatus
    func beginTOTPEnrollment() async throws -> CatalogTOTPEnrollment
    func verifyTOTP(factorID: String, code: String) async throws -> CatalogMFAStatus
    func cancelTOTPEnrollment(factorID: String) async throws
}

public actor AuthSessionStore: CatalogAuthSessionProviding, AccountMFASessionProviding {
    private nonisolated let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func currentState() async -> CatalogAuthState? {
        do {
            return Self.activeState(from: try await client.auth.session)
        } catch {
            return nil
        }
    }

    public nonisolated func stateChanges() async -> AsyncStream<CatalogAuthState?> {
        let changes = client.auth.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await (_, session) in changes {
                    continuation.yield(session.flatMap(Self.activeState(from:)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    public func signInWithApple(idToken: String, nonce: String) async throws -> CatalogAuthState {
        guard !idToken.isEmpty,
              idToken.utf8.count <= 16_384,
              (16...256).contains(nonce.utf8.count)
        else {
            throw CatalogRequestError.invalidRequest
        }
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: nonce
                )
            )
            guard let state = Self.activeState(from: session) else {
                throw CatalogRemoteError(
                    code: "authentication_failed",
                    safeMessage: nil,
                    retryable: false
                )
            }
            return state
        } catch {
            throw CatalogRemoteError(
                code: "authentication_failed",
                safeMessage: nil,
                retryable: false
            )
        }
    }

    public func signOut() async throws {
        do {
            try await client.auth.signOut(scope: .global)
        } catch {
            throw CatalogRemoteError(
                code: "sign_out_failed",
                safeMessage: nil,
                retryable: true
            )
        }
    }

    public func mfaStatus() async throws -> CatalogMFAStatus {
        do {
            let session = try await client.auth.session
            guard let active = Self.activeState(from: session) else {
                throw CatalogRequestError.invalidRequest
            }
            let assurance = try await client.auth.mfa.getAuthenticatorAssuranceLevel()
            let factors = try await client.auth.mfa.listFactors()
            var verifiedTOTP: (id: String, updatedAt: Date)?
            for factor in factors.totp {
                guard let id = Self.canonicalUUID(factor.id) else {
                    throw CatalogMappingError.invalidResponse
                }
                if let current = verifiedTOTP {
                    if factor.updatedAt > current.updatedAt
                        || (factor.updatedAt == current.updatedAt && id > current.id) {
                        verifiedTOTP = (id, factor.updatedAt)
                    }
                } else {
                    verifiedTOTP = (id, factor.updatedAt)
                }
            }
            let latestMFAAt = assurance.currentAuthenticationMethods
                .filter { ["totp", "mfa", "webauthn"].contains($0.method.lowercased()) }
                .map { Date(timeIntervalSince1970: $0.timestamp) }
                .filter { $0.timeIntervalSince1970 > 0 }
                .max()
            return CatalogMFAStatus(
                subjectID: active.userID,
                currentLevel: assurance.currentLevel == "aal2" ? .aal2 : .aal1,
                verifiedTOTPFactorID: verifiedTOTP?.id,
                latestMFAAt: latestMFAAt
            )
        } catch let error as CatalogRequestError {
            throw error
        } catch let error as CatalogMappingError {
            throw error
        } catch {
            throw CatalogRemoteError(code: "mfa_unavailable", safeMessage: nil, retryable: true)
        }
    }

    public func beginTOTPEnrollment() async throws -> CatalogTOTPEnrollment {
        do {
            let sessionBefore = try await client.auth.session
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await client.auth.mfa.listFactors()
            for factor in factors.all where factor.factorType == "totp"
                && factor.status == .unverified
                && factor.friendlyName == "WALI account security" {
                try await client.auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factor.id))
            }
            let response = try await client.auth.mfa.enroll(
                params: .totp(issuer: "WALI", friendlyName: "WALI account security")
            )
            guard response.type == "totp",
                  let totp = response.totp,
                  let factorID = Self.canonicalUUID(response.id),
                  (16...256).contains(totp.secret.utf8.count),
                  totp.secret.utf8.allSatisfy({
                    (50...55).contains($0) || (65...90).contains($0)
                  }),
                  let uri = URL(string: totp.uri),
                  uri.scheme?.lowercased() == "otpauth",
                  uri.host?.lowercased() == "totp",
                  uri.user == nil,
                  uri.password == nil,
                  uri.absoluteString.utf8.count <= 2_048,
                  let activeAfter = Self.activeState(from: try await client.auth.session),
                  activeAfter.userID == active.userID
            else { throw CatalogMappingError.invalidResponse }
            return CatalogTOTPEnrollment(
                subjectID: active.userID,
                factorID: factorID,
                secret: totp.secret,
                uri: uri
            )
        } catch let error as CatalogRequestError {
            throw error
        } catch let error as CatalogMappingError {
            throw error
        } catch {
            throw CatalogRemoteError(code: "mfa_enrollment_failed", safeMessage: nil, retryable: true)
        }
    }

    public func verifyTOTP(factorID: String, code: String) async throws -> CatalogMFAStatus {
        guard let factorID = Self.canonicalUUID(factorID),
              code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) })
        else { throw CatalogRequestError.invalidRequest }
        do {
            let sessionBefore = try await client.auth.session
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await client.auth.mfa.listFactors()
            guard factors.all.contains(where: {
                $0.id.lowercased() == factorID && $0.factorType == "totp"
            }) else { throw CatalogMappingError.invalidResponse }
            try await client.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factorID, code: code)
            )
            let result = try await mfaStatus()
            guard result.subjectID == active.userID,
                  result.currentLevel == .aal2,
                  result.isFresh()
            else { throw CatalogMappingError.invalidResponse }
            return result
        } catch let error as CatalogRequestError {
            throw error
        } catch let error as CatalogMappingError {
            throw error
        } catch {
            throw CatalogRemoteError(code: "mfa_verification_failed", safeMessage: nil, retryable: false)
        }
    }

    public func cancelTOTPEnrollment(factorID: String) async throws {
        guard let factorID = Self.canonicalUUID(factorID) else {
            throw CatalogRequestError.invalidRequest
        }
        do {
            let sessionBefore = try await client.auth.session
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await client.auth.mfa.listFactors()
            guard let factor = factors.all.first(where: { $0.id.lowercased() == factorID }),
                  factor.factorType == "totp",
                  factor.status == .unverified
            else { throw CatalogRequestError.invalidRequest }
            try await client.auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factorID))
            guard let activeAfter = Self.activeState(from: try await client.auth.session),
                  activeAfter.userID == active.userID
            else { throw CatalogMappingError.invalidResponse }
        } catch let error as CatalogRequestError {
            throw error
        } catch let error as CatalogMappingError {
            throw error
        } catch {
            throw CatalogRemoteError(code: "mfa_enrollment_cancel_failed", safeMessage: nil, retryable: true)
        }
    }

    private nonisolated static func activeState(from session: Session) -> CatalogAuthState? {
        let state = CatalogAuthState(
            userID: session.user.id.uuidString.lowercased(),
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
        return state.expiresAt > .now ? state : nil
    }

    private nonisolated static func canonicalUUID(_ value: String) -> String? {
        let lowercased = value.lowercased()
        guard UUID(uuidString: lowercased)?.uuidString.lowercased() == lowercased else { return nil }
        return lowercased
    }
}
