import Foundation
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
final class CreatorStudioFlowTests: XCTestCase {
    func testAAL1CreatorKeepsWatchingUntilAutomaticPublicationFinishes() async throws {
        let id = UUID()
        let gateway = CreatorFlowGateway(submission: submission(id: id, state: .approved))
        let model = CreatorStudioModel(gateway: gateway, authorization: authorization(subject: "owner"))
        await model.loadSubmissions()
        XCTAssertTrue(model.canUseCreatorStudio)
        XCTAssertTrue(model.hasProcessingSubmissions, "Verified media awaiting publication must keep updating")
        await model.refreshProcessingSubmissions()
        XCTAssertEqual(model.submissions.first?.state, .published)
        XCTAssertFalse(model.hasProcessingSubmissions)
    }

    func testChangingAccountClearsPreviousCreatorSubmissions() async {
        let gateway = CreatorFlowGateway(submission: submission(id: UUID(), state: .processing))
        let model = CreatorStudioModel(gateway: gateway, authorization: authorization(subject: "first"))
        await model.loadSubmissions()
        XCTAssertEqual(model.submissions.count, 1)
        model.updateAuthorization(authorization(subject: "second"))
        XCTAssertTrue(model.submissions.isEmpty)
        XCTAssertNil(model.nextCursor)
    }

    func testLateWithdrawalFailureCannotRestrictTheNextAccount() async throws {
        let item = submission(id: UUID(), state: .processing)
        let gateway = CreatorFlowGateway(submission: item, holdWithdrawal: true)
        let model = CreatorStudioModel(gateway: gateway, authorization: authorization(subject: "first"))
        await model.loadSubmissions()
        let withdrawal = Task { await model.withdraw(item) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gateway.isWithdrawalWaiting) {
            guard ContinuousClock.now < deadline else { XCTFail("Withdrawal did not start"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
        model.updateAuthorization(authorization(subject: "second"))
        await gateway.releaseWithdrawal()
        await withdrawal.value
        XCTAssertTrue(model.canUseCreatorStudio)
        XCTAssertEqual(model.loadState, .idle)
        XCTAssertTrue(model.submissions.isEmpty)
    }

    private func authorization(subject: String) -> CreatorAuthorizationSnapshot {
        .init(subjectID: subject, accountIsActive: true, sessionExpiresAt: .now.addingTimeInterval(3600),
              creatorGrantRevision: 1, acceptedCreatorTermsVersion: "2026-09-12", currentCreatorTermsVersion: "2026-09-12",
              moderatorGrantRevision: nil, assuranceLevel: .aal1)
    }

    private func submission(id: UUID, state: CreatorSubmissionState) -> CreatorSubmission {
        .init(id: id, wallpaperID: nil, revision: 2, generation: 1, state: state, draft: nil, processing: nil,
              moderationReasonCodes: [], creatorFacingNote: nil, createdAt: .now, updatedAt: .now)
    }
}

private actor CreatorFlowGateway: CreatorStudioGateway {
    let submission: CreatorSubmission
    let holdWithdrawal: Bool
    private var withdrawal: CheckedContinuation<Void, Never>?
    var isWithdrawalWaiting: Bool { withdrawal != nil }
    init(submission: CreatorSubmission, holdWithdrawal: Bool = false) {
        self.submission = submission
        self.holdWithdrawal = holdWithdrawal
    }
    func submissions(_ request: CreatorListRequest) async throws -> CreatorSubmissionPage {
        .init(items: [submission], nextCursor: nil)
    }
    func processingStatus(submissionID: UUID, generation: UInt64) async throws -> CreatorProcessingStatus {
        .init(submissionID: submissionID, revision: 3, generation: generation, state: .published,
              progress: 1, safeErrorCode: nil, mediaFacts: nil, generatedVariants: [], duplicateWarning: false,
              suggestions: [], findings: [])
    }
    func createUpload(_ request: CreatorUploadGrantRequest) async throws -> CreatorUploadSession { throw CreatorContractError.invalidRequest }
    func completeUpload(_ request: CreatorCompleteUploadRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
    func saveDraft(_ request: CreatorSaveDraftRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
    func submit(_ request: CreatorSubmitRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
    func withdraw(_ request: CreatorWithdrawRequest) async throws -> CreatorMutationResult {
        if holdWithdrawal { await withCheckedContinuation { withdrawal = $0 } }
        throw CatalogRemoteError(code: "creator_role_required", safeMessage: nil, retryable: false)
    }
    func releaseWithdrawal() { withdrawal?.resume(); withdrawal = nil }
}
