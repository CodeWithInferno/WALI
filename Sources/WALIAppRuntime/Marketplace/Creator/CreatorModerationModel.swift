import Foundation
import Observation
import WALICatalogRuntime

public enum CreatorModerationQueueState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case empty
    case restricted
    case offline
    case failed
}

public enum CreatorModerationDecisionState: Sendable, Equatable {
    case idle
    case submitting
    case succeeded
    case staleReloaded
    case restricted
    case failed
}

public enum CreatorPublicationState: Sendable, Equatable {
    case idle
    case publishing
    case awaitingPromotion
    case published(PublishedRelease)
    case failed
}

@MainActor
@Observable
public final class CreatorModerationModel {
    public private(set) var authorization: CreatorAuthorizationSnapshot
    public private(set) var queueItems: [ModerationQueueItem] = []
    public private(set) var reports: [ModerationReport] = []
    public private(set) var localArtifactURLs: [String: URL] = [:]
    public private(set) var queueState: CreatorModerationQueueState = .idle
    public private(set) var reportsState: CreatorModerationQueueState = .idle
    public private(set) var reportDecisionState: CreatorModerationDecisionState = .idle
    public private(set) var reportResolution: ModerationReportResolution?
    public private(set) var reportsNextCursor: String?
    public private(set) var isLoadingMoreReports = false
    public private(set) var reportsPageError: String?
    public private(set) var decisionState: CreatorModerationDecisionState = .idle
    public private(set) var publicationState: CreatorPublicationState = .idle
    public var queueFilter = "pending"
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    public private(set) var pageError: String?
    public private(set) var queueErrorMessage = "Refresh to try again."

    public var canShowReviewQueue: Bool {
        !locallyRestricted && authorization.canAccessModeration(at: .now)
    }

    private let gateway: any ModerationGateway
    private let presentationMediaCache: (any CatalogPresentationMediaCaching)?
    private var locallyRestricted = false
    private var requestGeneration: UInt64 = 0
    private var reportsGeneration: UInt64 = 0
    private var queueMediaLease = CatalogMediaLease()
    private var reviewMediaLease = CatalogMediaLease()
    private var selectedReviewID: UUID?
    private var publicationRequest: PublishReleaseRequest?
    private var decisionRequest: ModerationDecisionRequest?
    private var reportRequest: ModerationReportResolutionRequest?
    private var selectedReportID: UUID?
    private var reportMediaLease = CatalogMediaLease()

    public init(
        gateway: any ModerationGateway,
        authorization: CreatorAuthorizationSnapshot,
        presentationMediaCache: (any CatalogPresentationMediaCaching)? = nil
    ) {
        self.gateway = gateway
        self.authorization = authorization
        self.presentationMediaCache = presentationMediaCache
    }

    public func localURL(for artifact: CreatorCanonicalArtifact) -> URL? {
        localArtifactURLs[artifact.id]
    }

    public func updateAuthorization(_ value: CreatorAuthorizationSnapshot) {
        guard authorization != value || locallyRestricted else { return }
        let subjectChanged = authorization.subjectID != value.subjectID
        authorization = value
        locallyRestricted = false
        requestGeneration &+= 1
        reportsGeneration &+= 1
        isLoadingMore = false
        isLoadingMoreReports = false
        if queueState == .loading { queueState = .idle }
        if reportsState == .loading { reportsState = .idle }
        if subjectChanged {
            clearProtectedData()
            queueState = .idle
            reportsState = .idle
            decisionState = .idle
            publicationState = .idle
            publicationRequest = nil
            decisionRequest = nil
            selectedReviewID = nil
        }
        guard canShowReviewQueue else {
            clearProtectedData()
            queueState = .restricted
            reportsState = .restricted
            decisionState = .restricted
            return
        }
        if queueState == .restricted { queueState = .idle }
        if reportsState == .restricted { reportsState = .idle }
        if decisionState == .restricted { decisionState = .idle }
    }

