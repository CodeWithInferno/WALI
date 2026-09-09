#if WALI_APP_STORE
import AppKit
import SwiftUI

/// Observes the real window without a timer, including minimize, Hide WALI,
/// and occlusion; the authenticated connection outlives this visible surface.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stop()
    }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.report() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: NSApplication.shared, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.report() }
                })
            }
            report()
        }

        func report() {
            let visible = window.map {
                $0.isVisible && !$0.isMiniaturized && !NSApplication.shared.isHidden && $0.occlusionState.contains(.visible)
            } ?? false
            guard lastReported != visible else { return }
            lastReported = visible
            onChange?(visible)
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if lastReported == true { onChange?(false) }
            lastReported = nil
        }
    }
}
#endif
