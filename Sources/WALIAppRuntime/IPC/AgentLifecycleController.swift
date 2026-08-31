import AppKit
import Foundation
import ServiceManagement

public enum AgentLifecycleError: LocalizedError {
    case missingConfiguration
    case requiresApproval

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "WALI's background service configuration is missing."
        case .requiresApproval:
            "WALI needs approval in Login Items to keep your wallpaper running."
        }
    }
}

/// Registers the bundled launch agent and exposes its user-approval state.
@MainActor
public final class AgentLifecycleController {
    private var service: SMAppService? {
        guard let plistName = Bundle.main.object(
            forInfoDictionaryKey: "WALIAgentLaunchAgentPlistName"
        ) as? String, !plistName.isEmpty else {
            return nil
        }
        return SMAppService.agent(plistName: plistName)
    }

    public init() {}

    public var requiresApproval: Bool {
        service?.status == .requiresApproval
    }

    public func ensureRunning() throws {
        guard let service else { throw AgentLifecycleError.missingConfiguration }
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw AgentLifecycleError.requiresApproval
        case .notRegistered, .notFound:
            try service.register()
        @unknown default:
            try service.register()
        }
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func setMainApplicationLaunchAtLogin(_ enabled: Bool) throws {
        let mainApplication = SMAppService.mainApp
        if enabled {
            guard mainApplication.status != .enabled else { return }
            if mainApplication.status == .requiresApproval {
                throw AgentLifecycleError.requiresApproval
            }
            try mainApplication.register()
        } else if mainApplication.status != .notRegistered {
            try mainApplication.unregister()
        }
    }
}
