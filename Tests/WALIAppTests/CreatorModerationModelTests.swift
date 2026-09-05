import Foundation
import WALICatalog
import WALICatalogRuntime
@testable import WALIAppRuntime
import XCTest

@MainActor
final class CreatorModerationModelTests: XCTestCase {
    func testQueuePublishesOnlyLocallyVerifiedCanonicalMedia() async throws {
        let artifact = try CreatorCanonicalArtifact.fixture()
        let item = ModerationQueueItem.fixture(canonicalArtifacts: [artifact])
        let localURL = URL(fileURLWithPath: "/private/tmp/verified-poster.jpg")
        let cache = RecordingPresentationMediaCache(result: .success(localURL))
        let model = CreatorModerationModel(
            gateway: ScriptedModerationGateway(queueItems: [item]),
            authorization: .moderatorFixture(expiresAt: .distantFuture),
            presentationMediaCache: cache
        )

        await model.loadQueue()

        XCTAssertEqual(model.localURL(for: artifact), localURL)
        XCTAssertTrue(model.localURL(for: artifact)?.isFileURL == true)
        let requestedIDs = await cache.requestedIDs()
        XCTAssertEqual(requestedIDs, [artifact.id])

        model.updateAuthorization(model.authorization.removingModeratorGrant())
        XCTAssertNil(model.localURL(for: artifact))
    }

    func testQueueIsHiddenAndProtectedDataIsClearedWhenServerGrantIsRemoved() async throws {
        let gateway = ScriptedModerationGateway(queueItems: [.fixture()])
        let model = CreatorModerationModel(
            gateway: gateway,
            authorization: .moderatorFixture(expiresAt: .distantFuture)
        )

        await model.loadQueue()
        XCTAssertTrue(model.canShowReviewQueue)
        XCTAssertEqual(model.queueItems.count, 1)

        model.updateAuthorization(model.authorization.removingModeratorGrant())

        XCTAssertFalse(model.canShowReviewQueue)
        XCTAssertTrue(model.queueItems.isEmpty)
        XCTAssertEqual(model.queueState, .restricted)
    }

    func testAuthorizedSubjectChangeClearsPreviousProtectedData() async throws {
        let gateway = ScriptedModerationGateway(queueItems: [.fixture()])
        let model = CreatorModerationModel(
            gateway: gateway,
            authorization: .moderatorFixture(expiresAt: .distantFuture)
        )
        await model.loadQueue()
        XCTAssertEqual(model.queueItems.count, 1)

        model.updateAuthorization(.init(
            subjectID: "22222222-2222-4222-8222-222222222222",
            accountIsActive: true,
            sessionExpiresAt: .distantFuture,
            creatorGrantRevision: 1,
            acceptedCreatorTermsVersion: "2026-09-01",
            currentCreatorTermsVersion: "2026-09-01",
            moderatorGrantRevision: 1,
            assuranceLevel: .aal2
        ))

        XCTAssertTrue(model.queueItems.isEmpty)
        XCTAssertTrue(model.reports.isEmpty)
        XCTAssertEqual(model.queueState, .idle)
    }

    func testDelayedReportsFromPreviousSubjectAreDiscarded() async throws {
        let report = ModerationReport(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            revision: 1,
            reasonCode: "rights_review",
            safeSummary: "Review requested.",
            createdAt: .now, status: .open,
            wallpaperID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            wallpaperRevision: 1, wallpaperTitle: "Reported wallpaper", wallpaperStatus: .published,
            releaseID: nil, edition: nil, canonicalArtifacts: []
        )
        let gateway = ScriptedModerationGateway(
            queueItems: [],
            reportItems: [report],
            reportDelay: .milliseconds(100)
        )
        let model = CreatorModerationModel(
            gateway: gateway,
            authorization: .moderatorFixture(expiresAt: .distantFuture)
        )

        let load = Task { await model.loadReports() }
        try await Task.sleep(for: .milliseconds(20))
        model.updateAuthorization(.init(
            subjectID: "22222222-2222-4222-8222-222222222222",
            accountIsActive: true,
            sessionExpiresAt: .distantFuture,
            creatorGrantRevision: 1,
            acceptedCreatorTermsVersion: "2026-09-01",
            currentCreatorTermsVersion: "2026-09-01",
            moderatorGrantRevision: 1,
            assuranceLevel: .aal2
        ))
        await load.value

        XCTAssertTrue(model.reports.isEmpty)
    }

    func testAAL1NeverLoadsProtectedQueueData() async {
        let gateway = ScriptedModerationGateway(queueItems: [.fixture()])
        let authorization = CreatorAuthorizationSnapshot
            .moderatorFixture(expiresAt: .distantFuture)
            .withAssuranceLevel(.aal1)
        let model = CreatorModerationModel(
            gateway: gateway,
            authorization: authorization
        )

        await model.loadQueue()

        XCTAssertFalse(model.canShowReviewQueue)
        let queueRequestCount = await gateway.queueRequestCount()
        XCTAssertEqual(queueRequestCount, 0)
        XCTAssertEqual(model.queueState, .restricted)
    }