    public func loadQueue(more: Bool = false) async {
        guard !more || (nextCursor != nil && !isLoadingMore) else { return }
        guard canShowReviewQueue else {
            clearProtectedData()
            queueState = .restricted
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        let grantRevision = authorization.moderatorGrantRevision
        let cursor = more ? nextCursor : nil
        if more {
            guard cursor != nil, !isLoadingMore else { return }
            isLoadingMore = true
        } else {
            queueState = .loading
            nextCursor = nil
        }
        pageError = nil
        defer { if generation == requestGeneration { isLoadingMore = false } }
        do {
            let page = try await gateway.queue(try ModerationQueueRequest(status: queueFilter, cursor: cursor))
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            queueItems = more ? queueItems + page.items.filter { incoming in !queueItems.contains(where: { $0.id == incoming.id }) } : page.items
            nextCursor = page.nextCursor
            queueState = queueItems.isEmpty ? .empty : .ready
            if !more { localArtifactURLs = [:]; queueMediaLease = CatalogMediaLease() }
            // Rows become usable immediately; slow poster downloads never hold the whole queue.
            let cachedURLs = await cacheProtectedArtifacts(page.items)
            guard generation == requestGeneration,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            localArtifactURLs.merge(cachedURLs) { _, new in new }
        } catch is CancellationError {
            if generation == requestGeneration, queueState == .loading { queueState = .idle }
        } catch {
            guard generation == requestGeneration else { return }
            if more, CreatorRemoteFailureDisposition(error: error) != .accessRevoked {
                pageError = "More submissions couldn’t be loaded. Try again."
            } else { handleQueue(error) }
        }
    }

    public func prepareReview(_ item: ModerationQueueItem) {
        guard selectedReviewID != item.id else { return }
        selectedReviewID = item.id
        reviewMediaLease = CatalogMediaLease()
        decisionState = .idle
        publicationState = .idle
        publicationRequest = nil
        decisionRequest = nil
    }

    public func publish(_ item: ModerationQueueItem) async {
        guard canShowReviewQueue, item.state == .approved,
              publicationState != .publishing,
              let wallpaperID = item.wallpaperID, let wallpaperRevision = item.wallpaperRevision,
              queueItems.contains(where: { $0.id == item.id && $0.revision == item.revision && $0.generation == item.generation })
        else { return }
        if case .published = publicationState { return }
        let subject = authorization.subjectID
        let grantRevision = authorization.moderatorGrantRevision
        publicationState = .publishing
        do {
            let request: PublishReleaseRequest
            if let existing = publicationRequest, existing.submissionID == item.id,
               existing.expectedRevision == item.revision, existing.expectedGeneration == item.generation,
               existing.expectedWallpaperRevision == wallpaperRevision {
                request = existing
            } else {
                request = try PublishReleaseRequest(submissionID: item.id, expectedRevision: item.revision,
                    expectedGeneration: item.generation, expectedWallpaperRevision: wallpaperRevision,
                    idempotencyKey: UUID().uuidString.lowercased())
                publicationRequest = request
            }
            for attempt in 0..<6 {
                guard subject == authorization.subjectID, canShowReviewQueue,
                      grantRevision == authorization.moderatorGrantRevision,
                      selectedReviewID == item.id else { return }
                do {
                    let result = try await gateway.publish(request)
                    try Task.checkCancellation()
                    guard subject == authorization.subjectID, grantRevision == authorization.moderatorGrantRevision,
                          canShowReviewQueue, result.wallpaperID == wallpaperID,
                          selectedReviewID == item.id else { return }
                    publicationState = .published(result)
                    await loadQueue()
                    return
                } catch let error as CatalogRemoteError where error.code == "publication_promotion_pending" {
                    guard subject == authorization.subjectID, canShowReviewQueue,
                          grantRevision == authorization.moderatorGrantRevision, selectedReviewID == item.id else { return }
                    if attempt == 5 { publicationState = .awaitingPromotion; return }
                    try await Task.sleep(for: .seconds(3))
                }
            }
        } catch is CancellationError {
            if subject == authorization.subjectID, selectedReviewID == item.id { publicationState = .idle }
        } catch {
            guard subject == authorization.subjectID, selectedReviewID == item.id else { return }
            if CreatorRemoteFailureDisposition(error: error) == .accessRevoked { restrictLocally() }
            publicationState = .failed
        }
    }

    public func loadReports(more: Bool = false) async {
        guard !more || (reportsNextCursor != nil && !isLoadingMoreReports) else { return }
        guard canShowReviewQueue else {
            clearProtectedData()
            reportsState = .restricted
            return
        }
        reportsGeneration &+= 1
        let generation = reportsGeneration
        let grantRevision = authorization.moderatorGrantRevision
        let subjectID = authorization.subjectID
        let cursor = more ? reportsNextCursor : nil
        if more { isLoadingMoreReports = true }
        else { reportsState = .loading; reportsNextCursor = nil }
        reportsPageError = nil
        defer { if generation == reportsGeneration { isLoadingMoreReports = false } }
        do {
            let page = try await gateway.reports(try ModerationReportQueueRequest(cursor: cursor))
            try Task.checkCancellation()
            guard generation == reportsGeneration,
                  subjectID == authorization.subjectID,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            reports = more ? reports + page.items.filter { incoming in !reports.contains(where: { $0.id == incoming.id }) } : page.items
            reportsNextCursor = page.nextCursor
            reportsState = reports.isEmpty ? .empty : .ready
        } catch is CancellationError {
            if generation == reportsGeneration, reportsState == .loading { reportsState = .idle }
        } catch {
            guard generation == reportsGeneration,
                  subjectID == authorization.subjectID
            else { return }
            if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
                restrictLocally()
            } else if more {
                reportsPageError = "More reports couldn’t be loaded. Try again."
            } else {
                reports = []
                reportsState = .failed
            }
        }
    }

