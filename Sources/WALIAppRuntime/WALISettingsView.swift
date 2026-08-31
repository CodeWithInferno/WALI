import SwiftUI
import WALIUI

public struct WALISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WALIPreferencesPresentation
    private let storage: WALIStoragePresentation
    let onSave: (WALIPreferencesPresentation) -> Void

    public init(
        preferences: WALIPreferencesPresentation,
        storage: WALIStoragePresentation = .init(),
        onSave: @escaping (WALIPreferencesPresentation) -> Void
    ) {
        _draft = State(initialValue: preferences)
        self.storage = storage
        self.onSave = onSave
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Launch WALI at Login", isOn: $draft.launchAtLogin)
                    Toggle("Start Paused", isOn: $draft.startPaused)
                }

                Section("Playback") {
                    Picker("Quality", selection: $draft.quality) {
                        Text("Automatic").tag(WALIQualityPreference.automatic)
                        Text("Efficiency").tag(WALIQualityPreference.efficiency)
                        Text("Best Quality").tag(WALIQualityPreference.quality)
                    }

                    Picker("Fit", selection: $draft.contentFit) {
                        Text("Fill Display").tag(WALIContentFitPreference.fill)
                        Text("Fit Entire Video").tag(WALIContentFitPreference.fit)
                    }

                    Picker("Low Power Mode", selection: $draft.lowPowerBehavior) {
                        Text("Pause").tag(WALILowPowerPreference.pause)
                        Text("Reduce Quality").tag(WALILowPowerPreference.reduceQuality)
                        Text("Continue Playing").tag(WALILowPowerPreference.continuePlaying)
                    }
                }

                Section("Storage") {
                    LabeledContent("Used", value: storage.usedBytes.formatted(.byteCount(style: .file)))
                    if let limit = storage.limitBytes, limit > 0 {
                        ProgressView(value: storageFraction)
                            .accessibilityLabel("Storage used")
                            .accessibilityValue(storageDescription)
                        Text(storageDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("WALI stores prepared copies locally and keeps your original videos untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(12)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 470)
        .navigationTitle("Settings")
        .accessibilityIdentifier("WALI.Settings")
    }

    private var storageFraction: Double {
        guard let limit = storage.limitBytes, limit > 0 else { return 0 }
        return min(max(Double(storage.usedBytes) / Double(limit), 0), 1)
    }

    private var storageDescription: String {
        guard let limit = storage.limitBytes else {
            return storage.usedBytes.formatted(.byteCount(style: .file))
        }
        return "\(storage.usedBytes.formatted(.byteCount(style: .file))) of \(limit.formatted(.byteCount(style: .file)))"
    }
}
