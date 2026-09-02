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
    private var services: [SMAppService]? {
        guard let plistName = Bundle.main.object(
            forInfoDictionaryKey: "WALIAgentLaunchAgentPlistName"
        ) as? String, !plistName.isEmpty,
        let helperPlistName = Bundle.main.object(
            forInfoDictionaryKey: "WALILockScreenHelperLaunchAgentPlistName"
        ) as? String, !helperPlistName.isEmpty else {
            return nil
        }
        return [
            SMAppService.agent(plistName: plistName),
            SMAppService.agent(plistName: helperPlistName),
        ]
    }

    public init() {}

    public var requiresApproval: Bool {
        services?.contains(where: { $0.status == .requiresApproval }) == true
    }

    public func ensureRunning() throws {
        guard let services else { throw AgentLifecycleError.missingConfiguration }
        for service in services {
            switch service.status {
            case .enabled:
                continue
            case .requiresApproval:
                throw AgentLifecycleError.requiresApproval
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        }
    }

    /// Replaces a stale Service Management registration after the containing
    /// app bundle has been rebuilt in place. Normal installed updates do not
    /// need this; it is an explicit recovery path for support and development.
    public func reinstallAgent() async throws {
        guard let services else { throw AgentLifecycleError.missingConfiguration }
        for service in services where service.status != .notRegistered && service.status != .notFound {
            try await service.unregister()
        }
        // Service Management retires background-item records asynchronously.
        try await Task.sleep(for: .seconds(3))
        for service in services { try service.register() }
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
