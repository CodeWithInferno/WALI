#if WALI_APP_STORE
import Foundation
import Security

/// The two approved Store channels have disjoint peers, including when signed
/// by the same developer team. Configuration errors never select a direct peer.
enum StoreAgentPeerRequirement {
    static func expression(appIdentifier: String, agentIdentifier: String, team: String) throws -> String {
        let peers = [
            "com.wali.store.development.WALI": "com.wali.store.development.WALIAgent",
            "com.wali.store.WALI": "com.wali.store.WALIAgent",
        ]
        guard peers[appIdentifier] == agentIdentifier,
              !team.isEmpty,
              team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw AgentConnectionError.invalidProxy
        }
        return "anchor apple generic and identifier \"\(agentIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func configured() throws -> String {
        guard let appIdentifier = Bundle.main.bundleIdentifier,
              let agentIdentifier = Bundle.main.object(forInfoDictionaryKey: "WALIExpectedAgentBundleIdentifier") as? String else {
            throw AgentConnectionError.invalidProxy
        }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw AgentConnectionError.invalidProxy
        }
        return try expression(appIdentifier: appIdentifier, agentIdentifier: agentIdentifier, team: team)
    }
}
#endif
