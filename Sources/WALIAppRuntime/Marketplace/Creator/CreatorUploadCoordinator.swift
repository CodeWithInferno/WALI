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

    private let gateway: any CreatorStudioGateway
    private let transport: any CreatorResumableUploadTransport
    private let uploader: CreatorResumableUploader
    private var uploadTask: Task<Void, Never>?
    private var source: (any CreatorUploadSource)?
    private var pauseRequested = false
    private var cancelledByUser = false

    public init(
        gateway: any CreatorStudioGateway,
        transport: any CreatorResumableUploadTransport,
        uploader: CreatorResumableUploader = .init()
    ) {
        self.gateway = gateway
        self.transport = transport
        self.uploader = uploader
    }

    public func start(
        fileURL: URL,
        declaredByteCount: UInt64,
        containerHint: String,
        target: CreatorUploadTarget = .new
    ) {
        cancelLocalTask()
        let source = FileCreatorUploadSource(fileURL: fileURL)
        self.source = source
        pauseRequested = false
        cancelledByUser = false
        state = .requestingGrant
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try CreatorUploadGrantRequest(
                    declaredByteCount: declaredByteCount,
                    containerHint: containerHint,
                    originalFilename: fileURL.lastPathComponent,
                    target: target,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                let session = try await gateway.createUpload(request)
                guard !Task.isCancelled else { return }
                self.session = session
                await self.runUpload(session: session, source: source)
            } catch {
                self.present(error)
            }
        }
    }

    public func pause() {
        guard uploadTask != nil else { return }
        pauseRequested = true
        cancelledByUser = false
        uploadTask?.cancel()
    }

    public func resume() {
        guard let session, let source else { return }
        pauseRequested = false
        cancelledByUser = false
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.runUpload(session: session, source: source)
        }
    }

    public func cancel() {
        cancelledByUser = true
        pauseRequested = false
        uploadTask?.cancel()
        session = nil
        source = nil
        state = .cancelled
    }

    private func runUpload(
        session: CreatorUploadSession,
        source: any CreatorUploadSource
    ) async {
        do {
            let result = try await uploader.upload(
                session: session,
                source: source,
                transport: transport
            ) { [weak self] progress in
                await MainActor.run {
                    guard let self else { return }
                    self.lastProgress = progress
                    self.state = .uploading(progress)
                }
            }
            guard !Task.isCancelled else { return }
            lastProgress = result
            state = .completing
            let completion = try CreatorCompleteUploadRequest(
                uploadSessionID: session.id,
                expectedSessionRevision: session.revision,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let mutation = try await gateway.completeUpload(completion)
            guard !Task.isCancelled,
                  mutation.generation > 0,
                  mutation.state == .processing
            else { return }
            state = .processing(mutation)
            self.session = nil
            self.source = nil
            uploadTask = nil
        } catch {
            if pauseRequested {
                state = .paused(lastProgress)
            } else if cancelledByUser {
                state = .cancelled
            } else {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        if CreatorRemoteFailureDisposition(error: error) == .accessRevoked {
            state = .restricted
        } else if let error = error as? CreatorUploadError {
            state = .failed(error.rawValue)
        } else if let error = error as? CatalogRemoteError {
            state = .failed(error.code)
        } else {
            state = .failed("temporarily_unavailable")
        }
        uploadTask = nil
    }

    private func cancelLocalTask() {
        uploadTask?.cancel()
        uploadTask = nil
        session = nil
        source = nil
    }
}
