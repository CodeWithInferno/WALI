import Foundation
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
final class CreatorUploadFlowTests: XCTestCase {
    func testLegacyAndExplicitEmptyCapabilitiesPreventUnsupportedGrants() async throws {
        for (formats, hint) in [(CreatorUploadMediaType.legacyVideo, "image/png"), (Set<CreatorUploadMediaType>(), "video/mp4")] {
            let gateway = try UploadFlowGateway(formats: formats)
            let transport = UploadFlowTransport()
            let coordinator = coordinator(gateway: gateway, transport: transport)
            coordinator.start(fileURL: URL(fileURLWithPath: "/fixture/wallpaper.png"), declaredByteCount: 6,
                              containerHint: hint, draft: try DraftFixture().draft(), creatorTermsVersion: "2026-09-12")
            try await waitUntil { if case .failed = coordinator.state { return true }; if case .processing = coordinator.state { return true }; return false }
            XCTAssertEqual(coordinator.state, .failed(CreatorContractError.unsupportedUploadFormat.rawValue))
            XCTAssertFalse(coordinator.canRetry)
            let grants = await gateway.grantCount; let offsets = await transport.receivedOffsets
            XCTAssertEqual(grants, 0); XCTAssertTrue(offsets.isEmpty)
        }
    }

    func testExplicitImageCapabilityPermitsOneBoundUpload() async throws {
        let gateway = try UploadFlowGateway(formats: [.png])
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        coordinator.start(fileURL: URL(fileURLWithPath: "/fixture/wallpaper.png"), declaredByteCount: 6,
                          containerHint: "image/png", draft: try DraftFixture().draft(), creatorTermsVersion: "2026-09-12")
        try await waitUntil { if case .processing = coordinator.state { return true }; return false }
        let grants = await gateway.grants; let reads = await gateway.capabilityReadCount
        XCTAssertEqual(grants.map(\.containerHint), ["image/png"])
        XCTAssertEqual(reads, 1)
    }

    func testCapabilityRollbackWhileFormIsOpenPreventsNewImageGrant() async throws {
        let gateway = try UploadFlowGateway(formats: [.png])
        let transport = UploadFlowTransport()
        let coordinator = coordinator(gateway: gateway, transport: transport)
        let initial = try await coordinator.refreshSupportedMediaTypes()
        XCTAssertEqual(initial, [.png])
        await gateway.setFormats(CreatorUploadMediaType.legacyVideo)
        coordinator.start(fileURL: URL(fileURLWithPath: "/fixture/wallpaper.png"), declaredByteCount: 6,
                          containerHint: "image/png", draft: try DraftFixture().draft(), creatorTermsVersion: "2026-09-12")
        try await waitUntil { if case .failed = coordinator.state { return true }; if case .processing = coordinator.state { return true }; return false }
        XCTAssertEqual(coordinator.state, .failed(CreatorContractError.unsupportedUploadFormat.rawValue))
        let grants = await gateway.grantCount; let offsets = await transport.receivedOffsets
        XCTAssertEqual(grants, 0); XCTAssertTrue(offsets.isEmpty)
    }

    func testFailedCapabilityRefreshDiscardsCachedImageSupportBeforeGrant() async throws {
        let gateway = try UploadFlowGateway(formats: [.png])
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        _ = try await coordinator.refreshSupportedMediaTypes()
        await gateway.failCapabilities()
        coordinator.start(fileURL: URL(fileURLWithPath: "/fixture/wallpaper.png"), declaredByteCount: 6,
                          containerHint: "image/png", draft: try DraftFixture().draft(), creatorTermsVersion: "2026-09-12")
        try await waitUntil { if case .failed = coordinator.state { return true }; if case .processing = coordinator.state { return true }; return false }
        XCTAssertEqual(coordinator.state, .failed("temporarily_unavailable"))
        XCTAssertEqual(coordinator.supportedMediaTypes, CreatorUploadMediaType.legacyVideo)
        let grants = await gateway.grantCount; XCTAssertEqual(grants, 0)
    }

