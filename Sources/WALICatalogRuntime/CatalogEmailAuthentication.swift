import Foundation

public struct CatalogEmailAuthAttempt: Sendable, Hashable {
    public let id: UUID
    public let email: String
    public let resendAvailableAt: Date

    public init(id: UUID, email: String, resendAvailableAt: Date) {
        self.id = id
        self.email = email
        self.resendAvailableAt = resendAvailableAt
    }
}

/// These errors contain no server message, email, code, or session credential.
public enum CatalogEmailAuthError: Error, Sendable, Equatable {
    case invalidEmail
    case invalidCode
    case unavailable
    case expiredAttempt
    case attemptInProgress
    case resendTooSoon(retryAt: Date)
    case invalidOrExpiredCode
    case rateLimited
    case timedOut
    case networkUnavailable
    case admissionFailed
    case cancelled
    case superseded
}

public protocol CatalogEmailAuthenticating: Sendable {
    func beginEmailSignIn(email: String, ownerID: UUID) async throws -> CatalogEmailAuthAttempt
    func resendEmailCode(attemptID: UUID, ownerID: UUID) async throws -> CatalogEmailAuthAttempt
    func verifyEmailCode(
        code: String,
        attemptID: UUID,
        ownerID: UUID,
        onAdmissionCommitted: @escaping @Sendable () async -> Void
    ) async throws -> CatalogAuthState
    /// False means this attempt has committed to completion; it must not be shown as cancelled.
    func cancelEmailSignIn(attemptID: UUID, ownerID: UUID) async -> Bool
    func detachEmailSignIn(ownerID: UUID) async
}

// Credentials remain transient inside the foreground adapter. Deliberately not Codable.
struct CatalogEmailSessionCandidate: Sendable {
    let accessToken: String
    let refreshToken: String
    let state: CatalogAuthState
}

protocol CatalogEmailAttemptTransport: Sendable {
    func requestCode(email: String) async throws
    func verifyCode(email: String, code: String) async throws -> CatalogEmailSessionCandidate
    /// Destroys only this isolated client's transport/storage, never the shared session.
    func discard() async
}

protocol CatalogSharedSessionAdapter: Sendable {
    func currentState() async -> CatalogAuthState?
    /// Includes an expired stored session, which still needs scoped credential removal.
    func currentSubjectID() async -> String?
    func changes() async -> AsyncStream<Void>
    func admit(_ candidate: CatalogEmailSessionCandidate) async throws -> CatalogAuthState
    func signOut() async throws
}

enum CatalogEmailInput {
    static func email(_ value: String) throws -> String {
        // Check the original size before trimming, and never rewrite the local part's case.
        guard value.utf8.count <= 320 else { throw CatalogEmailAuthError.invalidEmail }
        let email = value.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard (3...254).contains(email.utf8.count),
              email.utf8.allSatisfy({ (33...126).contains($0) }),
              parts.count == 2,
              (1...64).contains(parts[0].utf8.count),
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."),
              !parts[0].contains(".."),
              parts[0].utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || "!#$%&'*+-/=?^_`{|}~.".utf8.contains($0)
              })
        else { throw CatalogEmailAuthError.invalidEmail }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                })
        }) else { throw CatalogEmailAuthError.invalidEmail }
        return email
    }

    static func code(_ value: String) throws -> String {
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw CatalogEmailAuthError.invalidCode
        }
        return value
    }
}