    func testStaleModerationDecisionDiscardsProtectedSnapshotAndReloadsQueue() async throws {
        let first = ModerationQueueItem.fixture(revision: 5, generation: 2)
        let fresh = ModerationQueueItem.fixture(revision: 6, generation: 3)
        let gateway = ScriptedModerationGateway(
            queueBatches: [[first], [fresh]],
            moderationError: CatalogRemoteError(
                code: "review_generation_stale",
                safeMessage: nil,
                retryable: false
            )
        )
        let model = CreatorModerationModel(
            gateway: gateway,
            authorization: .moderatorFixture(expiresAt: .distantFuture)
        )
        await model.loadQueue()

        await model.moderate(
            first,
            decision: .changesRequested,
            checklistRevision: 1,
            reasonCodes: ["metadata_incomplete"],
            creatorNote: "Please add attribution.",
            privateNote: "Required by license."
        )

        let queueRequestCount = await gateway.queueRequestCount()
        let lastDecisionBinding = await gateway.lastDecisionBinding()
        XCTAssertEqual(queueRequestCount, 2)
        XCTAssertEqual(lastDecisionBinding, .init(revision: 5, generation: 2))
        XCTAssertEqual(model.queueItems.first?.revision, 6)
        XCTAssertEqual(model.decisionState, .staleReloaded)
    }
}

private actor ScriptedModerationGateway: ModerationGateway {
    private var queueBatches: [[ModerationQueueItem]]
    private let moderationError: CatalogRemoteError?
    private let reportItems: [ModerationReport]
    private let reportDelay: Duration
    private var queueRequests = 0
    private var lastBinding: DecisionBinding?

    init(
        queueItems: [ModerationQueueItem],
        reportItems: [ModerationReport] = [],
        reportDelay: Duration = .zero
    ) {
        queueBatches = [queueItems]
        moderationError = nil
        self.reportItems = reportItems
        self.reportDelay = reportDelay
    }

    init(queueBatches: [[ModerationQueueItem]], moderationError: CatalogRemoteError?) {
        self.queueBatches = queueBatches
        self.moderationError = moderationError
        reportItems = []
        reportDelay = .zero
    }

    func moderationMetadata() async throws -> ModerationMetadata {
        try ModerationMetadata(
            checklistRevision: 1,
            creatorNoteRequired: true,
            reasonCodes: [
                try ModerationReasonOption(
                    code: "metadata_issue",
                    label: "Metadata issue",
                    decisions: Set(ModerationDecision.allCases)
                ),
            ]
        )
    }

    func queue(_ request: ModerationQueueRequest) async throws -> ModerationQueuePage {
        queueRequests += 1
        let index = min(queueRequests - 1, queueBatches.count - 1)
        return ModerationQueuePage(items: queueBatches[index], nextCursor: nil)
    }

    func moderate(_ request: ModerationDecisionRequest) async throws -> ModerationDecisionResult {
        lastBinding = .init(
            revision: request.expectedRevision,
            generation: request.expectedGeneration
        )
        if let moderationError { throw moderationError }
        return ModerationDecisionResult(
            submissionID: request.submissionID,
            revision: request.expectedRevision + 1,
            generation: request.expectedGeneration,
            state: .changesRequested
        )
    }

    func reports(_ request: ModerationReportQueueRequest) async throws -> ModerationReportPage {
        if reportDelay != .zero { try await Task.sleep(for: reportDelay) }
        return ModerationReportPage(items: reportItems, nextCursor: nil)
    }

    func queueRequestCount() -> Int { queueRequests }
    func lastDecisionBinding() -> DecisionBinding? { lastBinding }

    struct DecisionBinding: Equatable, Sendable {
        let revision: UInt64
        let generation: UInt64
    }
}

private extension CreatorAuthorizationSnapshot {
    static func moderatorFixture(expiresAt: Date) -> Self {
        .init(
            subjectID: "11111111-1111-4111-8111-111111111111",
            accountIsActive: true,
            sessionExpiresAt: expiresAt,
            creatorGrantRevision: 1,
            acceptedCreatorTermsVersion: "2026-09-01",
            currentCreatorTermsVersion: "2026-09-01",
            moderatorGrantRevision: 1,
            assuranceLevel: .aal2
        )
    }
}

private extension ModerationQueueItem {
    static func fixture(
        revision: UInt64 = 5,
        generation: UInt64 = 2,
        canonicalArtifacts: [CreatorCanonicalArtifact] = []
    ) -> Self {
        .init(
            submissionID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            revision: revision,
            generation: generation,
            creator: .init(id: UUID(), handle: "creator_one", displayName: "Creator One"),
            proposedTitle: "Night Sky",
            proposedDescription: "A calm night sky.",
            primaryCategoryName: "Nature",
            tagNames: ["night"],
            contentRating: "everyone",
            attributionText: nil,
            sourceURL: nil,
            rightsSummary: "Original work · attested",
            proofStatus: .notRequired,
            canonicalArtifacts: canonicalArtifacts,
            mediaFacts: nil,
            findings: [],
            modelSuggestions: [],
            submittedAt: Date(timeIntervalSince1970: 900)
        )
    }
}

private extension CreatorCanonicalArtifact {
    static func fixture() throws -> Self {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.example.test"]
        )
        return try Self(
            role: .poster,
            url: XCTUnwrap(URL(string: "https://project.supabase.co/storage/v1/object/sign/processing-private/sha256/aa/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/poster.jpg?token=moderator-safe-token")),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1_024,
            mediaType: "image/jpeg",
            width: 1920,
            height: 1080,
            durationMilliseconds: 0,
            remoteURLPolicy: policy
        )
    }
}

private actor RecordingPresentationMediaCache: CatalogPresentationMediaCaching {
    private let result: Result<URL, Error>
    private var ids: [String] = []

    init(result: Result<URL, Error>) { self.result = result }

    func localURL(for artifact: CatalogArtifact) async throws -> URL {
        throw CatalogPresentationMediaCacheError.unsupportedArtifact
    }

    func localURL(for artifact: CreatorCanonicalArtifact) async throws -> URL {
        ids.append(artifact.id)
        return try result.get()
    }

    func requestedIDs() -> [String] { ids }
}
