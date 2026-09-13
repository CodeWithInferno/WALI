import Foundation

/// One instance per foreground composition. The transition gate remains held across suspension;
/// actor isolation alone would let sign-out race the SDK's asynchronous session persistence.
actor CatalogAuthAuthority: CatalogAuthSessionProviding, CatalogEmailAuthenticating {
    typealias AttemptFactory = @Sendable () throws -> any CatalogEmailAttemptTransport
    private enum Phase { case requesting, ready, verifying }
    private struct Pending {
        let id: UUID
        let ownerID: UUID
        let email: String
        let transport: any CatalogEmailAttemptTransport
        let expiresAt: Double
        var resendAt: Double
        var resendDate: Date
        var phase: Phase
        var presentation: CatalogEmailAuthAttempt {
            CatalogEmailAuthAttempt(id: id, email: email, resendAvailableAt: resendDate)
        }
    }
    private let shared: any CatalogSharedSessionAdapter
    private let attemptFactory: AttemptFactory?
    private let monotonicNow: @Sendable () -> Double
    private let wallNow: @Sendable () -> Date
    private var pending: Pending?
    private var committed: (id: UUID, ownerID: UUID)?
    private var transitionHeld = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<CatalogAuthState?>.Continuation] = [:]
    private var observation: Task<Void, Never>?
    private var acceptedState: CatalogAuthState?

    init(
        shared: any CatalogSharedSessionAdapter,
        attemptFactory: AttemptFactory? = nil,
        monotonicNow: (@Sendable () -> Double)? = nil,
        wallNow: (@Sendable () -> Date)? = nil
    ) {
        self.shared = shared
        self.attemptFactory = attemptFactory
        self.monotonicNow = monotonicNow ?? { ProcessInfo.processInfo.systemUptime }
        self.wallNow = wallNow ?? { .now }
    }

    deinit { observation?.cancel() }

    func currentState() async -> CatalogAuthState? {
        await acquireTransition()
        defer { releaseTransition() }
        let state = await shared.currentState()
        publish(state)
        return state
    }

    func stateChanges() async -> AsyncStream<CatalogAuthState?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CatalogAuthState?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        if observation == nil {
            let shared = shared
            observation = Task { [weak self] in
                let changes = await shared.changes()
                for await _ in changes {
                    if Task.isCancelled { break }
                    // Read current shared storage after the transition, never replay an event's
                    // captured session (which could precede a newer sign-out).
                    _ = await self?.currentState()
                }
            }
        }
        await acquireTransition()
        let state = await shared.currentState()
        publish(state)
        continuation.yield(state)
        releaseTransition()
        return stream
    }

    func beginEmailSignIn(email: String, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        let email = try CatalogEmailInput.email(email)
        guard !Task.isCancelled else { throw CatalogEmailAuthError.cancelled }
        guard let attemptFactory else { throw CatalogEmailAuthError.unavailable }
        let transport = try attemptFactory()
        let old = pending
        let attempt = Pending(
            id: UUID(), ownerID: ownerID, email: email, transport: transport,
            expiresAt: monotonicNow() + 600, resendAt: monotonicNow() + 60,
            resendDate: wallNow().addingTimeInterval(60), phase: .requesting
        )
        pending = attempt
        // Reserve ownership before waiting, so teardown can invalidate a queued begin.
        await acquireTransition()
        let isCurrent = pending?.id == attempt.id && !Task.isCancelled
        releaseTransition()
        if let old { await old.transport.discard() }
        guard isCurrent, pending?.id == attempt.id else {
            await transport.discard()
            throw CatalogEmailAuthError.superseded
        }
        return try await requestCode(attempt)
    }

    func resendEmailCode(attemptID: UUID, ownerID: UUID) async throws -> CatalogEmailAuthAttempt {
        var attempt = try activeAttempt(id: attemptID, ownerID: ownerID)
        guard attempt.phase == .ready else { throw CatalogEmailAuthError.attemptInProgress }
        guard monotonicNow() >= attempt.resendAt else {
            throw CatalogEmailAuthError.resendTooSoon(retryAt: attempt.resendDate)
        }
        attempt.phase = .requesting
        attempt.resendAt = monotonicNow() + 60
        attempt.resendDate = wallNow().addingTimeInterval(60)
        pending = attempt
        return try await requestCode(attempt, isResend: true)
    }

    func verifyEmailCode(
        code: String, attemptID: UUID, ownerID: UUID,
        onAdmissionCommitted: @escaping @Sendable () async -> Void
    ) async throws -> CatalogAuthState {
        let code = try CatalogEmailInput.code(code)
        var attempt = try activeAttempt(id: attemptID, ownerID: ownerID)
        guard attempt.phase == .ready else { throw CatalogEmailAuthError.attemptInProgress }
        attempt.phase = .verifying
        pending = attempt
        let candidate: CatalogEmailSessionCandidate
        do {
            candidate = try await attempt.transport.verifyCode(email: attempt.email, code: code)
        } catch {
            guard pending?.id == attempt.id else { throw CatalogEmailAuthError.superseded }
            if Task.isCancelled || safeError(error) == .cancelled {
                pending = nil
                await attempt.transport.discard()
                throw CatalogEmailAuthError.cancelled
            }
            pending?.phase = .ready
            throw safeError(error)
        }
        await acquireTransition()
        guard pending?.id == attempt.id, !Task.isCancelled, monotonicNow() < attempt.expiresAt else {
            if pending?.id == attempt.id { pending = nil }
            releaseTransition()
            await attempt.transport.discard()
            throw CatalogEmailAuthError.superseded
        }
        // Commit without suspension. Cancellation after this line cannot cancel the login.
        pending = nil
        committed = (attempt.id, attempt.ownerID)
        await onAdmissionCommitted()
        do {
            // An unstructured task deliberately does not inherit caller cancellation. The gate
            // is not released until the bounded SDK admission really has finished.
            let shared = shared
            let admission = Task { try await shared.admit(candidate) }
            let state = try await admission.value
            publish(state)
            committed = nil
            releaseTransition()
            await attempt.transport.discard()
            return state
        } catch {
            committed = nil
            publish(await shared.currentState())
            releaseTransition()
            await attempt.transport.discard()
            throw CatalogEmailAuthError.admissionFailed
        }
    }

    func cancelEmailSignIn(attemptID: UUID, ownerID: UUID) async -> Bool {
        if committed?.id == attemptID && committed?.ownerID == ownerID { return false }
        guard let attempt = pending, attempt.id == attemptID, attempt.ownerID == ownerID else { return false }
        pending = nil
        await attempt.transport.discard()
        return true
    }

    func detachEmailSignIn(ownerID: UUID) async {
        guard let attempt = pending, attempt.ownerID == ownerID else { return }
        pending = nil
        await attempt.transport.discard()
    }

    func signOut() async throws {
        let old = pending
        pending = nil
        await acquireTransition()
        try await finishSignOut(discarding: old)
    }

    func signOut(expectedSubjectID: String) async throws -> Bool {
        await acquireTransition()
        guard !Task.isCancelled else {
            releaseTransition()
            throw CancellationError()
        }
        let currentSubjectID = await shared.currentSubjectID()
        guard !Task.isCancelled else {
            releaseTransition()
            throw CancellationError()
        }
        guard currentSubjectID == nil || currentSubjectID == expectedSubjectID else {
            releaseTransition()
            return false
        }
        // Even an absent SDK projection must pass the storage adapter's
        // removal verification. Preserve a new pending login if already signed out.
        let old = currentSubjectID == nil ? nil : pending
        if currentSubjectID != nil { pending = nil }
        try await finishSignOut(discarding: old)
        return true
    }

    private func finishSignOut(discarding old: Pending?) async throws {
        do {
            let shared = shared
            try await Task { try await shared.signOut() }.value
            publish(await shared.currentState())
            releaseTransition()
            if let old { await old.transport.discard() }
        } catch {
            publish(await shared.currentState())
            releaseTransition()
            if let old { await old.transport.discard() }
            throw error
        }
    }

    /// Existing native Apple and MFA operations use this same gate. Their nested work must call
    /// private operations rather than recursively enter this method.
    func withSessionTransition<T: Sendable>(
        replacingEmail: Bool = false,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let old = replacingEmail ? pending : nil
        if replacingEmail { pending = nil }
        await acquireTransition()
        guard !Task.isCancelled else {
            releaseTransition()
            if let old { await old.transport.discard() }
            throw CancellationError()
        }
        do {
            let result = try await Task { try await operation() }.value
            publish(await shared.currentState())
            releaseTransition()
            if let old { await old.transport.discard() }
            return result
        } catch {
            publish(await shared.currentState())
            releaseTransition()
            if let old { await old.transport.discard() }
            throw error
        }
    }

    private func requestCode(_ attempt: Pending, isResend: Bool = false) async throws -> CatalogEmailAuthAttempt {
        do {
            try await attempt.transport.requestCode(email: attempt.email)
            guard pending?.id == attempt.id, !Task.isCancelled else {
                if pending?.id == attempt.id { pending = nil }
                await attempt.transport.discard()
                throw CatalogEmailAuthError.superseded
            }
            pending?.phase = .ready
            return attempt.presentation
        } catch {
            guard pending?.id == attempt.id else { throw CatalogEmailAuthError.superseded }
            let failure = safeError(error)
            if isResend, !Task.isCancelled, failure != .cancelled {
                pending?.phase = .ready
            } else {
                pending = nil
                await attempt.transport.discard()
            }
            throw failure
        }
    }

    private func activeAttempt(id: UUID, ownerID: UUID) throws -> Pending {
        guard !Task.isCancelled else { throw CatalogEmailAuthError.cancelled }
        guard let attempt = pending, attempt.id == id, attempt.ownerID == ownerID else {
            throw CatalogEmailAuthError.superseded
        }
        guard monotonicNow() < attempt.expiresAt else { throw CatalogEmailAuthError.expiredAttempt }
        return attempt
    }

    private func safeError(_ error: any Error) -> CatalogEmailAuthError {
        if let error = error as? CatalogEmailAuthError { return error }
        if error is CancellationError { return .cancelled }
        return .networkUnavailable
    }

    private func publish(_ state: CatalogAuthState?) {
        guard state != acceptedState else { return }
        acceptedState = state
        for observer in observers.values { observer.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        if observers.isEmpty {
            observation?.cancel()
            observation = nil
        }
    }

    var observerCount: Int { observers.count }
    var queuedTransitionCount: Int { transitionWaiters.count }

    private func acquireTransition() async {
        if !transitionHeld { transitionHeld = true; return }
        await withCheckedContinuation { transitionWaiters.append($0) }
    }

    private func releaseTransition() {
        if transitionWaiters.isEmpty { transitionHeld = false }
        else { transitionWaiters.removeFirst().resume() }
    }
}
