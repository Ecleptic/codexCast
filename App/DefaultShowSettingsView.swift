import CodexCastCore
import SwiftUI

/// Global per-class defaults: what a FOLLOWED show gets versus what a merely
/// ADDED show gets — episode retention, auto download/transcribe/scan, and
/// notifications, set once instead of ninety-seven times.
///
/// Defaults apply automatically to newly added shows only; the "Apply to
/// all" buttons push them onto existing shows explicitly. Per-show settings
/// always win afterward.
struct DefaultShowSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var applied: String?

    private static let limitChoices: [(String, Int?)] = [
        ("Unlimited", nil), ("None", 0), ("1", 1), ("2", 2), ("3", 3),
        ("5", 5), ("10", 10), ("20", 20),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            classSection(
                title: "Followed Shows",
                subtitle: "Your regulars — they appear on Home and in New Releases.",
                defaults: $model.showDefaults.followed,
                followedClass: true
            )
            classSection(
                title: "Added Shows",
                subtitle: "The browsing library. Usually nothing automatic.",
                defaults: $model.showDefaults.added,
                followedClass: false
            )

            if let applied {
                Section { Text(applied).font(.footnote) }
            }
        }
        .navigationTitle("Show Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func classSection(
        title: String,
        subtitle: String,
        defaults: Binding<AppModel.ShowDefaults>,
        followedClass: Bool
    ) -> some View {
        Section {
            Picker("Keep downloaded episodes", selection: Binding(
                get: { defaults.wrappedValue.episodeLimit ?? -1 },
                set: { defaults.wrappedValue.episodeLimit = $0 == -1 ? nil : $0 }
            )) {
                ForEach(Self.limitChoices, id: \.0) { choice in
                    Text(choice.0).tag(choice.1 ?? -1)
                }
            }
            Toggle("Auto-download new episodes", isOn: defaults.autoDownload)
            Toggle("Transcribe after download", isOn: defaults.autoTranscribe)
            Toggle("Scan for ads after transcribing", isOn: defaults.autoScan)
            Picker("Notify me", selection: defaults.notifyOn) {
                Text("Never").tag(AppModel.NotifyOn.never)
                Text("New episode").tag(AppModel.NotifyOn.newEpisode)
                Text("Downloaded").tag(AppModel.NotifyOn.downloaded)
                Text("Ready (ads scanned)").tag(AppModel.NotifyOn.processed)
            }

            Button("Apply to All \(count(followed: followedClass)) \(followedClass ? "Followed" : "Added") Shows Now") {
                Task {
                    await model.applyDefaultsToAll(followedShows: followedClass)
                    applied = "Applied to \(count(followed: followedClass)) \(followedClass ? "followed" : "added") shows."
                }
            }
            .disabled(count(followed: followedClass) == 0)
        } header: {
            Text(title)
        } footer: {
            Text(subtitle + " New shows pick these up automatically; the button pushes them onto existing shows, replacing their per-show settings.")
        }
    }

    private func count(followed: Bool) -> Int {
        model.library.filter { $0.isFollowed == followed }.count
    }
}
