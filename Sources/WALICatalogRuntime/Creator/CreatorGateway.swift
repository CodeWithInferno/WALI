import Foundation

public protocol CreatorStudioGateway: Sendable {
    func supportedUploadMediaTypes() async throws -> Set<CreatorUploadMediaType>
    func submissions(_ request: CreatorListRequest) async throws -> CreatorSubmissionPage
    func createUpload(_ request: CreatorUploadGrantRequest) async throws -> CreatorUploadSession
    func completeUpload(_ request: CreatorCompleteUploadRequest) async throws -> CreatorMutationResult
    func saveDraft(_ request: CreatorSaveDraftRequest) async throws -> CreatorMutationResult
    func processingStatus(submissionID: UUID, generation: UInt64) async throws -> CreatorProcessingStatus
    func submit(_ request: CreatorSubmitRequest) async throws -> CreatorMutationResult
    func withdraw(_ request: CreatorWithdrawRequest) async throws -> CreatorMutationResult
    func retryProcessing(_ request: CreatorRetryProcessingRequest) async throws -> CreatorMutationResult
    func retryPublication(_ request: CreatorRetryPublicationRequest) async throws -> CreatorMutationResult
}

public extension CreatorStudioGateway {
    func supportedUploadMediaTypes() async throws -> Set<CreatorUploadMediaType> {
        CreatorUploadMediaType.legacyVideo
    }

    func retryProcessing(_ request: CreatorRetryProcessingRequest) async throws -> CreatorMutationResult {
        throw CreatorContractError.invalidRequest
    }

    func retryPublication(_ request: CreatorRetryPublicationRequest) async throws -> CreatorMutationResult {
        throw CreatorContractError.invalidRequest
    }
}

public protocol ModerationGateway: Sendable {
    func moderationMetadata() async throws -> ModerationMetadata
    func queue(_ request: ModerationQueueRequest) async throws -> ModerationQueuePage
    func moderate(_ request: ModerationDecisionRequest) async throws -> ModerationDecisionResult
    func reports(_ request: ModerationReportQueueRequest) async throws -> ModerationReportPage
    func resolveReport(_ request: ModerationReportResolutionRequest) async throws -> ModerationReportResolution
    func publish(_ request: PublishReleaseRequest) async throws -> PublishedRelease
}

public extension ModerationGateway {
    func resolveReport(_ request: ModerationReportResolutionRequest) async throws -> ModerationReportResolution {
        throw CreatorContractError.invalidRequest
    }
    func publish(_ request: PublishReleaseRequest) async throws -> PublishedRelease {
        throw CreatorContractError.invalidRequest
    }
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
        "stale_revision",
        "revision_mismatch",
        "processing_generation_stale",
        "review_generation_stale",
        "checklist_stale",
        "review_state_conflict",
        "submission_state_conflict",
    ]

    private static let revocationCodes: Set<String> = [
        "authentication_required",
        "reauthentication_required",
        "account_suspended",
        "auth_required",
        "session_expired",
        "account_inactive",
        "creator_role_required",
        "creator_terms_required",
        "moderator_role_required",
        "mfa_required",
    ]
}
