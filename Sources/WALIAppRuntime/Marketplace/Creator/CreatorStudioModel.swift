import Foundation
import Observation
import WALICatalogRuntime

public enum CreatorStudioLoadState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case empty
    case restricted
    case offline
    case failed
}

@MainActor
@Observable
public final class CreatorStudioModel {
    public private(set) var authorization: CreatorAuthorizationSnapshot
    public private(set) var submissions: [CreatorSubmission] = []
    public private(set) var loadState: CreatorStudioLoadState = .idle
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    public private(set) var pageError: String?

    public var hasProcessingSubmissions: Bool {
        submissions.contains { $0.state == .processing || $0.state == .uploaded }
    }

    public var canUseCreatorStudio: Bool {
        !locallyRestricted && authorization.canAccessCreatorStudio(at: .now)
    }

    private let gateway: any CreatorStudioGateway
    private var locallyRestricted = false
    private var loadGeneration: UInt64 = 0

    public init(
        gateway: any CreatorStudioGateway,
        authorization: CreatorAuthorizationSnapshot
    ) {
        self.gateway = gateway
        self.authorization = authorization
    }

    public func updateAuthorization(_ value: CreatorAuthorizationSnapshot) {
        guard authorization != value || locallyRestricted else { return }
        let subjectChanged = authorization.subjectID != value.subjectID
        authorization = value
        locallyRestricted = false
        loadGeneration &+= 1
        if loadState == .loading { loadState = .idle }
        isLoadingMore = false
        pageError = nil
        if subjectChanged {
            submissions = []
            nextCursor = nil
            loadState = .idle
        }
        guard canUseCreatorStudio else {
            submissions = []
            loadState = .restricted
            return
        }
        if loadState == .restricted { loadState = .idle }
    }

    public func loadSubmissions() async {
        guard canUseCreatorStudio else {
            submissions = []
            loadState = .restricted
            return
        }
        loadGeneration &+= 1
        isLoadingMore = false
        pageError = nil
        nextCursor = nil
        let generation = loadGeneration
        let grantRevision = authorization.creatorGrantRevision
        loadState = .loading
        do {
            let request = try CreatorListRequest()
            let page = try await gateway.submissions(request)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  grantRevision == authorization.creatorGrantRevision,
                  canUseCreatorStudio
            else { return }
            submissions = page.items
            nextCursor = page.nextCursor
            loadState = page.items.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            handle(error)
        }
    }

    public func loadNextPage() async {
        guard canUseCreatorStudio, !isLoadingMore, let cursor = nextCursor else { return }
        let generation = loadGeneration
        isLoadingMore = true
        pageError = nil
        defer { if generation == loadGeneration { isLoadingMore = false } }
        do {
            let page = try await gateway.submissions(CreatorListRequest(cursor: cursor))
            try Task.checkCancellation()
            guard generation == loadGeneration, canUseCreatorStudio else { return }
            let existingIDs = Set(submissions.map(\.id))
            submissions.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
                restrictLocally()
            } else {
                pageError = "More submissions couldn’t be loaded. Try again."
            }
        }
    }

    public func refreshProcessingSubmissions() async {
        let generation = loadGeneration
        for submission in submissions where submission.state == .processing || submission.state == .uploaded {
            guard !Task.isCancelled, canUseCreatorStudio, generation == loadGeneration else { return }
            do {
                let status = try await gateway.processingStatus(submissionID: submission.id, generation: submission.generation)
                try Task.checkCancellation()
                guard generation == loadGeneration, canUseCreatorStudio,
                      let index = submissions.firstIndex(where: { $0.id == submission.id }),
                      submissions[index].revision == submission.revision,
                      status.revision >= submission.revision
                else { continue }
                submissions[index] = CreatorSubmission(
                    id: submission.id, wallpaperID: submission.wallpaperID,
                    revision: status.revision, generation: status.generation, state: status.state,
                    draft: submission.draft, processing: status,
                    moderationReasonCodes: submission.moderationReasonCodes,
                    creatorFacingNote: submission.creatorFacingNote,
                    createdAt: submission.createdAt, updatedAt: submission.updatedAt,
                    wallpaperStatus: submission.wallpaperStatus
                )
                pageError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
                    restrictLocally()
                    return
                }
                pageError = "Processing status couldn’t be refreshed. Try again in a moment."
                return
            }
        }
    }

    public func withdraw(_ submission: CreatorSubmission) async {
        guard canUseCreatorStudio else {
            restrictLocally()
            return
        }
        let binding = (submission.id, submission.revision, submission.generation)
        let grantRevision = authorization.creatorGrantRevision
        do {
            let request = try CreatorWithdrawRequest(
                submissionID: submission.id,
                expectedRevision: submission.revision,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            _ = try await gateway.withdraw(request)
            guard grantRevision == authorization.creatorGrantRevision,
                  canUseCreatorStudio,
                  submissions.contains(where: {
                      ($0.id, $0.revision, $0.generation) == binding
                  })
            else { return }
            await loadSubmissions()
        } catch {
            switch CreatorRemoteFailureDisposition(error: error) {
            case .stale:
                await loadSubmissions()
            default:
                handle(error)
            }
        }
    }

    private func handle(_ error: Error) {
        switch CreatorRemoteFailureDisposition(error: error) {
        case .accessRevoked:
            restrictLocally()
        case .retryable:
            if submissions.isEmpty {
                loadState = (error as? CatalogRemoteError)?.code == "network_unavailable" ? .offline : .failed
            } else {
                loadState = .ready
                pageError = "Submissions couldn’t be refreshed. Try again in a moment."
            }
        case .stale, .terminal:
            if submissions.isEmpty {
                loadState = .failed
            } else {
                loadState = .ready
                pageError = "Submissions couldn’t be refreshed. Try again in a moment."
            }
        }
    }

    private func restrictLocally() {
        locallyRestricted = true
        loadGeneration &+= 1
        submissions = []
        isLoadingMore = false
        pageError = nil
        nextCursor = nil
        loadState = .restricted
    }
}
