import SwiftUI
import WALIUI

/// Menu-bar scene for the long-lived wallpaper agent.
///
/// The agent composition root owns when this scene is installed; the content
/// intentionally reuses the exact status panel shown in the main app toolbar.
public struct WALIMenuBarScene: Scene {
    @State private var model: WALIAppModel
    private let actions: any WALIUIActionHandling

    public init(model: WALIAppModel, actions: any WALIUIActionHandling) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some Scene {
        MenuBarExtra {
            StatusPanel(status: model.snapshot.renderer, actions: actions)
        } label: {
            Label("WALI", systemImage: menuBarSymbol)
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch model.snapshot.renderer.state {
        case .playing: "play.circle.fill"
        case .automaticallyPaused, .userPaused: "pause.circle.fill"
        case .converting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .error: "exclamationmark.triangle.fill"
        case .stopped: "circle.dashed"
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch model.snapshot.renderer.state {
        case .playing: "WALI, playing"
        case .automaticallyPaused: "WALI, automatically paused"
        case .userPaused: "WALI, paused"
        case .converting: "WALI, converting"
        case .error: "WALI, needs attention"
        case .stopped: "WALI, stopped"
        }
    }
}
