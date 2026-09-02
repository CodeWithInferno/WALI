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

@MainActor
@Observable
public final class CreatorModerationModel {
    public private(set) var authorization: CreatorAuthorizationSnapshot
    public private(set) var queueItems: [ModerationQueueItem] = []
    public private(set) var reports: [ModerationReport] = []
    public private(set) var localArtifactURLs: [String: URL] = [:]
    public private(set) var queueState: CreatorModerationQueueState = .idle
    public private(set) var decisionState: CreatorModerationDecisionState = .idle

    public var canShowReviewQueue: Bool {
        !locallyRestricted && authorization.canAccessModeration(at: .now)
    }

    private let gateway: any ModerationGateway
    private let presentationMediaCache: (any CatalogPresentationMediaCaching)?
    private var locallyRestricted = false
    private var requestGeneration: UInt64 = 0

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
        let subjectChanged = authorization.subjectID != value.subjectID
        authorization = value
        locallyRestricted = false
        requestGeneration &+= 1
        if subjectChanged {
            clearProtectedData()
            queueState = .idle
            decisionState = .idle
        }
        guard canShowReviewQueue else {
            clearProtectedData()
            queueState = .restricted
            decisionState = .restricted
            return
        }
        if queueState == .restricted { queueState = .idle }
        if decisionState == .restricted { decisionState = .idle }
    }

    public func loadQueue() async {
        guard canShowReviewQueue else {
            clearProtectedData()
            queueState = .restricted
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        let grantRevision = authorization.moderatorGrantRevision
        queueState = .loading
        do {
            let page = try await gateway.queue(try ModerationQueueRequest())
            guard generation == requestGeneration,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            let cachedURLs = await cacheProtectedArtifacts(page.items)
            guard generation == requestGeneration,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            queueItems = page.items
            localArtifactURLs = cachedURLs
            queueState = page.items.isEmpty ? .empty : .ready
        } catch {
            guard generation == requestGeneration else { return }
            handleQueue(error)
        }
    }

    public func loadReports() async {
        guard canShowReviewQueue else {
            clearProtectedData()
            queueState = .restricted
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        let grantRevision = authorization.moderatorGrantRevision
        let subjectID = authorization.subjectID
        do {
            let page = try await gateway.reports(try ModerationReportQueueRequest())
            guard generation == requestGeneration,
                  subjectID == authorization.subjectID,
                  grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else { return }
            reports = page.items
        } catch {
            guard generation == requestGeneration,
                  subjectID == authorization.subjectID
            else { return }
            if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
                restrictLocally()
            }
        }
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
        decisionState = .submitting
        do {
            let request = try ModerationDecisionRequest(
                submissionID: item.submissionID,
                expectedRevision: item.revision,
                expectedGeneration: item.generation,
                decision: decision,
                checklistRevision: checklistRevision,
                reasonCodes: reasonCodes,
                creatorNote: creatorNote,
                privateNote: privateNote,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            _ = try await gateway.moderate(request)
            guard grantRevision == authorization.moderatorGrantRevision,
                  canShowReviewQueue
            else {
                restrictLocally()
                return
            }
            decisionState = .succeeded
            await loadQueue()
        } catch {
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
        switch CreatorRemoteFailureDisposition(error: error) {
        case .accessRevoked:
            restrictLocally()
        case .retryable:
            clearProtectedData()
            queueState = .offline
        case .stale, .terminal:
            clearProtectedData()
            queueState = .failed
        }
    }

    private func restrictLocally() {
        locallyRestricted = true
        requestGeneration &+= 1
        clearProtectedData()
        queueState = .restricted
        decisionState = .restricted
    }

    private func clearProtectedData() {
        queueItems = []
        reports = []
        localArtifactURLs = [:]
    }

    private func cacheProtectedArtifacts(_ items: [ModerationQueueItem]) async -> [String: URL] {
        guard let presentationMediaCache else { return [:] }
        let artifacts = items.flatMap(\.canonicalArtifacts)
        return await withTaskGroup(of: (String, URL)?.self) { group in
            for artifact in artifacts {
                group.addTask {
                    guard let url = try? await presentationMediaCache.localURL(for: artifact),
                          url.isFileURL
                    else { return nil }
                    return (artifact.id, url)
                }
            }
            var result: [String: URL] = [:]
            for await entry in group {
                if let entry { result[entry.0] = entry.1 }
            }
            return result
        }
    }
}
