import Foundation
import Darwin
import Security
import WALIModel
import WALIWire

private final class TranscoderReplyBox: @unchecked Sendable {
    let reply: (Data?, NSError?) -> Void

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }
}

private final class CancellationReplyBox: @unchecked Sendable {
    let reply: (NSError?) -> Void

    init(_ reply: @escaping (NSError?) -> Void) {
        self.reply = reply
    }
}

private final class LatestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TranscoderProgress

    init(jobID: UUID, generation: UInt64) {
        value = TranscoderProgress(
            jobID: jobID,
            attemptGeneration: generation,
            phase: .queued,
            fractionCompleted: 0
        )
    }

    func update(_ progress: MediaPipelineProgress) {
        lock.lock()
        value = TranscoderProgress(
            jobID: value.jobID,
            attemptGeneration: value.attemptGeneration,
            phase: Self.wirePhase(progress.phase),
            fractionCompleted: progress.fractionCompleted
        )
        lock.unlock()
    }

    func snapshot() -> TranscoderProgress {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }

    private static func wirePhase(_ phase: MediaPipelinePhase) -> TranscoderProgressPhase {
        switch phase {
        case .inspecting: .inspecting
        case .hashingSource: .hashingSource
        case .transcodingMaster: .transcodingMaster
        case .transcodingPreview: .transcodingPreview
        case .generatingPoster: .generatingPoster
        case .verifyingOutputs: .verifyingOutputs
        case .complete: .complete
        }
    }
}

