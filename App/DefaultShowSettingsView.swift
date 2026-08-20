import CodexCastCore
import SwiftUI

/// Global per-class defaults: what a FOLLOWED show gets versus what a merely
/// ADDED show gets — episode retention, auto download/transcribe/scan, and
/// notifications, set once instead of ninety-seven times.
///
/// Editing a default here IS the apply. Every show that has not taken a
/// setting into its own hands follows these values live, including shows you
/// added long before you changed them — the old behaviour, where the values
/// were copied onto each show once and then went stale, is what made editing
/// a default look like it did nothing.
///
/// The button per class is only for shows that HAVE customised something:
/// it clears their overrides so they follow along again.
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
            if defaults.wrappedValue.autoDownload || defaults.wrappedValue.autoTranscribe {
                Text("Applies to episodes published in the last \(AppModel.queueRecencyDays) days, at most \(AppModel.queuePerShowLimit) per show at a time. Older episodes download when you play them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Notify me", selection: defaults.notifyOn) {
                Text("Never").tag(AppModel.NotifyOn.never)
                Text("New episode").tag(AppModel.NotifyOn.newEpisode)
                Text("Downloaded").tag(AppModel.NotifyOn.downloaded)
                Text("Ready (ads scanned)").tag(AppModel.NotifyOn.processed)
            }

            let customized = model.customizedShowCount(followed: followedClass)
            Button("Reset \(customized) Customised Show\(customized == 1 ? "" : "s")") {
                Task {
                    await model.resetOverrides(followedShows: followedClass)
                    applied = "\(customized) show\(customized == 1 ? "" : "s") now follow\(customized == 1 ? "s" : "") these defaults."
                }
            }
            .disabled(customized == 0)
        } header: {
            Text(title)
        } footer: {
            Text(subtitle + " These apply to every \(followedClass ? "followed" : "added") show straight away. A show that sets its own value on its settings page keeps it — the button above puts those shows back on these defaults.")
        }
    }

    private func count(followed: Bool) -> Int {
        model.library.filter { $0.isFollowed == followed }.count
    }
}
