import Foundation
import WALIWire

public enum TranscoderConnectionError: LocalizedError {
    case invalidProxy
    case emptyResponse
    case responseMismatch
    case timeout
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case .invalidProxy: "WALI could not create a transcoder connection."
        case .emptyResponse: "The transcoder returned an empty response."
        case .responseMismatch: "The transcoder response belongs to another attempt."
        case .timeout: "The transcoder did not acknowledge the operation before its deadline."
        case .shuttingDown: "The transcoder is shutting down."
        }
    }
}

public extension TranscoderArtifactClaim {
    var storageRole: StoredArtifactRole {
        switch kind {
        case .masterVideo: .masterVideo
        case .previewVideo: .previewVideo
        case .posterImage: .posterImage
        }
    }

    var storageMediaKind: StoredArtifactMediaKind {
        switch kind {
        case .masterVideo, .previewVideo: .hevcVideo
        case .posterImage: .heicImage
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private final class ConnectionEndHandler: @unchecked Sendable {
    private weak var owner: TranscoderConnection?
    private let identifier: UUID

    init(owner: TranscoderConnection, identifier: UUID) {
        self.owner = owner
        self.identifier = identifier
    }

    func notify() {
        guard let owner else { return }
        Task { await owner.connectionEnded(identifier) }
    }
}

private final class ProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TranscoderProgress?
    private let handler: @Sendable (TranscoderProgress) -> Void

    init(handler: @escaping @Sendable (TranscoderProgress) -> Void) {
        self.handler = handler
    }

    func emit(_ progress: TranscoderProgress) {
        lock.lock()
        guard last != progress else {
            lock.unlock()
            return
        }
        last = progress
        lock.unlock()
        handler(progress)
    }
}

/// Reconnecting, agent-private transport for the embedded transcoder service.
public actor TranscoderConnection {
    private let serviceName: String
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var shutdownCompleted = false
    private var shutdownStarted = false

    public init(serviceName: String = TranscoderServiceName.current) {
        self.serviceName = serviceName
    }

    public func transcode(_ request: TranscoderRequest) async throws -> TranscoderOutput {
        try await transcode(request, progress: { _ in })
    }

    public func transcode(
        _ request: TranscoderRequest,
        progress: @escaping @Sendable (TranscoderProgress) -> Void
    ) async throws -> TranscoderOutput {
        #if WALI_APP_STORE
        guard !shutdownStarted else { throw TranscoderConnectionError.shuttingDown }
        let negotiatedConnectionID = try await negotiate(timeout: .seconds(5))
        guard !shutdownStarted else { throw TranscoderConnectionError.shuttingDown }
        let scoped = try StoreWorkerRequestFactory.make(request: request, persistentBookmark: request.sourceBookmark)
        let requestData = try StoreTranscoderWireCodec.encodeRequest(scoped)
        #else
        let requestData = try TranscoderWireCodec.encodeRequest(request)
        #endif
        let emitter = ProgressEmitter(handler: progress)
        let pollingTask = Task {
            await pollProgress(for: request, emitter: emitter)
        }
        defer { pollingTask.cancel() }
        #if WALI_APP_STORE
        let responseData = try await perform(requestData, expectedConnectionID: negotiatedConnectionID)
        #else
        let responseData = try await perform(requestData)
        #endif
        let output = try TranscoderWireCodec.decodeOutput(from: responseData)
        guard output.jobID == request.jobID,
              output.attemptGeneration == request.attemptGeneration else {
            throw TranscoderConnectionError.responseMismatch
        }
        emitter.emit(TranscoderProgress(
            jobID: request.jobID,
            attemptGeneration: request.attemptGeneration,
            phase: .complete,
            fractionCompleted: 1
        ))
        return output
    }

    public func cancel(jobID: UUID, attemptGeneration: UInt64) async throws {
        guard attemptGeneration > 0 else { throw TranscoderWireError.invalidRequest }
        let connection = activeConnection()
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = OneShotContinuation<Void>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                oneShot.resume(with: .failure(error))
            }) as? WALITranscoderXPCProtocol else {
                oneShot.resume(with: .failure(TranscoderConnectionError.invalidProxy))
                return
            }
            proxy.cancel(jobID, attemptGeneration: attemptGeneration) { error in
                if let error {
                    oneShot.resume(with: .failure(error))
                } else {
                    oneShot.resume(with: .success(()))
                }
            }
        }
    }

    /// Store shutdown is acknowledged only after worker attempts and scopes end.
    /// A successful retry is a no-op and never starts another XPC service.
    public func shutdown() async throws {
        if shutdownCompleted { return }
        shutdownStarted = true
        #if WALI_APP_STORE
        let deadline = ContinuousClock.now.advanced(by: .seconds(StoreWorkerWire.shutdownTimeoutSeconds))
        do {
            let negotiatedConnectionID = try await negotiate(timeout: .seconds(5))
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw TranscoderConnectionError.timeout }
            guard let connection, connectionID == negotiatedConnectionID else { throw TranscoderConnectionError.responseMismatch }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OneShotContinuation<Void>(continuation)
                let timer = Task {
                    do { try await Task.sleep(for: remaining) } catch { return }
                    once.resume(with: .failure(TranscoderConnectionError.timeout))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    timer.cancel(); once.resume(with: .failure(error))
                }) as? WALIStoreTranscoderXPCProtocol else {
                    timer.cancel(); once.resume(with: .failure(TranscoderConnectionError.invalidProxy)); return
                }
                proxy.shutdown { error in
                    timer.cancel()
                    if let error { once.resume(with: .failure(error)) }
                    else { once.resume(with: .success(())) }
                }
            }
            shutdownCompleted = true
            invalidate()
        } catch {
            invalidate()
            throw error
        }
        #else
        shutdownCompleted = true
        invalidate()
        #endif
    }

    #if WALI_APP_STORE
    private func negotiate(timeout: Duration) async throws -> UUID {
        let hello = StoreWorkerHandshake()
        let data = try StoreTranscoderWireCodec.encodeHandshake(hello)
        let connection = activeConnection()
        guard let identifier = connectionID else { throw TranscoderConnectionError.invalidProxy }
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let once = OneShotContinuation<Data>(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                once.resume(with: .failure(TranscoderConnectionError.timeout))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                timer.cancel(); once.resume(with: .failure(error))
            }) as? WALIStoreTranscoderXPCProtocol else {
                timer.cancel(); once.resume(with: .failure(TranscoderConnectionError.invalidProxy)); return
            }
            proxy.negotiate(data) { result, error in
                timer.cancel()
                if let error { once.resume(with: .failure(error)) }
                else if let result { once.resume(with: .success(result)) }
                else { once.resume(with: .failure(TranscoderConnectionError.emptyResponse)) }
            }
        }
        guard connectionID == identifier,
              try StoreTranscoderWireCodec.decodeHandshake(from: response) == hello else {
            throw TranscoderConnectionError.responseMismatch
        }
        return identifier
    }
    #endif

    public func invalidate() {
        connection?.invalidate()
        connection = nil
        connectionID = nil
    }

    private func perform(_ request: Data, expectedConnectionID: UUID? = nil) async throws -> Data {
        #if WALI_APP_STORE
        guard let connection, let expectedConnectionID, connectionID == expectedConnectionID else {
            throw TranscoderConnectionError.responseMismatch
        }
        #else
        let connection = activeConnection()
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            let oneShot = OneShotContinuation<Data>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                oneShot.resume(with: .failure(error))
            }) as? WALITranscoderXPCProtocol else {
                oneShot.resume(with: .failure(TranscoderConnectionError.invalidProxy))
                return
            }
            proxy.transcode(request) { data, error in
                if let error {
                    oneShot.resume(with: .failure(error))
                } else if let data {
                    oneShot.resume(with: .success(data))
                } else {
                    oneShot.resume(with: .failure(TranscoderConnectionError.emptyResponse))
                }
            }
        }
    }

    private func pollProgress(for request: TranscoderRequest, emitter: ProgressEmitter) async {
        while !Task.isCancelled {
            if let update = try? await fetchProgress(
                jobID: request.jobID,
                generation: request.attemptGeneration
            ) {
                emitter.emit(update)
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    private func fetchProgress(
        jobID: UUID,
        generation: UInt64
    ) async throws -> TranscoderProgress? {
        let connection = activeConnection()
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            let oneShot = OneShotContinuation<Data?>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                oneShot.resume(with: .failure(error))
            }) as? WALITranscoderXPCProtocol else {
                oneShot.resume(with: .failure(TranscoderConnectionError.invalidProxy))
                return
            }
            proxy.progress(jobID, attemptGeneration: generation) { data, error in
                if let error {
                    oneShot.resume(with: .failure(error))
                } else {
                    oneShot.resume(with: .success(data))
                }
            }
        }
        guard let data else { return nil }
        let progress = try TranscoderWireCodec.decodeProgress(from: data)
        guard progress.jobID == jobID, progress.attemptGeneration == generation else {
            throw TranscoderConnectionError.responseMismatch
        }
        return progress
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let identifier = UUID()
        let newConnection = NSXPCConnection(serviceName: serviceName)
        let endHandler = ConnectionEndHandler(owner: self, identifier: identifier)
        #if WALI_APP_STORE
        newConnection.remoteObjectInterface = NSXPCInterface(with: WALIStoreTranscoderXPCProtocol.self)
        #else
        newConnection.remoteObjectInterface = NSXPCInterface(with: WALITranscoderXPCProtocol.self)
        #endif
        newConnection.interruptionHandler = { endHandler.notify() }
        newConnection.invalidationHandler = { endHandler.notify() }
        newConnection.resume()
        connection = newConnection
        connectionID = identifier
        return newConnection
    }

    fileprivate func connectionEnded(_ identifier: UUID) {
        guard connectionID == identifier else { return }
        connection = nil
        connectionID = nil
    }
}

public enum TranscoderServiceName {
    public static var current: String {
        if let configured = Bundle.main.object(
            forInfoDictionaryKey: "WALITranscoderServiceName"
        ) as? String, !configured.isEmpty {
            return configured
        }
        return identifier(for: Bundle.main.bundleIdentifier)
    }

    static func identifier(for agentBundleIdentifier: String?) -> String {
        let identifier = agentBundleIdentifier ?? "io.github.codewithinferno.wali.WALIAgent"
        return identifier.replacingOccurrences(of: "WALIAgent", with: "WALITranscoder")
    }
}