private actor TranscodeTaskRegistry {
    private struct AttemptKey: Hashable, Sendable {
        let jobID: UUID
        let generation: UInt64
    }

    private struct PendingAttempt {
        let request: TranscoderRequest
        let stagingBookmark: Data?
        var waiters: [CheckedContinuation<TranscoderOutput, Error>]
    }

    private struct ActiveAttempt {
        let key: AttemptKey
        let request: TranscoderRequest
        let stagingBookmark: Data?
        var waiters: [CheckedContinuation<TranscoderOutput, Error>]
        let progress: LatestProgress
        let task: Task<TranscoderOutput, Error>
    }

    private var isShuttingDown = false
    private var active: ActiveAttempt?
    private var queue: [AttemptKey] = []
    private var pending: [AttemptKey: PendingAttempt] = [:]

    func transcode(_ request: TranscoderRequest, stagingBookmark: Data? = nil) async throws -> TranscoderOutput {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(request, stagingBookmark: stagingBookmark, continuation: continuation)
        }
    }

    func cancel(jobID: UUID, generation: UInt64) {
        let key = AttemptKey(jobID: jobID, generation: generation)
        if active?.key == key {
            active?.task.cancel()
            return
        }
        guard let cancelled = pending.removeValue(forKey: key) else { return }
        queue.removeAll { $0 == key }
        for waiter in cancelled.waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    func progress(jobID: UUID, generation: UInt64) -> TranscoderProgress? {
        let key = AttemptKey(jobID: jobID, generation: generation)
        if let active, active.key == key {
            return active.progress.snapshot()
        }
        guard pending[key] != nil else { return nil }
        return TranscoderProgress(
            jobID: jobID,
            attemptGeneration: generation,
            phase: .queued,
            fractionCompleted: 0
        )
    }

    private func enqueue(
        _ request: TranscoderRequest,
        stagingBookmark: Data?,
        continuation: CheckedContinuation<TranscoderOutput, Error>
    ) {
        guard !isShuttingDown else { continuation.resume(throwing: CancellationError()); return }
        let key = AttemptKey(jobID: request.jobID, generation: request.attemptGeneration)
        if var current = active, current.key == key {
            guard current.request == request, current.stagingBookmark == stagingBookmark else {
                continuation.resume(throwing: TranscoderServiceError.conflictingAttempt)
                return
            }
            current.waiters.append(continuation)
            active = current
            return
        }
        if var queued = pending[key] {
            guard queued.request == request, queued.stagingBookmark == stagingBookmark else {
                continuation.resume(throwing: TranscoderServiceError.conflictingAttempt)
                return
            }
            queued.waiters.append(continuation)
            pending[key] = queued
            return
        }

        pending[key] = PendingAttempt(request: request, stagingBookmark: stagingBookmark, waiters: [continuation])
        queue.append(key)
        startNextIfIdle()
    }

    func shutdown() async {
        isShuttingDown = true
        for attempt in pending.values {
            for waiter in attempt.waiters { waiter.resume(throwing: CancellationError()) }
        }
        pending.removeAll()
        queue.removeAll()
        if let task = active?.task {
            task.cancel()
            _ = await task.result
        }
    }

    private func startNextIfIdle() {
        guard !isShuttingDown, active == nil else { return }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard let next = pending.removeValue(forKey: key) else { continue }
            let progress = LatestProgress(jobID: key.jobID, generation: key.generation)
            let task = Task {
                try await Self.perform(next.request, stagingBookmark: next.stagingBookmark, progress: progress.update)
            }
            active = ActiveAttempt(
                key: key,
                request: next.request,
                stagingBookmark: next.stagingBookmark,
                waiters: next.waiters,
                progress: progress,
                task: task
            )
            Task {
                let result: Result<TranscoderOutput, Error>
                do {
                    result = .success(try await task.value)
                } catch {
                    result = .failure(error)
                }
                self.finished(key: key, result: result)
            }
            return
        }
    }

    private func finished(
        key: AttemptKey,
        result: Result<TranscoderOutput, Error>
    ) {
        guard let completed = active, completed.key == key else { return }
        active = nil
        for waiter in completed.waiters {
            waiter.resume(with: result)
        }
        startNextIfIdle()
    }

    private static func perform(
        _ request: TranscoderRequest,
        stagingBookmark: Data?,
        progress: @escaping @Sendable (MediaPipelineProgress) -> Void
    ) async throws -> TranscoderOutput {
        #if WALI_APP_STORE
        guard let stagingBookmark else { throw WorkerGrantError.missingGrant }
        let access = try WorkerScopedMediaAccess.open(StoreTranscoderRequest(request: request, stagingBookmark: stagingBookmark))
        defer { access.close() }
        let resolvedSourceURL = access.sourceURL
        #else
        var bookmarkIsStale = false
        let resolvedSourceURL: URL
        do {
            resolvedSourceURL = try URL(
                resolvingBookmarkData: request.sourceBookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        } catch {
            throw TranscoderServiceError.invalidSourceBookmark
        }
        guard !bookmarkIsStale else {
            throw TranscoderServiceError.staleSourceBookmark
        }
        guard resolvedSourceURL.isFileURL,
              resolvedSourceURL.standardizedFileURL == request.sourceURL.standardizedFileURL else {
            throw TranscoderServiceError.sourceBookmarkMismatch
        }

        let hasSecurityScope = resolvedSourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                resolvedSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        #endif

        let jobID = try JobID(request.jobID.uuidString.lowercased())
        let generation = try AttemptGeneration(request.attemptGeneration)
        let mediaRequest = try MediaTranscodeRequest(
            attempt: MediaAttemptID(jobID: jobID, generation: generation),
            sourceURL: resolvedSourceURL,
            stagingDirectoryURL: request.stagingDirectoryURL,
            sourceByteLimit: request.sourceByteLimit
        )
        let result = try await MediaTranscoder().transcode(mediaRequest, progress: progress)
        return TranscoderOutput(
            jobID: request.jobID,
            attemptGeneration: request.attemptGeneration,
            displayName: result.suggestedDisplayName,
            completedAt: result.completedAt,
            sourceDigest: result.sourceDigest.value,
            sourceMedia: wireClaim(result.sourceInspection),
            artifacts: result.claims.map { claim in
                TranscoderArtifactClaim(
                    kind: wireKind(claim.kind),
                    stagedURL: claim.stagedURL,
                    digest: claim.digest.value,
                    byteCount: claim.byteCount,
                    media: claim.inspection.map(wireClaim)
                )
            }
        )
    }

    private static func wireKind(_ kind: MediaArtifactKind) -> TranscoderArtifactKind {
        switch kind {
        case .masterVideo: .masterVideo
        case .previewVideo: .previewVideo
        case .posterImage: .posterImage
        }
    }

    private static func wireClaim(_ inspection: MediaInspection) -> TranscoderMediaClaim {
        TranscoderMediaClaim(
            byteCount: inspection.byteCount,
            pixelWidth: inspection.pixelSize.width,
            pixelHeight: inspection.pixelSize.height,
            duration: inspection.durationSeconds,
            nominalFrameRate: inspection.nominalFrameRate,
            hasAudio: inspection.hasAudio,
            isHDR: inspection.isHDR,
            videoCodec: inspection.videoCodec
        )
    }
}

private enum TranscoderServiceError: LocalizedError {
    case conflictingAttempt
    case invalidSourceBookmark
    case sourceBookmarkMismatch
    case staleSourceBookmark

    var errorDescription: String? {
        switch self {
        case .conflictingAttempt:
            "A different generation is already active for this import job."
        case .invalidSourceBookmark:
            "The source authorization could not be resolved."
        case .sourceBookmarkMismatch:
            "The source authorization does not match the requested file."
        case .staleSourceBookmark:
            "The source authorization is stale and must be renewed."
        }
    }
}

