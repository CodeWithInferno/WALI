import AppKit
import Foundation
import ServiceManagement

public enum AgentLifecycleError: LocalizedError {
    case missingConfiguration
    case consentRequired
    case requiresApproval
    case anotherDistributionRunning
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "WALI's background service configuration is missing."
        case .consentRequired: "Allow background playback before starting WALI's wallpaper service."
        case .requiresApproval: "WALI needs approval in Login Items to keep your wallpaper running."
        case .anotherDistributionRunning: "Quit the other edition of WALI before starting this one."
        case .operationInProgress: "WALI is finishing background service setup. Try Quit again in a moment."
        }
    }
}

@MainActor
protocol AgentServiceRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
private struct NativeAgentServiceRegistration: AgentServiceRegistration {
    let service: SMAppService
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

/// Service consent is per distribution and independent of launch-at-login.
@MainActor
public final class AgentLifecycleController {
    private static let consentKey = "WALIBackgroundPlaybackConsent"
    private let registrations: [any AgentServiceRegistration]?
    private let defaults: UserDefaults
    private let requiresExplicitConsent: Bool
    private let expectedAgentIdentifier: String?
    private let runningAgentIdentifiers: @MainActor () -> Set<String>
    private(set) var isReinstalling = false
    var onReinstallCompleted: (@MainActor () -> Void)?
    #if !WALI_APP_STORE
    private var agentWasActive = false
    #endif

    public convenience init() {
        #if WALI_APP_STORE
        let requiresConsent = true
        #else
        let requiresConsent = false
        #endif
        self.init(
            registrations: Self.configuredRegistrations(),
            defaults: .standard,
            requiresExplicitConsent: requiresConsent,
            expectedAgentIdentifier: Bundle.main.object(forInfoDictionaryKey: "WALIExpectedAgentBundleIdentifier") as? String,
            runningAgentIdentifiers: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        )
    }

    init(
        registrations: [any AgentServiceRegistration]?,
        defaults: UserDefaults,
        requiresExplicitConsent: Bool,
        expectedAgentIdentifier: String? = nil,
        runningAgentIdentifiers: (@MainActor () -> Set<String>)? = nil
    ) {
        self.registrations = registrations
        self.defaults = defaults
        self.requiresExplicitConsent = requiresExplicitConsent
        self.expectedAgentIdentifier = expectedAgentIdentifier
        self.runningAgentIdentifiers = runningAgentIdentifiers ?? { [] }
    }

    public var hasBackgroundPlaybackConsent: Bool {
        !requiresExplicitConsent || defaults.bool(forKey: Self.consentKey)
    }

    public func allowBackgroundPlayback() {
        defaults.set(true, forKey: Self.consentKey)
    }

    public var requiresApproval: Bool {
        registrations?.contains(where: { $0.status == .requiresApproval }) == true
    }

    #if !WALI_APP_STORE
    /// Only the first registration belongs to the agent. Helper approval does
    /// not establish whether the desktop agent is inactive.
    var canQuitWithoutAgent: Bool {
        guard !isReinstalling, let expectedAgentIdentifier,
              let agent = registrations?.first else { return false }
        if agent.status == .enabled || runningAgentIdentifiers().contains(expectedAgentIdentifier) {
            agentWasActive = true
        }
        guard !agentWasActive else { return false }
        switch agent.status {
        case .notRegistered, .notFound, .requiresApproval: return true
        case .enabled: return false
        @unknown default: return false
        }
    }
    #endif

    public func ensureRunning() throws {
        try Task.checkCancellation()
        guard !isReinstalling else { throw AgentLifecycleError.operationInProgress }
        #if !WALI_APP_STORE
        defer { _ = canQuitWithoutAgent }
        #endif
        guard hasBackgroundPlaybackConsent else { throw AgentLifecycleError.consentRequired }
        guard let registrations else { throw AgentLifecycleError.missingConfiguration }
        if requiresExplicitConsent, let expectedAgentIdentifier {
            let editions: Set<String> = [
                "io.github.codewithinferno.wali.WALIAgent",
                "com.wali.WALIAgent", "com.wali.development.WALIAgent", "com.wali.debug.WALIAgent",
                "com.wali.store.WALIAgent", "com.wali.store.development.WALIAgent",
            ]
            let others = editions.subtracting([expectedAgentIdentifier])
            guard others.isDisjoint(with: runningAgentIdentifiers()) else {
                throw AgentLifecycleError.anotherDistributionRunning
            }
        }
        for registration in registrations {
            switch registration.status {
            case .enabled: continue
            case .requiresApproval: throw AgentLifecycleError.requiresApproval
            case .notRegistered, .notFound: try registration.register()
            @unknown default: try registration.register()
            }
            guard !requiresExplicitConsent || registration.status == .enabled else {
                throw AgentLifecycleError.requiresApproval
            }
        }
    }

    public func reinstallAgent() async throws {
        try Task.checkCancellation()
        guard !isReinstalling else { throw AgentLifecycleError.operationInProgress }
        #if !WALI_APP_STORE
        _ = canQuitWithoutAgent
        #endif
        guard hasBackgroundPlaybackConsent else { throw AgentLifecycleError.consentRequired }
        guard let registrations else { throw AgentLifecycleError.missingConfiguration }
        isReinstalling = true
        defer {
            isReinstalling = false
            onReinstallCompleted?()
        }
        for registration in registrations where registration.status != .notRegistered && registration.status != .notFound {
            try Task.checkCancellation()
            try await registration.unregister()
            try Task.checkCancellation()
        }
        try await Task.sleep(for: .seconds(3))
        isReinstalling = false
        try ensureRunning()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func setMainApplicationLaunchAtLogin(_ enabled: Bool) throws {
        let mainApplication = SMAppService.mainApp
        if enabled {
            guard mainApplication.status != .enabled else { return }
            if mainApplication.status == .requiresApproval { throw AgentLifecycleError.requiresApproval }
            try mainApplication.register()
        } else if mainApplication.status != .notRegistered {
            try mainApplication.unregister()
        }
    }

    private static func configuredRegistrations() -> [any AgentServiceRegistration]? {
        guard let plist = Bundle.main.object(forInfoDictionaryKey: "WALIAgentLaunchAgentPlistName") as? String,
              !plist.isEmpty else { return nil }
        var result: [any AgentServiceRegistration] = [
            NativeAgentServiceRegistration(service: .agent(plistName: plist)),
        ]
        #if !WALI_APP_STORE
        guard let helper = Bundle.main.object(forInfoDictionaryKey: "WALILockScreenHelperLaunchAgentPlistName") as? String,
              !helper.isEmpty else { return nil }
        result.append(NativeAgentServiceRegistration(service: .agent(plistName: helper)))
        #endif
        return result
    }
}
