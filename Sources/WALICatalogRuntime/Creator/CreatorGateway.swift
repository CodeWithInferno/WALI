import Foundation

public protocol CreatorStudioGateway: Sendable {
    func submissions(_ request: CreatorListRequest) async throws -> CreatorSubmissionPage
    func createUpload(_ request: CreatorUploadGrantRequest) async throws -> CreatorUploadSession
    func completeUpload(_ request: CreatorCompleteUploadRequest) async throws -> CreatorMutationResult
    func saveDraft(_ request: CreatorSaveDraftRequest) async throws -> CreatorMutationResult
    func processingStatus(submissionID: UUID, generation: UInt64) async throws -> CreatorProcessingStatus
    func submit(_ request: CreatorSubmitRequest) async throws -> CreatorMutationResult
    func withdraw(_ request: CreatorWithdrawRequest) async throws -> CreatorMutationResult
}

public protocol ModerationGateway: Sendable {
    func moderationMetadata() async throws -> ModerationMetadata
    func queue(_ request: ModerationQueueRequest) async throws -> ModerationQueuePage
    func moderate(_ request: ModerationDecisionRequest) async throws -> ModerationDecisionResult
    func reports(_ request: ModerationReportQueueRequest) async throws -> ModerationReportPage
}

public protocol CreatorAuthorizationGateway: Sendable {
    /// Must be backed by current server grants. JWT role claims alone are insufficient.
    func authorizationSnapshot() async throws -> CreatorAuthorizationSnapshot
    func creatorMetadata() async throws -> CreatorMetadata
    func acceptCreatorTerms(
        expectedSubjectID: String,
        version: String,
        idempotencyKey: String
    ) async throws -> CreatorAuthorizationSnapshot
}

public enum CreatorRemoteFailureDisposition: Sendable, Equatable {
    case retryable
    case stale
    case accessRevoked
    case terminal

    public init(error: Error) {
        guard let error = error as? CatalogRemoteError else {
            self = .terminal
            return
        }
        if error.retryable {
            self = .retryable
        } else if Self.staleCodes.contains(error.code) {
            self = .stale
        } else if Self.revocationCodes.contains(error.code) {
            self = .accessRevoked
        } else {
            self = .terminal
        }
    }

    private static let staleCodes: Set<String> = [
        "revision_mismatch",
        "processing_generation_stale",
        "review_generation_stale",
        "checklist_stale",
        "review_state_conflict",
        "submission_state_conflict",
    ]

    private static let revocationCodes: Set<String> = [
        "auth_required",
        "session_expired",
        "account_inactive",
        "creator_role_required",
        "creator_terms_required",
        "moderator_role_required",
        "mfa_required",
    ]
}