private final class TranscoderServiceEndpoint:
    NSObject,
    @unchecked Sendable
{
    private let registry = TranscodeTaskRegistry()

    func transcode(_ requestData: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let request: TranscoderRequest
        let stagingBookmark: Data?
        do {
            #if WALI_APP_STORE
            let storeRequest = try StoreTranscoderWireCodec.decodeRequest(from: requestData)
            request = storeRequest.request
            stagingBookmark = storeRequest.stagingBookmark
            #else
            request = try TranscoderWireCodec.decodeRequest(from: requestData)
            stagingBookmark = nil
            #endif
        } catch {
            reply(nil, error as NSError)
            return
        }

        let replyBox = TranscoderReplyBox(reply)
        Task {
            do {
                let output = try await registry.transcode(request, stagingBookmark: stagingBookmark)
                replyBox.reply(try TranscoderWireCodec.encodeOutput(output), nil)
            } catch {
                replyBox.reply(nil, error as NSError)
            }
        }
    }

    func progress(
        _ jobID: UUID,
        attemptGeneration: UInt64,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        guard attemptGeneration > 0 else {
            reply(nil, TranscoderWireError.invalidRequest as NSError)
            return
        }
        let replyBox = TranscoderReplyBox(reply)
        Task {
            guard let progress = await registry.progress(
                jobID: jobID,
                generation: attemptGeneration
            ) else {
                replyBox.reply(nil, nil)
                return
            }
            do {
                replyBox.reply(try TranscoderWireCodec.encodeProgress(progress), nil)
            } catch {
                replyBox.reply(nil, error as NSError)
            }
        }
    }

    func cancel(
        _ jobID: UUID,
        attemptGeneration: UInt64,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        guard attemptGeneration > 0 else {
            reply(TranscoderWireError.invalidRequest as NSError)
            return
        }
        let replyBox = CancellationReplyBox(reply)
        Task {
            await registry.cancel(jobID: jobID, generation: attemptGeneration)
            replyBox.reply(nil)
        }
    }
}

#if WALI_APP_STORE
extension TranscoderServiceEndpoint: WALIStoreTranscoderXPCProtocol {
    func connectionInvalidated() {
        Task {
            await registry.shutdown()
            exit(EXIT_SUCCESS)
        }
    }

    func negotiate(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let value = try StoreTranscoderWireCodec.decodeHandshake(from: request)
            reply(try StoreTranscoderWireCodec.encodeHandshake(value), nil)
        } catch { reply(nil, error as NSError) }
    }

    func shutdown(withReply reply: @escaping (NSError?) -> Void) {
        let box = CancellationReplyBox(reply)
        Task {
            await registry.shutdown()
            box.reply(nil)
            // The acknowledgement is enqueued before this service exits. The
            // agent reports success only after receiving it; a lost reply fails.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { exit(EXIT_SUCCESS) }
        }
    }
}
#else
extension TranscoderServiceEndpoint: WALITranscoderXPCProtocol {}
#endif

private final class TranscoderListenerDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let endpoint = TranscoderServiceEndpoint()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard TranscoderClientValidator.isTrusted(connection) else { return false }
        #if WALI_APP_STORE
        connection.exportedInterface = NSXPCInterface(with: WALIStoreTranscoderXPCProtocol.self)
        connection.invalidationHandler = { [endpoint] in endpoint.connectionInvalidated() }
        #else
        connection.exportedInterface = NSXPCInterface(with: WALITranscoderXPCProtocol.self)
        #endif
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

private enum TranscoderClientValidator {
    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        guard let client = code(for: connection.processIdentifier),
              SecCodeCheckValidity(client, [], nil) == errSecSuccess,
              let clientInfo = signingInfo(for: client),
              let clientIdentifier = clientInfo[kSecCodeInfoIdentifier as String] as? String,
              clientIdentifier == expectedClientIdentifier,
              let ownCode = ownCode(),
              let ownInfo = signingInfo(for: ownCode)
        else {
            return false
        }

        let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let clientTeam = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String
        if isAdHocDebugBuild, ownTeam == nil, clientTeam == nil {
            return true
        }
        guard let ownTeam,
              ownTeam == clientTeam,
              let requirement = peerRequirement(identifier: expectedClientIdentifier, team: ownTeam)
        else {
            return false
        }
        return SecCodeCheckValidity(client, [], requirement) == errSecSuccess
    }

    private static var isAdHocDebugBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").contains(".debug.")
    }

    private static func peerRequirement(identifier: String, team: String) -> SecRequirement? {
        let validIdentifier = identifier.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
        }
        let validTeam = !team.isEmpty && team.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
        guard validIdentifier, validTeam else { return nil }
        let expression = "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            [],
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static var expectedClientIdentifier: String {
        if let configured = Bundle.main.object(
            forInfoDictionaryKey: "WALIExpectedClientBundleIdentifier"
        ) as? String, !configured.isEmpty {
            return configured
        }
        let identifier = Bundle.main.bundleIdentifier ?? "com.wali.WALITranscoder"
        return identifier.replacingOccurrences(of: "WALITranscoder", with: "WALIAgent")
    }

    private static func code(for processIdentifier: pid_t) -> SecCode? {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func ownCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func signingInfo(for code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

/// Starts the authenticated embedded XPC service and yields to libdispatch.
public enum WALITranscoderServiceRunner {
    public static func run() {
        let delegate = TranscoderListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        dispatchMain()
    }
}
