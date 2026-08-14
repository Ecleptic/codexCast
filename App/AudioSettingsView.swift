import CodexCastPlayback
import SwiftUI

/// Global audio settings (A5.4, §10). Per-show overrides use the same
/// three-state mechanism and appear on the show screen.
struct AudioSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Stepper(
                    value: $model.audioSettings.speed,
                    in: PlaybackSpeed.minimum...PlaybackSpeed.maximum,
                    step: PlaybackSpeed.step
                ) {
                    LabeledContent("Playback Speed") {
                        Text(String(format: "%.2f×", model.audioSettings.speed))
                            .monospacedDigit()
                    }
                }
            }

            Section {
                Toggle(isOn: $model.audioSettings.trimSilence) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart Speed")
                        Text("Shorter silences")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $model.audioSettings.voiceBoostEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Boost")
                        Text("Clear, consistent volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.audioSettings.voiceBoostEnabled {
                    Picker("Strength", selection: $model.audioSettings.voiceBoostLevel) {
                        Text("Low").tag(VoiceBoostLevel.low)
                        Text("High").tag(VoiceBoostLevel.high)
                    }
                    .pickerStyle(.segmented)
                }

                NavigationLink {
                    AdvancedAudioView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced")
                        Text("Mono, normalization, and more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Applies to all podcasts except those with custom audio settings.")
            }
        }
        .navigationTitle("Audio Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.audioSettings) {
            model.applyAudioSettings()
        }
    }
}

private struct AdvancedAudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Toggle("Mono Downmix", isOn: $model.audioSettings.monoDownmix)
            Toggle("Volume Normalization", isOn: $model.audioSettings.volumeNormalization)
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.audioSettings) {
            model.applyAudioSettings()
        }
    }
}
