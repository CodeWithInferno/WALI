#if WALI_APP_STORE
import Foundation
import WALIWire

/// Each attempt is independent: a timeout is not an acknowledgement, and a
/// later Quit can retry the remaining authenticated connection.
enum StoreForegroundAcknowledgement {
    typealias Reply = @Sendable (Result<Void, Error>) -> Void
    static func wait(
        timeout: Duration = .seconds(2),
        send: @Sendable (@escaping Reply) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = PendingReply(continuation)
            Task {
                try? await Task.sleep(for: timeout)
                result.finish(.failure(AgentFailure(
                    code: .internalFailure,
                    message: "The WALI window did not acknowledge Quit. Try Quit again."
                )))
            }
            send { result.finish($0) }
        }
    }

    private final class PendingReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
#endif