    func testAccountChangeRejectsAwaitedCapabilityResult() async throws {
        let gateway = try UploadFlowGateway(formats: [.png], holdCapabilities: true)
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        let lookup = Task { try await coordinator.refreshSupportedMediaTypes() }
        try await waitUntil { await gateway.isCapabilityWaiting }
        coordinator.updateAuthorization(authorization(subject: "second"))
        await gateway.releaseCapabilities()
        do { _ = try await lookup.value; XCTFail("Old account capability became current") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(coordinator.supportedMediaTypes, CreatorUploadMediaType.legacyVideo)
        let grants = await gateway.grantCount; XCTAssertEqual(grants, 0)
    }

    func testLicensedDraftRetainsAuthorCreditsWithoutDemandingPrivateProof() throws {
        let fixture = DraftFixture()
        let draft = try fixture.model.makeDraft(categories: fixture.categories, tags: [], licenses: fixture.licenses)
        XCTAssertEqual(draft.rights.basis, .licensed)
        XCTAssertEqual(draft.rights.rightsHolder, "Original artist")
        XCTAssertEqual(draft.rights.attributionText, "Art by Original artist; published with permission")
        XCTAssertTrue(draft.rights.proofObjectIDs.isEmpty)
        XCTAssertEqual(draft.title, "Ocean")
    }

    func testLicensedDraftRequiresExplicitPermissionSourceAndCredits() throws {
        let fixture = DraftFixture()
        fixture.model.attestsRights = false
        XCTAssertThrowsError(try fixture.draft())
        fixture.model.attestsRights = true
        fixture.model.sourceURL = ""
        XCTAssertThrowsError(try fixture.draft())
        fixture.model.sourceURL = "https://artist.example.test/ocean"
        fixture.model.attributionText = ""
        XCTAssertThrowsError(try fixture.draft())
    }

    func testDraftRejectsUnlistedCategoryTagAndLicense() throws {
        let fixture = DraftFixture()
        fixture.model.categoryID = UUID()
        XCTAssertThrowsError(try fixture.draft())
        fixture.model.categoryID = fixture.categories[0].id
        fixture.model.selectedTagIDs = [UUID()]
        XCTAssertThrowsError(try fixture.draft())
        fixture.model.selectedTagIDs = []
        fixture.model.licenseID = UUID()
        XCTAssertThrowsError(try fixture.draft())
    }

    func testOriginalDraftRejectsMalformedOptionalSourceInsteadOfDiscardingIt() throws {
        let fixture = DraftFixture()
        fixture.model.rightsBasis = .original
        fixture.model.sourceURL = "https://["
        XCTAssertThrowsError(try fixture.draft())
    }

    func testAdmissionRejectsCreditsPastTheServerLimitBeforeUploading() throws {
        let fixture = DraftFixture()
        fixture.model.attributionText = String(repeating: "a", count: 501)
        XCTAssertThrowsError(try fixture.draft())
        fixture.model.attributionText = String(repeating: "a", count: 500)
        XCTAssertNoThrow(try fixture.draft())
    }

    func testAAL1UploadCompletesWithBoundDraftAndTermsBeforeProcessing() async throws {
        let fixture = DraftFixture()
        let gateway = try UploadFlowGateway()
        let transport = UploadFlowTransport()
        let coordinator = coordinator(gateway: gateway, transport: transport)
        let draft = try fixture.draft()
        start(coordinator, draft: draft)
        try await waitUntil { if case .processing = coordinator.state { return true }; return false }
        let requests = await gateway.completions
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.draft, draft)
        XCTAssertEqual(requests.first?.creatorTermsVersion, "2026-09-12")
        let offsets = await transport.receivedOffsets
        XCTAssertEqual(offsets, [0, 3])
    }