    public func prepareReport(_ report: ModerationReport) {
        guard selectedReportID != report.id else { return }
        selectedReportID = report.id
        reportDecisionState = .idle
        reportResolution = nil
        reportRequest = nil
        reportMediaLease = CatalogMediaLease()
    }

    public func finishReport(_ report: ModerationReport) {
        guard selectedReportID == report.id else { return }
        selectedReportID = nil
        reportMediaLease = CatalogMediaLease()
    }

    public func loadReportMedia(_ report: ModerationReport) async -> CreatorReviewMedia? {
        guard canShowReviewQueue, let presentationMediaCache,
              reports.contains(where: { $0.id == report.id && $0.revision == report.revision }),
              let artifact = primaryArtifact(report.canonicalArtifacts)
        else { return nil }
        let subject = authorization.subjectID
        let grantRevision = authorization.moderatorGrantRevision
        let lease = reportMediaLease
        do {
            let url = try await presentationMediaCache.localURL(for: artifact, retaining: lease)
            try Task.checkCancellation()
            guard url.isFileURL, canShowReviewQueue, subject == authorization.subjectID,
                  grantRevision == authorization.moderatorGrantRevision, selectedReportID == report.id,
                  reportMediaLease === lease,
                  reports.contains(where: { $0.id == report.id && $0.revision == report.revision && $0.wallpaperRevision == report.wallpaperRevision })
            else { return nil }
            return media(artifact, at: url)
        } catch { return nil }
    }

    public func resolveReport(_ report: ModerationReport, action: ModerationReportAction,
                              reasonCode: String, privateNote: String) async {
        guard canShowReviewQueue, selectedReportID == report.id,
              reportDecisionState != .submitting, reportDecisionState != .succeeded,
              reports.contains(where: { $0.id == report.id && $0.revision == report.revision && $0.wallpaperRevision == report.wallpaperRevision })
        else { return }
        let subject = authorization.subjectID
        let grantRevision = authorization.moderatorGrantRevision
        reportDecisionState = .submitting
        do {
            var candidate = try ModerationReportResolutionRequest(report: report, action: action,
                reasonCode: reasonCode, privateNote: privateNote,
                idempotencyKey: reportRequest?.idempotencyKey ?? UUID().uuidString.lowercased())
            if let previous = reportRequest, previous != candidate {
                candidate = try ModerationReportResolutionRequest(report: report, action: action,
                    reasonCode: reasonCode, privateNote: privateNote, idempotencyKey: UUID().uuidString.lowercased())
            }
            reportRequest = candidate
            let result = try await gateway.resolveReport(candidate)
            guard subject == authorization.subjectID, grantRevision == authorization.moderatorGrantRevision,
                  selectedReportID == report.id, canShowReviewQueue else { return }
            reportResolution = result
            reportDecisionState = .succeeded
            await loadReports()
        } catch {
            guard subject == authorization.subjectID, selectedReportID == report.id else { return }
            switch CreatorRemoteFailureDisposition(error: error) {
            case .accessRevoked: restrictLocally()
            case .stale:
                await loadReports()
                reportDecisionState = .staleReloaded
            default: reportDecisionState = .failed
            }
        }
    }

    public func finishReview(_ item: ModerationQueueItem) {
        guard selectedReviewID == item.id else { return }
        selectedReviewID = nil
        reviewMediaLease = CatalogMediaLease()
    }

    public func loadReviewMedia(for item: ModerationQueueItem) async -> CreatorReviewMedia? {
        guard canShowReviewQueue, let presentationMediaCache,
              queueItems.contains(where: { $0.id == item.id && $0.revision == item.revision }),
              let artifact = primaryArtifact(item.canonicalArtifacts)
        else { return nil }
        let subject = authorization.subjectID
        let grantRevision = authorization.moderatorGrantRevision
        let lease = reviewMediaLease
        do {
            let url = try await presentationMediaCache.localURL(for: artifact, retaining: lease)
            try Task.checkCancellation()
            guard url.isFileURL, canShowReviewQueue, selectedReviewID == item.id, reviewMediaLease === lease,
                  subject == authorization.subjectID,
                  grantRevision == authorization.moderatorGrantRevision,
                  queueItems.contains(where: {
                      $0.id == item.id && $0.revision == item.revision && $0.generation == item.generation
                  })
            else { return nil }
            localArtifactURLs[artifact.id] = url
            return media(artifact, at: url)
        } catch {
            return nil
        }
    }

    private func primaryArtifact(_ artifacts: [CreatorCanonicalArtifact]) -> CreatorCanonicalArtifact? {
        let primary = artifacts.filter { $0.role == .videoDefault || $0.role == .imageDefault }
        return primary.count == 1 ? primary[0] : nil
    }

