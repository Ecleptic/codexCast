import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
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

                Section("Coming soon") {
                    LabeledContent("Pipeline defaults", value: "after detection lands")
                    LabeledContent("Skip policies", value: "after detection lands")
                    LabeledContent("Export learning data", value: "after learning lands")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