    func testCompletionRetryReusesAdmissionAndUploadedBytes() async throws {
        let gateway = try UploadFlowGateway(failFirstCompletion: true)
        let transport = UploadFlowTransport()
        let coordinator = coordinator(gateway: gateway, transport: transport)
        start(coordinator, draft: try DraftFixture().draft())
        try await waitUntil { if case .failed = coordinator.state { return true }; return false }
        coordinator.retry()
        try await waitUntil { if case .processing = coordinator.state { return true }; return false }
        let requests = await gateway.completions
        let grantCount = await gateway.grantCount
        let offsets = await transport.receivedOffsets
        XCTAssertEqual(grantCount, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(offsets, [0, 3], "A completion retry must use the server offset without uploading twice")
    }

    func testChangingAccountDuringGrantRejectsOldReplyAndClearsDraft() async throws {
        let gateway = try UploadFlowGateway(holdGrant: true)
        let transport = UploadFlowTransport()
        let coordinator = coordinator(gateway: gateway, transport: transport)
        start(coordinator, draft: try DraftFixture().draft())
        try await waitUntil { await gateway.isGrantWaiting }
        coordinator.updateAuthorization(authorization(subject: "second"))
        XCTAssertEqual(coordinator.state, .idle)
        await gateway.releaseGrant()
        try await waitUntil { await gateway.didReturnGrant }
        coordinator.resume()
        await Task.yield()
        XCTAssertEqual(coordinator.state, .idle)
        let completions = await gateway.completions
        let offsets = await transport.receivedOffsets
        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(offsets.isEmpty)
    }

    func testPauseWhileGrantIsPendingIsVisibleAndResumeKeepsTheSameReservation() async throws {
        let gateway = try UploadFlowGateway(holdGrant: true)
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        start(coordinator, draft: try DraftFixture().draft())
        try await waitUntil { await gateway.isGrantWaiting }
        coordinator.pause()
        XCTAssertEqual(coordinator.state, .paused(nil))
        coordinator.resume()
        await gateway.releaseGrant()
        try await waitUntil { if case .processing = coordinator.state { return true }; return false }
        let grants = await gateway.grants
        XCTAssertEqual(grants.count, 2)
        XCTAssertEqual(grants.first?.idempotencyKey, grants.last?.idempotencyKey)
    }

    func testStaleTermsCannotObtainUploadGrant() async throws {
        let gateway = try UploadFlowGateway()
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        start(coordinator, draft: try DraftFixture().draft(), terms: "2026-09-01")
        XCTAssertEqual(coordinator.state, .restricted)
        let grantCount = await gateway.grantCount
        XCTAssertEqual(grantCount, 0)
    }

    func testSameAccountAccessRecoveryClearsBannerWithoutResettingValidUpload() async throws {
        let gateway = try UploadFlowGateway(holdGrant: true)
        let coordinator = coordinator(gateway: gateway, transport: UploadFlowTransport())
        coordinator.updateAuthorization(.init(
            subjectID: "first", accountIsActive: true, sessionExpiresAt: .now.addingTimeInterval(3600),
            creatorGrantRevision: nil, acceptedCreatorTermsVersion: nil, currentCreatorTermsVersion: "2026-09-12",
            moderatorGrantRevision: nil, assuranceLevel: .aal1
        ))
        XCTAssertEqual(coordinator.state, .restricted)
        coordinator.updateAuthorization(authorization(subject: "first"))
        XCTAssertEqual(coordinator.state, .idle, "Accepting the current terms must remove stale restricted presentation")

        start(coordinator, draft: try DraftFixture().draft())
        try await waitUntil { await gateway.isGrantWaiting }
        coordinator.updateAuthorization(authorization(subject: "first"))
        XCTAssertEqual(coordinator.state, .requestingGrant, "An unrelated valid refresh must preserve the upload")
        await gateway.releaseGrant()
        try await waitUntil { if case .processing = coordinator.state { return true }; return false }
        let grants = await gateway.grantCount
        XCTAssertEqual(grants, 1)
    }

    private func coordinator(gateway: UploadFlowGateway, transport: UploadFlowTransport) -> CreatorUploadCoordinator {
        let result = CreatorUploadCoordinator(gateway: gateway, transport: transport, uploader: .init(chunkSize: 3),
                                             makeSource: { _ in UploadFlowSource() })
        result.updateAuthorization(authorization(subject: "first"))
        return result
    }

    private func authorization(subject: String) -> CreatorAuthorizationSnapshot {
        .init(subjectID: subject, accountIsActive: true, sessionExpiresAt: .now.addingTimeInterval(3600),
              creatorGrantRevision: 1, acceptedCreatorTermsVersion: "2026-09-12", currentCreatorTermsVersion: "2026-09-12",
              moderatorGrantRevision: nil, assuranceLevel: .aal1)
    }

    private func start(_ coordinator: CreatorUploadCoordinator, draft: CreatorDraft, terms: String = "2026-09-12") {
        coordinator.start(fileURL: URL(fileURLWithPath: "/fixture/ocean.mp4"), declaredByteCount: 6,
                          containerHint: "video/mp4", draft: draft, creatorTermsVersion: terms)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Creator upload did not reach the expected state")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private struct DraftFixture {
    let model = CreatorUploadDraftModel(title: " Ocean ")
    let categories = [CreatorTaxonomyOption(id: UUID(), name: "Nature", slug: "nature")]
    let licenses = [CreatorLicenseOption(id: UUID(), name: "WALI Wallpaper Use License", code: "wali-wallpaper-use-2026-09-12",
                                        requirements: .init(requiresSourceURL: false, requiresAttribution: true, requiresProof: false))]
    init() {
        model.description = "A calm ocean loop"
        model.categoryID = categories[0].id
        model.licenseID = licenses[0].id
        model.rightsBasis = .licensed
        model.rightsHolder = "Original artist"
        model.sourceURL = "https://artist.example.test/ocean"
        model.attributionText = "Art by Original artist; published with permission"
        model.attestsRights = true
    }
    func draft() throws -> CreatorDraft { try model.makeDraft(categories: categories, tags: [], licenses: licenses) }
}

private struct UploadFlowSource: CreatorUploadSource {
    let byteCount: UInt64 = 6
    func beginAccess() async throws {}
    func endAccess() async {}
    func read(range: Range<UInt64>) async throws -> Data {
        Data("source".utf8).subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

private actor UploadFlowTransport: CreatorResumableUploadTransport {
    private var offset: UInt64 = 0
    private(set) var receivedOffsets: [UInt64] = []
    func uploadOffset(for session: CreatorUploadSession) async throws -> UInt64 { offset }
    func upload(_ chunk: Data, at offset: UInt64, in session: CreatorUploadSession) async throws -> UInt64 {
        receivedOffsets.append(offset)
        self.offset = offset + UInt64(chunk.count)
        return self.offset
    }
    func cancel(_ session: CreatorUploadSession) async {}
}

private actor UploadFlowGateway: CreatorStudioGateway {
    let session: CreatorUploadSession
    let failFirstCompletion: Bool
    let holdGrant: Bool
    var formats: Set<CreatorUploadMediaType>
    let holdCapabilities: Bool
    private var capabilityContinuation: CheckedContinuation<Void, Never>?
    private var capabilityFailure = false
    private(set) var capabilityReadCount = 0
    var isCapabilityWaiting: Bool { capabilityContinuation != nil }
    private var grantContinuation: CheckedContinuation<Void, Never>?
    private(set) var didReturnGrant = false
    private(set) var grantCount = 0
    private(set) var grants: [CreatorUploadGrantRequest] = []
    private(set) var completions: [CreatorCompleteUploadRequest] = []
    var isGrantWaiting: Bool { grantContinuation != nil }

    init(failFirstCompletion: Bool = false, holdGrant: Bool = false,
         formats: Set<CreatorUploadMediaType> = CreatorUploadMediaType.legacyVideo, holdCapabilities: Bool = false) throws {
        self.formats = formats
        self.holdCapabilities = holdCapabilities
        self.failFirstCompletion = failFirstCompletion
        self.holdGrant = holdGrant
        session = try .init(id: UUID(), revision: 1, endpoint: URL(string: "https://uploads.example.test/session")!,
                            requiredHeaders: ["Tus-Resumable": "1.0.0"], scopedUploadToken: "scoped-test-token",
                            expiresAt: .now.addingTimeInterval(3600), declaredByteCount: 6)
    }
    func supportedUploadMediaTypes() async throws -> Set<CreatorUploadMediaType> {
        capabilityReadCount += 1
        let captured = formats
        if holdCapabilities { await withCheckedContinuation { capabilityContinuation = $0 } }
        if capabilityFailure { throw URLError(.networkConnectionLost) }
        return captured
    }
    func setFormats(_ value: Set<CreatorUploadMediaType>) { formats = value }
    func failCapabilities() { capabilityFailure = true }
    func releaseCapabilities() { capabilityContinuation?.resume(); capabilityContinuation = nil }

    func createUpload(_ request: CreatorUploadGrantRequest) async throws -> CreatorUploadSession {
        grantCount += 1
        grants.append(request)
        if holdGrant, grantCount == 1 { await withCheckedContinuation { grantContinuation = $0 } }
        didReturnGrant = true
        return session
    }
    func releaseGrant() { grantContinuation?.resume(); grantContinuation = nil }
    func completeUpload(_ request: CreatorCompleteUploadRequest) async throws -> CreatorMutationResult {
        completions.append(request)
        if failFirstCompletion, completions.count == 1 { throw URLError(.networkConnectionLost) }
        return .init(submissionID: session.id, revision: 2, generation: 1, state: .processing)
    }
    func submissions(_ request: CreatorListRequest) async throws -> CreatorSubmissionPage { throw CreatorContractError.invalidRequest }
    func processingStatus(submissionID: UUID, generation: UInt64) async throws -> CreatorProcessingStatus { throw CreatorContractError.invalidRequest }
    func saveDraft(_ request: CreatorSaveDraftRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
    func submit(_ request: CreatorSubmitRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
    func withdraw(_ request: CreatorWithdrawRequest) async throws -> CreatorMutationResult { throw CreatorContractError.invalidRequest }
}
