import AppKit
import Foundation

public enum WallpaperAutomaticPauseReason: String, Codable, Sendable, Hashable {
    case sessionLocked = "session_locked"
    case systemSleep = "system_sleep"
    case displayAsleep = "display_asleep"
    case windowOccluded = "window_occluded"
    case lowPower = "low_power"
    case thermalPressure = "thermal_pressure"
}

/// Coalesced system conditions that influence wallpaper playback.
@MainActor
public final class SystemEventSource {
    public typealias ChangeHandler = @MainActor (Set<WallpaperAutomaticPauseReason>) -> Void

    public var onChange: ChangeHandler?
    public private(set) var pauseReasons: Set<WallpaperAutomaticPauseReason> = []

    private var workspaceTokens: [any NSObjectProtocol] = []
    private var processTokens: [any NSObjectProtocol] = []
    private var distributedTokens: [any NSObjectProtocol] = []
    private var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(workspaceCenter, name: NSWorkspace.willSleepNotification) { source in
            source.set(.systemSleep, active: true)
        }
        observe(workspaceCenter, name: NSWorkspace.didWakeNotification) { source in
            source.set(.systemSleep, active: false)
        }
        observe(workspaceCenter, name: NSWorkspace.screensDidSleepNotification) { source in
            source.set(.displayAsleep, active: true)
        }
        observe(workspaceCenter, name: NSWorkspace.screensDidWakeNotification) { source in
            source.set(.displayAsleep, active: false)
        }
        observe(workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) { source in
            source.set(.sessionLocked, active: true)
        }
        observe(workspaceCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { source in
            source.set(.sessionLocked, active: false)
        }

        let processCenter = NotificationCenter.default
        observeProcess(processCenter, name: ProcessInfo.thermalStateDidChangeNotification)
        observeProcess(processCenter, name: .NSProcessInfoPowerStateDidChange)

        let distributedCenter = DistributedNotificationCenter.default()
        distributedTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.set(.sessionLocked, active: true)
                }
            }
        )
        distributedTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.set(.sessionLocked, active: false)
                }
            }
        )

        refreshProcessConditions(publish: false)
        onChange?(pauseReasons)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceTokens.removeAll(keepingCapacity: false)

        for token in processTokens {
            NotificationCenter.default.removeObserver(token)
        }
        processTokens.removeAll(keepingCapacity: false)

        let distributedCenter = DistributedNotificationCenter.default()
        for token in distributedTokens {
            distributedCenter.removeObserver(token)
        }
        distributedTokens.removeAll(keepingCapacity: false)
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor (SystemEventSource) -> Void
    ) {
        workspaceTokens.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
            }
        )
    }

    private func observeProcess(_ center: NotificationCenter, name: Notification.Name) {
        processTokens.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshProcessConditions()
                }
            }
        )
    }

    private func refreshProcessConditions(publish: Bool = true) {
        let previousReasons = pauseReasons
        let processInfo = ProcessInfo.processInfo
        set(.lowPower, active: processInfo.isLowPowerModeEnabled, publish: false)
        set(
            .thermalPressure,
            active: processInfo.thermalState == .serious || processInfo.thermalState == .critical,
            publish: false
        )
        if publish, pauseReasons != previousReasons {
            onChange?(pauseReasons)
        }
    }

    private func set(
        _ reason: WallpaperAutomaticPauseReason,
        active: Bool,
        publish: Bool = true
    ) {
        let changed: Bool
        if active {
            changed = pauseReasons.insert(reason).inserted
        } else {
            changed = pauseReasons.remove(reason) != nil
        }
        guard publish, changed else { return }
        onChange?(pauseReasons)
    }
}
