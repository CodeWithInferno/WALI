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
        let subjectChanged = authorization.subjectID != value.subjectID
        authorization = value
        locallyRestricted = false
        loadGeneration &+= 1
        if subjectChanged {
            submissions = []
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
        let generation = loadGeneration
        let grantRevision = authorization.creatorGrantRevision
        loadState = .loading
        do {
            let request = try CreatorListRequest()
            let page = try await gateway.submissions(request)
            guard generation == loadGeneration,
                  grantRevision == authorization.creatorGrantRevision,
                  canUseCreatorStudio
            else { return }
            submissions = page.items
            loadState = page.items.isEmpty ? .empty : .ready
        } catch {
            guard generation == loadGeneration else { return }
            handle(error)
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
            submissions = []
            loadState = .offline
        case .stale, .terminal:
            submissions = []
            loadState = .failed
        }
    }

    private func restrictLocally() {
        locallyRestricted = true
        loadGeneration &+= 1
        submissions = []
        loadState = .restricted
    }
}
