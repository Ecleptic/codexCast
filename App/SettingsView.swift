import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    NavigationLink("Audio Settings") { AudioSettingsView() }
                }

                Section("Appearance") {
                    NavigationLink("App Icon") { AppIconSettingsView() }
                    NavigationLink("Video") { VideoSettingsView() }
                }

                Section("Library") {
                    NavigationLink("Show Defaults") { DefaultShowSettingsView() }
                    NavigationLink("Episode Limits") { EpisodeLimitsView() }
                    NavigationLink("Storage") { StorageView() }
                    NavigationLink("Import & Export") { ImportExportView() }
                    NavigationLink("YouTube") { YouTubeSettingsView() }
                }

                Section("Ad Detection") {
                    NavigationLink("Learned Patterns") { PatternsView() }
                    NavigationLink("Sponsors") { SponsorsView() }
                }

                Section {
                    LabeledContent("Last checked") {
                        if let last = model.lastRefreshedAt {
                            Text(last, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Last background check") {
                        if let last = model.lastBackgroundRunAt {
                            Text(last, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                    Button("Check for New Episodes Now") {
                        Task { await model.refreshFollowedNow() }
                    }
                    .disabled(model.isRefreshing)
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text(
                        """
                        iOS decides when apps may check in the background, and \
                        it grants that time sparingly — a few times a day for \
                        most apps. Codex Cast also checks whenever you open it, \
                        which is usually what surfaces a new episode first. \
                        Apps that alert within minutes of publication do it by \
                        running a server that watches feeds and pings the phone.
                        """
                    )
                }

                Section("Privacy") {
                    // §12.1 — the product claim, stated plainly where it lives.
                    Text(
                        """
                        Everything happens on this device. Transcription is \
                        on-device. Ad detection is on-device. No account, no \
                        server, no API key, no telemetry. Audio and \
                        transcripts never leave your phone.
                        """
                    )
                    .font(.footnote)
                }


            }
            .navigationTitle("Settings")
        }
    }
}
