import SwiftUI
import WALIUI

/// Menu-bar scene for the long-lived wallpaper agent.
///
/// The agent composition root owns this scene and its bundled brand artwork.
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
            Label {
                Text("WALI")
            } icon: {
                Image("WALIMenuBar", bundle: .main)
                    .renderingMode(.template)
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
            .help(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
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
