import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class WallpaperWindow: NSWindow {
    let canvas = WallpaperCanvasView(frame: .zero)
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    private var occlusionToken: (any NSObjectProtocol)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        canHide = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        )
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        contentView = canvas
        setFrame(screen.frame, display: true)

        occlusionToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publishVisibility()
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
        publishVisibility()
    }

    func updateFrame(for screen: NSScreen) {
        guard frame != screen.frame else { return }
        setFrame(screen.frame, display: true)
    }

    func tearDown() {
        if let occlusionToken {
            NotificationCenter.default.removeObserver(occlusionToken)
            self.occlusionToken = nil
        }
        onVisibilityChange = nil
        orderOut(nil)
        contentView = nil
        close()
    }

    private func publishVisibility() {
        onVisibilityChange?(occlusionState.contains(.visible) && isVisible)
    }
}

@MainActor
final class WallpaperCanvasView: NSView {
    private let backgroundLayer = CALayer()
    private var surfaceLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = backgroundLayer
        backgroundLayer.backgroundColor = NSColor.black.cgColor
        backgroundLayer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WallpaperCanvasView does not support NSCoder")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surfaceLayer in surfaceLayers {
            surfaceLayer.frame = bounds
            for child in surfaceLayer.sublayers ?? [] {
                child.frame = surfaceLayer.bounds
            }
        }
        CATransaction.commit()
    }

    func addSurface(_ surfaceLayer: CALayer, visible: Bool) {
        surfaceLayer.frame = bounds
        surfaceLayer.opacity = visible ? 1 : 0
        for child in surfaceLayer.sublayers ?? [] {
            child.frame = surfaceLayer.bounds
        }
        backgroundLayer.addSublayer(surfaceLayer)
        surfaceLayers.append(surfaceLayer)
    }

    func crossfade(
        from oldLayer: CALayer?,
        to newLayer: CALayer,
        completion: @escaping @MainActor () -> Void
    ) {
        guard
            let oldLayer,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oldLayer?.opacity = 0
            newLayer.opacity = 1
            CATransaction.commit()
            completion()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut)
        )
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                completion()
            }
        }
        oldLayer.opacity = 0
        newLayer.opacity = 1
        CATransaction.commit()
    }

    func removeSurface(_ surfaceLayer: CALayer) {
        surfaceLayer.removeAllAnimations()
        surfaceLayer.removeFromSuperlayer()
        surfaceLayers.removeAll { $0 === surfaceLayer }
    }

    func removeAllSurfaces() {
        for surfaceLayer in surfaceLayers {
            surfaceLayer.removeAllAnimations()
            surfaceLayer.removeFromSuperlayer()
        }
        surfaceLayers.removeAll(keepingCapacity: false)
    }
}
