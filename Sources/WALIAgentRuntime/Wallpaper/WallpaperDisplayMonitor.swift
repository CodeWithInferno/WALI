import AppKit
import CoreGraphics
import Foundation

/// Stable display key used by the wallpaper runtime.
///
/// The value is derived from Core Graphics' display UUID where possible. The
/// additional aliases on ``WallpaperDisplay`` let persisted assignments made
/// against older observations survive topology changes.
public struct WallpaperDisplayIdentifier: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A sendable description of a currently connected display.
public struct WallpaperDisplay: Sendable, Hashable, Identifiable {
    public let id: WallpaperDisplayIdentifier
    public let aliases: Set<WallpaperDisplayIdentifier>
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat
    public let isBuiltIn: Bool

    public init(
        id: WallpaperDisplayIdentifier,
        aliases: Set<WallpaperDisplayIdentifier>,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.aliases = aliases
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.isBuiltIn = isBuiltIn
    }

    public func matches(_ identifier: WallpaperDisplayIdentifier) -> Bool {
        id == identifier || aliases.contains(identifier)
    }
}

@MainActor
public final class WallpaperDisplayMonitor {
    public typealias ChangeHandler = @MainActor ([WallpaperDisplay]) -> Void

    public var onChange: ChangeHandler?
    public private(set) var displays: [WallpaperDisplay] = []

    private var observedScreens: [WallpaperDisplayIdentifier: NSScreen] = [:]
    private var notificationToken: (any NSObjectProtocol)?
    private var reconciliationTask: Task<Void, Never>?
    private var isRunning = false

    public init() {}

    /// Begins topology observation and immediately publishes the current screens.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        notificationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReconciliation()
            }
        }

        reconcileNow()
    }

    /// Stops observation. Calling this more than once is safe.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        reconciliationTask?.cancel()
        reconciliationTask = nil
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
        observedScreens.removeAll(keepingCapacity: false)
        displays.removeAll(keepingCapacity: false)
    }

    /// Re-reads `NSScreen.screens` without waiting for the debounce interval.
    public func reconcileNow() {
        reconciliationTask?.cancel()
        reconciliationTask = nil

        let observations = NSScreen.screens.compactMap(Self.observation(for:))
            .sorted { $0.display.id.rawValue < $1.display.id.rawValue }
        let nextDisplays = observations.map(\.display)

        observedScreens = Dictionary(
            observations.map { ($0.display.id, $0.screen) },
            uniquingKeysWith: { _, newest in newest }
        )

        guard nextDisplays != displays else { return }
        displays = nextDisplays
        onChange?(nextDisplays)
    }

    func screen(matching identifier: WallpaperDisplayIdentifier) -> NSScreen? {
        for display in displays where display.matches(identifier) {
            return observedScreens[display.id]
        }
        return nil
    }

    func screen(for display: WallpaperDisplay) -> NSScreen? {
        observedScreens[display.id]
    }

    private func scheduleReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reconcileNow()
        }
    }

    private static func observation(for screen: NSScreen) -> Observation? {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            return nil
        }

        let directID = CGDirectDisplayID(number.uint32Value)
        let sessionIdentifier = WallpaperDisplayIdentifier(
            rawValue: "session:\(directID)"
        )
        var aliases: Set<WallpaperDisplayIdentifier> = [sessionIdentifier]

        let vendor = CGDisplayVendorNumber(directID)
        let model = CGDisplayModelNumber(directID)
        let serial = CGDisplaySerialNumber(directID)
        // Vendor/model alone is ambiguous when two identical displays are
        // attached. Treat the hardware tuple as a durable alias only when the
        // display exposes a nonzero serial number.
        if serial != 0 {
            aliases.insert(
                WallpaperDisplayIdentifier(
                    rawValue: String(
                        format: "hardware:%08x:%08x:%08x",
                        vendor,
                        model,
                        serial
                    )
                )
            )
        }

        let uuidIdentifier: WallpaperDisplayIdentifier? =
            CGDisplayCreateUUIDFromDisplayID(directID).map { unmanagedDisplayUUID in
                let displayUUID = unmanagedDisplayUUID.takeRetainedValue()
                let value = CFUUIDCreateString(nil, displayUUID) as String
                return WallpaperDisplayIdentifier(
                    rawValue: "uuid:\(value.lowercased())"
                )
            }
        if let uuidIdentifier {
            aliases.insert(uuidIdentifier)
        }

        let preferredIdentifier = uuidIdentifier
            ?? aliases.first(where: { $0.rawValue.hasPrefix("hardware:") })
            ?? sessionIdentifier
        aliases.remove(preferredIdentifier)

        return Observation(
            display: WallpaperDisplay(
                id: preferredIdentifier,
                aliases: aliases,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                backingScaleFactor: screen.backingScaleFactor,
                isBuiltIn: CGDisplayIsBuiltin(directID) != 0
            ),
            screen: screen
        )
    }

    private struct Observation {
        let display: WallpaperDisplay
        let screen: NSScreen
    }
}
