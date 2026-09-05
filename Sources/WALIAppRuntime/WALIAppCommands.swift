import SwiftUI

private struct WALISettingsActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var waliSettingsAction: (@MainActor () -> Void)? {
        get { self[WALISettingsActionKey.self] }
        set { self[WALISettingsActionKey.self] = newValue }
    }
}

public struct WALIAppCommands: Commands {
    @FocusedValue(\.waliSettingsAction) private var openSettings

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings?() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(openSettings == nil)
        }
    }
}
