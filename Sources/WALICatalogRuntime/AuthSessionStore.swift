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
    /// Atomically checks the subject under the existing session transition gate.
    /// Returns false when another account now owns the shared session.
    func signOut(expectedSubjectID: String) async throws -> Bool
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

public actor AuthSessionStore: CatalogAuthSessionProviding, AccountMFASessionProviding, CatalogEmailAuthenticating {
    private nonisolated let auth: AuthClient
    private nonisolated let storage: CatalogCheckedAuthStorage
    private nonisolated let authority: CatalogAuthAuthority
    private let nativeAppleEnabled: Bool

    init(auth: AuthClient, storage: CatalogCheckedAuthStorage, environment: CatalogEnvironment) {
        self.auth = auth
        self.storage = storage
        nativeAppleEnabled = environment.authenticationMethod == .nativeApple
        let factory: CatalogAuthAuthority.AttemptFactory?
        if environment.authenticationMethod == .emailOTP {
            factory = { @Sendable in SupabaseEmailAttempt(environment: environment) }
        } else {
            factory = nil
        }
        authority = CatalogAuthAuthority(shared: SupabaseSharedSession(auth: auth, storage: storage), attemptFactory: factory)
    }

    /// API requests obtain credentials through the same serialized foreground authority. A
    /// stale SDK refresh result is not usable unless its exact credentials survived persistence.
    func validatedSession() async throws -> Session {
        try await authority.withSessionTransition { try await self.validatedAuthSession() }
    }

    func accessToken() async -> String? {
        if let snapshot = CatalogRequestAuthentication.snapshot,
           snapshot.ownerID == ObjectIdentifier(self) {
            return snapshot.validAccessToken
        }
        do { return try await validatedSession().accessToken }
        catch { return nil }
    }

    private func validatedAuthSession() async throws -> Session {
        let returned = try await auth.session
        guard let persisted = auth.currentSession,
              Self.activeState(from: persisted) != nil,
              persisted.accessToken == returned.accessToken,
              persisted.refreshToken == returned.refreshToken,
              persisted.user.id == returned.user.id else { throw CatalogEmailAuthError.superseded }
        return persisted
    }

    public func currentState() async -> CatalogAuthState? { await authority.currentState() }
    public func stateChanges() async -> AsyncStream<CatalogAuthState?> { await authority.stateChanges() }

    public func beginEmailSignIn(email: String, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        try await authority.beginEmailSignIn(email: email, ownerID: ownerID)
    }

    public func resendEmailCode(attemptID: UUID, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        try await authority.resendEmailCode(attemptID: attemptID, ownerID: ownerID)
    }

    public func verifyEmailCode(
        code: String, attemptID: UUID, ownerID: UUID,
        onAdmissionCommitted: @escaping @Sendable () async -> Void
    ) async throws -> CatalogAuthState {
        try await authority.verifyEmailCode(code: code, attemptID: attemptID, ownerID: ownerID, onAdmissionCommitted: onAdmissionCommitted)
    }

    public func cancelEmailSignIn(attemptID: UUID, ownerID: UUID) async -> Bool {
        await authority.cancelEmailSignIn(attemptID: attemptID, ownerID: ownerID)
    }

    public func detachEmailSignIn(ownerID: UUID) async { await authority.detachEmailSignIn(ownerID: ownerID) }

    @discardableResult
    public func signInWithApple(idToken: String, nonce: String) async throws -> CatalogAuthState {
        guard !idToken.isEmpty,
              idToken.utf8.count <= 16_384,
              (16...256).contains(nonce.utf8.count)
        else {
            throw CatalogRequestError.invalidRequest
        }
        guard nativeAppleEnabled else { throw CatalogEmailAuthError.unavailable }
        return try await authority.withSessionTransition(replacingEmail: true) {
            try await self.performAppleSignIn(idToken: idToken, nonce: nonce)
        }
    }

    private func performAppleSignIn(idToken: String, nonce: String) async throws -> CatalogAuthState {
        do {
            try storage.beginReplacement()
            let session = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: nonce
                )
            )
            guard let state = Self.activeState(from: session), auth.currentSession == session else {
                throw CatalogRemoteError(
                    code: "authentication_failed",
                    safeMessage: nil,
                    retryable: false
                )
            }
            return state
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CatalogRemoteError(
                code: "authentication_failed",
                safeMessage: nil,
                retryable: false
            )
        }
    }

    public func signOut() async throws { try await authority.signOut() }
    public func signOut(expectedSubjectID: String) async throws -> Bool {
        try await authority.signOut(expectedSubjectID: expectedSubjectID)
    }

    public func mfaStatus() async throws -> CatalogMFAStatus {
        try await authority.withSessionTransition { try await self.performMFAStatus() }
    }

    private func performMFAStatus() async throws -> CatalogMFAStatus {
        do {
            let session = try await validatedAuthSession()
            guard let active = Self.activeState(from: session) else {
                throw CatalogRequestError.invalidRequest
            }
            let assurance = try await auth.mfa.getAuthenticatorAssuranceLevel()
            let factors = try await currentFactors(for: session)
            var verifiedTOTP: (id: String, updatedAt: Date)?
            for factor in factors where factor.factorType == "totp" && factor.status == .verified {
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
        try await authority.withSessionTransition { try await self.performTOTPEnrollment() }
    }

    private func performTOTPEnrollment() async throws -> CatalogTOTPEnrollment {
        do {
            let sessionBefore = try await validatedAuthSession()
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await currentFactors(for: sessionBefore)
            for factor in factors where factor.factorType == "totp"
                && factor.status == .unverified
                && factor.friendlyName == "WALI account security" {
                try await auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factor.id))
            }
            let response = try await auth.mfa.enroll(
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
                  let activeAfter = Self.activeState(from: try await validatedAuthSession()),
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
        try await authority.withSessionTransition { try await self.performTOTPVerification(factorID: factorID, code: code) }
    }

    private func performTOTPVerification(factorID: String, code: String) async throws -> CatalogMFAStatus {
        guard let factorID = Self.canonicalUUID(factorID),
              code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) })
        else { throw CatalogRequestError.invalidRequest }
        do {
            let sessionBefore = try await validatedAuthSession()
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await currentFactors(for: sessionBefore)
            guard factors.contains(where: {
                $0.id.lowercased() == factorID && $0.factorType == "totp"
            }) else { throw CatalogMappingError.invalidResponse }
            try await auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factorID, code: code)
            )
            let result = try await performMFAStatus()
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
        try await authority.withSessionTransition { try await self.performTOTPEnrollmentCancellation(factorID: factorID) }
    }

    private func performTOTPEnrollmentCancellation(factorID: String) async throws {
        guard let factorID = Self.canonicalUUID(factorID) else {
            throw CatalogRequestError.invalidRequest
        }
        do {
            let sessionBefore = try await validatedAuthSession()
            guard let active = Self.activeState(from: sessionBefore) else {
                throw CatalogRequestError.invalidRequest
            }
            let factors = try await currentFactors(for: sessionBefore)
            guard let factor = factors.first(where: { $0.id.lowercased() == factorID }),
                  factor.factorType == "totp",
                  factor.status == .unverified
            else { throw CatalogRequestError.invalidRequest }
            try await auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factorID))
            guard let activeAfter = Self.activeState(from: try await validatedAuthSession()),
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

    /// The SDK's listFactors reads cached session.user and enrollment does not refresh it.
    /// Reconcile with the authenticated server user inside the existing transition gate before
    /// using factor ownership or status, then revalidate the persisted foreground subject.
    private func currentFactors(for session: Session) async throws -> [Factor] {
        let user = try await auth.user(jwt: session.accessToken)
        let current = try await validatedAuthSession()
        guard user.id == session.user.id, current.user.id == session.user.id else {
            throw CatalogMappingError.invalidResponse
        }
        return user.factors ?? []
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
