import Foundation
import Observation
import WALICatalogRuntime

public enum CreatorUploadPresentationState: Sendable, Equatable {
    case idle
    case requestingGrant
    case uploading(CreatorUploadProgress)
    case paused(CreatorUploadProgress?)
    case completing
    case processing(CreatorMutationResult)
    case cancelled
    case restricted
    case failed(String)
}

@MainActor
@Observable
public final class CreatorUploadCoordinator {
    public private(set) var state: CreatorUploadPresentationState = .idle
    public private(set) var session: CreatorUploadSession?
    public private(set) var lastProgress: CreatorUploadProgress?
    public private(set) var supportedMediaTypes = CreatorUploadMediaType.legacyVideo

    public var canRetry: Bool {
        guard case let .failed(code) = state, pending != nil, source != nil else { return false }
        return ![CreatorUploadError.sessionExpired.rawValue, CreatorUploadError.sourceChanged.rawValue,
                 CreatorUploadError.accessDenied.rawValue, CreatorContractError.invalidRequest.rawValue,
                 CreatorContractError.rightsIncomplete.rawValue, CreatorContractError.unsupportedUploadFormat.rawValue,
                 "still_intake_disabled"].contains(code)
    }

    private struct Pending {
        let grant: CreatorUploadGrantRequest
        let draft: CreatorDraft
        let termsVersion: String
        let completionKey: String
    }

    private let gateway: any CreatorStudioGateway
    private let transport: any CreatorResumableUploadTransport
    private let uploader: CreatorResumableUploader
    private let makeSource: @Sendable (URL) -> any CreatorUploadSource
    private var authorization: CreatorAuthorizationSnapshot?
    private var uploadTask: Task<Void, Never>?
    private var source: (any CreatorUploadSource)?
    private var pending: Pending?
    private var operationGeneration: UInt64 = 0
    private var pauseRequested = false

    public init(
        gateway: any CreatorStudioGateway,
        transport: any CreatorResumableUploadTransport,
        uploader: CreatorResumableUploader = .init(),
        makeSource: (@Sendable (URL) -> any CreatorUploadSource)? = nil
    ) {
        self.gateway = gateway
        self.transport = transport
        self.uploader = uploader
        self.makeSource = makeSource ?? { FileCreatorUploadSource(fileURL: $0) }
    }

    public func updateAuthorization(_ value: CreatorAuthorizationSnapshot) {
        let changedSubject = authorization?.subjectID != value.subjectID
        let changedTerms = authorization?.currentCreatorTermsVersion != value.currentCreatorTermsVersion
        let canAccess = value.canAccessCreatorStudio()
        authorization = value
        if changedSubject || changedTerms || !canAccess {
            clearLocalUpload()
            state = canAccess ? .idle : .restricted
        } else if state == .restricted {
            state = .idle
        }
    }

    public func refreshSupportedMediaTypes() async throws -> Set<CreatorUploadMediaType> {
        let generation = operationGeneration
        guard let authorization, authorization.canAccessCreatorStudio() else {
            throw CreatorUploadError.accessDenied
        }
        let subject = authorization.subjectID
        let terms = authorization.currentCreatorTermsVersion
        // A failed refresh must never retain a previous positive still capability.
        supportedMediaTypes = CreatorUploadMediaType.legacyVideo
        let supported = try await gateway.supportedUploadMediaTypes()
        guard accepts(generation), self.authorization?.subjectID == subject,
              self.authorization?.currentCreatorTermsVersion == terms else {
            throw CancellationError()
        }
        supportedMediaTypes = supported
        return supported
    }

