#if !WALI_APP_STORE
/// Exact direct peers shared by connection authentication and foreground activation.
enum DirectAgentIdentity {
    static func foregroundIdentifier(for agentIdentifier: String?) -> String? {
        let peers = [
            "io.github.codewithinferno.wali.WALIAgent": "io.github.codewithinferno.wali.WALI",
            "com.wali.development.WALIAgent": "com.wali.development.WALI",
            "com.wali.debug.WALIAgent": "com.wali.debug.WALI",
        ]
        return peers[agentIdentifier ?? "io.github.codewithinferno.wali.WALIAgent"]
    }
}
#endif