    private func media(_ artifact: CreatorCanonicalArtifact, at url: URL) -> CreatorReviewMedia {
        if artifact.role == .imageDefault {
            return .still(.init(url: url, width: artifact.width, height: artifact.height, byteCount: artifact.byteCount))
        }
        return .video(url)
    }

    public func moderate(
        _ item: ModerationQueueItem,
        decision: ModerationDecision,
        checklistRevision: UInt64,
        reasonCodes: [String],
        creatorNote: String,
        privateNote: String
    ) async {
        guard canShowReviewQueue,
              queueItems.contains(where: {
                  $0.submissionID == item.submissionID
                      && $0.revision == item.revision
                      && $0.generation == item.generation
              })
        else {
            decisionState = .restricted
            return
        }
        let grantRevision = authorization.moderatorGrantRevision
        let subjectID = authorization.subjectID
        decisionState = .submitting
        do {
            let candidate = try ModerationDecisionRequest(
                submissionID: item.submissionID,
                expectedRevision: item.revision,
                expectedGeneration: item.generation,
                decision: decision,
                checklistRevision: checklistRevision,
                reasonCodes: reasonCodes,
                creatorNote: creatorNote,
                privateNote: privateNote,
                idempotencyKey: decisionRequest?.idempotencyKey ?? UUID().uuidString.lowercased()
            )
            let request: ModerationDecisionRequest
            if let previous = decisionRequest, previous != candidate {
                request = try ModerationDecisionRequest(submissionID: candidate.submissionID,
                    expectedRevision: candidate.expectedRevision, expectedGeneration: candidate.expectedGeneration,
                    decision: candidate.decision, checklistRevision: candidate.checklistRevision,
                    reasonCodes: candidate.reasonCodes, creatorNote: candidate.creatorNote, privateNote: candidate.privateNote,
                    idempotencyKey: UUID().uuidString.lowercased())
            } else { request = candidate }
            decisionRequest = request
            _ = try await gateway.moderate(request)
            guard subjectID == authorization.subjectID,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else {
                restrictLocally()
                return
            }
            decisionState = .succeeded
            await loadQueue()
        } catch {
            guard subjectID == authorization.subjectID else { return }
            switch CreatorRemoteFailureDisposition(error: error) {
            case .stale:
                await loadQueue()
                decisionState = .staleReloaded
            case .accessRevoked:
                restrictLocally()
            default:
                decisionState = .failed
            }
        }
    }

    private func handleQueue(_ error: Error) {
        queueErrorMessage = (error as? CatalogRemoteError)?.code == "rate_limited"
            ? "The hourly review request limit has been reached. Try again after it resets."
            : "Refresh to try again."
        switch CreatorRemoteFailureDisposition(error: error) {
        case .accessRevoked:
            restrictLocally()
        case .retryable:
            clearProtectedData()
            queueState = (error as? CatalogRemoteError)?.code == "offline" ? .offline : .failed
        case .stale, .terminal:
            clearProtectedData()
            queueState = .failed
        }
    }

    private func restrictLocally() {
        locallyRestricted = true
        requestGeneration &+= 1
        reportsGeneration &+= 1
        clearProtectedData()
        queueState = .restricted
        reportsState = .restricted
        decisionState = .restricted
        reportDecisionState = .restricted
    }

    private func clearProtectedData() {
        queueItems = []
        nextCursor = nil
        pageError = nil
        reports = []
        reportsNextCursor = nil
        reportsPageError = nil
        reportDecisionState = .idle
        reportResolution = nil
        reportRequest = nil
        selectedReportID = nil
        localArtifactURLs = [:]
        queueMediaLease = CatalogMediaLease()
        reviewMediaLease = CatalogMediaLease()
        reportMediaLease = CatalogMediaLease()
    }

    private func cacheProtectedArtifacts(_ items: [ModerationQueueItem]) async -> [String: URL] {
        guard let presentationMediaCache else { return [:] }
        let artifacts = items.flatMap(\.canonicalArtifacts).filter { $0.role == .poster }
        let lease = queueMediaLease
        return await withTaskGroup(of: (String, URL)?.self) { group in
            var pending = artifacts.makeIterator()
            func enqueue(_ artifact: CreatorCanonicalArtifact) {
                group.addTask {
                    guard !Task.isCancelled,
                          let url = try? await presentationMediaCache.localURL(for: artifact, retaining: lease),
                          url.isFileURL
                    else { return nil }
                    return (artifact.id, url)
                }
            }
            for _ in 0..<4 { if let artifact = pending.next() { enqueue(artifact) } }
            var result: [String: URL] = [:]
            while let entry = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let entry { result[entry.0] = entry.1 }
                if let artifact = pending.next() { enqueue(artifact) }
            }
            return result
        }
    }
}