    public func start(
        fileURL: URL,
        declaredByteCount: UInt64,
        containerHint: String,
        draft: CreatorDraft,
        creatorTermsVersion: String,
        target: CreatorUploadTarget = .new
    ) {
        guard authorization?.canAccessCreatorStudio() == true,
              authorization?.currentCreatorTermsVersion == creatorTermsVersion else {
            clearLocalUpload()
            state = .restricted
            return
        }
        clearLocalUpload()
        do {
            let grant = try CreatorUploadGrantRequest(
                declaredByteCount: declaredByteCount, containerHint: containerHint,
                originalFilename: fileURL.lastPathComponent, target: target,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            try draft.validateForUpload()
            pending = Pending(grant: grant, draft: draft, termsVersion: creatorTermsVersion,
                              completionKey: UUID().uuidString.lowercased())
            source = makeSource(fileURL)
            launchUpload()
        } catch {
            present(error)
        }
    }

    public func pause() {
        guard uploadTask != nil else { return }
        pauseRequested = true
        uploadTask?.cancel()
        state = .paused(lastProgress)
    }

    public func resume() {
        guard pending != nil, source != nil, authorization?.canAccessCreatorStudio() == true else { return }
        launchUpload()
    }

    public func retry() {
        guard canRetry else { return }
        resume()
    }

    public func cancel() {
        clearLocalUpload()
        state = .cancelled
    }

    private func launchUpload() {
        let previousTask = uploadTask
        previousTask?.cancel()
        operationGeneration &+= 1
        let generation = operationGeneration
        pauseRequested = false
        state = session.map { .uploading(lastProgress ?? .init(uploadedByteCount: 0, totalByteCount: $0.declaredByteCount)) }
            ?? .requestingGrant
        uploadTask = Task { [weak self] in
            // Reusing a source must wait for the cancelled attempt to close its file access.
            await previousTask?.value
            await self?.runUpload(generation: generation)
        }
    }

    private func runUpload(generation: UInt64) async {
        guard accepts(generation), let pending, let source else { return }
        do {
            let activeSession: CreatorUploadSession
            if let session {
                activeSession = session
            } else {
                let supported = try await refreshSupportedMediaTypes()
                guard accepts(generation) else { return }
                guard let format = CreatorUploadMediaType(rawValue: pending.grant.containerHint),
                      supported.contains(format) else {
                    throw CreatorContractError.unsupportedUploadFormat
                }
                activeSession = try await gateway.createUpload(pending.grant)
                guard accepts(generation) else { return }
                session = activeSession
            }
            let result = try await uploader.upload(session: activeSession, source: source, transport: transport) { [weak self] progress in
                await MainActor.run {
                    guard let self, self.accepts(generation) else { return }
                    self.lastProgress = progress
                    self.state = .uploading(progress)
                }
            }
            guard accepts(generation) else { return }
            lastProgress = result
            state = .completing
            let completion = try CreatorCompleteUploadRequest(
                uploadSessionID: activeSession.id, expectedSessionRevision: activeSession.revision,
                draft: pending.draft, creatorTermsVersion: pending.termsVersion,
                idempotencyKey: pending.completionKey
            )
            let mutation = try await gateway.completeUpload(completion)
            guard accepts(generation) else { return }
            guard mutation.generation > 0,
                  mutation.state.awaitsAutomaticPublication || mutation.state == .published else {
                throw CreatorContractError.invalidRemoteResponse
            }
            state = .processing(mutation)
            session = nil
            self.source = nil
            self.pending = nil
            uploadTask = nil
        } catch {
            guard generation == operationGeneration else { return }
            if pauseRequested {
                state = .paused(lastProgress)
            } else {
                present(error)
            }
            uploadTask = nil
        }
    }

    private func accepts(_ generation: UInt64) -> Bool {
        generation == operationGeneration && !Task.isCancelled && authorization?.canAccessCreatorStudio() == true
    }

    private func present(_ error: Error) {
        if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
            clearLocalUpload()
            state = .restricted
        } else if let error = error as? CreatorUploadError {
            state = .failed(error.rawValue)
        } else if let error = error as? CreatorContractError {
            state = .failed(error.rawValue)
        } else if let error = error as? CatalogRemoteError {
            state = .failed(error.code)
        } else {
            state = .failed("temporarily_unavailable")
        }
    }

    private func clearLocalUpload() {
        supportedMediaTypes = CreatorUploadMediaType.legacyVideo
        operationGeneration &+= 1
        uploadTask?.cancel()
        uploadTask = nil
        session = nil
        source = nil
        pending = nil
        lastProgress = nil
        pauseRequested = false
    }
}
