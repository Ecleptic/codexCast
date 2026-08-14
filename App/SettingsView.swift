import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    NavigationLink("Audio Settings") { AudioSettingsView() }
                }

                Section("Library") {
                    NavigationLink("Episode Limits") { EpisodeLimitsView() }
                    NavigationLink("Storage") { StorageView() }
                    NavigationLink("Import & Export") { ImportExportView() }
                }

                Section("Ad Detection") {
                    NavigationLink("Learned Patterns") { PatternsView() }
                    NavigationLink("Sponsors") { SponsorsView() }
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
