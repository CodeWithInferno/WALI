#if !WALI_APP_STORE
import AppKit
import WALIWire

@MainActor
enum DirectAgentQuit {
    /// Let the foreground's native delegate initiate the authenticated Quit.
    /// This also reaches an application whose last window has been closed.
    static func requestForegroundQuit() throws -> Bool {
        guard let identifier = DirectAgentIdentity.foregroundIdentifier(for: Bundle.main.bundleIdentifier) else {
            throw AgentFailure(code: .internalFailure, message: "WALI could not identify its application.")
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        return try forwardIfPresent(applications.map { application in { application.terminate() } })
    }

    static func forwardIfPresent(_ requests: [() -> Bool]) throws -> Bool {
        guard !requests.isEmpty else { return false }
        var refused = false
        for request in requests where !request() { refused = true }
        guard !refused else {
            throw AgentFailure(
                code: .internalFailure,
                message: "WALI could not ask its application to quit. Try Quit from the WALI application."
            )
        }
        // Accepted means forwarded, not completed. The agent remains available
        // until that application's authenticated .quit request receives a reply.
        return true
    }
}
#endif
