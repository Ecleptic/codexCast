import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Per-show info and settings (§12 "Show detail" settings surface): episode
/// retention, storage, and unsubscribe. Skip policy, playback overrides, and
/// position rules join this screen as their features land.
struct ShowSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let podcast: PodcastRecord

    @State private var limitIndex: Int = 0
    @State private var storageBytes: Int64?
    @State private var confirmUnsubscribe = false
    @State private var autoDownload = false
    @State private var speedOverride: Double = 0   // 0 = inherit
    @State private var pipelinePrefs = AppModel.ShowPipelinePrefs()
    @State private var notifyOn: AppModel.NotifyOn = .never

    private static let limitChoices: [Int?] = [nil, 1, 2, 3, 5, 10, 20, 50]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(podcast.title).font(.headline)
                        if let author = podcast.author {
                            Text(author).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)

                if let summary = podcast.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }

            Section {
                Picker("Keep", selection: $limitIndex) {
                    ForEach(Self.limitChoices.indices, id: \.self) { index in
                        Text(limitLabel(Self.limitChoices[index])).tag(index)
                    }
                }
                .onChange(of: limitIndex) {
                    Task {
                        await model.setEpisodeLimit(Self.limitChoices[limitIndex], for: podcast.id)
                    }
                }

                LabeledContent("Storage used") {
                    if let bytes = storageBytes {
                        Text(ByteCountFormatStyle().format(bytes))
                    } else {
                        Text("—")
                    }
                }
                Toggle("Auto-download new episodes", isOn: autoDownloadBinding)
            } header: {
                Text("Downloads")
            } footer: {
                Text(
                    """
                    Older downloads beyond the limit are deleted automatically. \
                    Transcripts and everything Codex Cast has learned about \
                    this show are always kept.
                    """
                )
            }

            Section {
                Toggle("Transcribe after download", isOn: pipelineBinding(\.autoTranscribe))
                Toggle("Scan for ads after transcribing", isOn: pipelineBinding(\.autoScan))
            } header: {
                Text("Processing")
            } footer: {
                Text("Runs automatically when new episodes download — overnight while charging, or on refresh.")
            }

            Section {
                Picker("Notify me", selection: notifyBinding) {
                    Text("Never").tag(AppModel.NotifyOn.never)
                    Text("New episode").tag(AppModel.NotifyOn.newEpisode)
                    Text("Downloaded").tag(AppModel.NotifyOn.downloaded)
                    Text("Ready (ads scanned)").tag(AppModel.NotifyOn.processed)
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Picker("Playback speed", selection: $speedOverride) {
                    Text("Use global").tag(0.0)
                    ForEach([0.8, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { speed in
                        Text(String(format: "%.2g×", speed)).tag(speed)
                    }
                }
                .onChange(of: speedOverride) {
                    Task {
                        var overrides = model.overrides(for: podcast.id)
                        overrides.speed = speedOverride == 0 ? nil : speedOverride
                        await model.saveOverrides(overrides, podcastID: podcast.id)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Overrides the global speed for this show only.")
            }

            Section("Feed") {
                LabeledContent("URL") {
                    Text(podcast.feedURL)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let error = podcast.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Button("Refresh Now") {
                    Task {
                        await model.refresh(podcast)
                        await model.reloadLibrary()
                    }
                }
            }

            Section {
                Button("Unsubscribe", role: .destructive) {
                    confirmUnsubscribe = true
                }
            } footer: {
                Text("Removes the show, its episodes, and its downloads.")
            }
        }
        .navigationTitle("Show Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Unsubscribe from \(podcast.title)?",
            isPresented: $confirmUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                Task {
                    try? await model.podcasts.unsubscribe(podcastID: podcast.id)
                    await model.reloadLibrary()
                    dismiss()
                }
            }
        }
        .task {
            limitIndex = Self.limitChoices.firstIndex(of: podcast.episodeLimit) ?? 0
            autoDownload = podcast.autoDownloadEnabled
            speedOverride = model.overrides(for: podcast.id).speed ?? 0
            pipelinePrefs = model.pipelinePrefs(for: podcast.id)
            notifyOn = model.notifySetting(for: podcast.id)
            storageBytes = try? await model.retention.downloadedByteCount(podcastID: podcast.id)
        }
    }

    private func pipelineBinding(
        _ keyPath: WritableKeyPath<AppModel.ShowPipelinePrefs, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { pipelinePrefs[keyPath: keyPath] },
            set: { newValue in
                pipelinePrefs[keyPath: keyPath] = newValue
                Task { await model.savePipelinePrefs(pipelinePrefs, podcastID: podcast.id) }
            }
        )
    }

    private var notifyBinding: Binding<AppModel.NotifyOn> {
        Binding(
            get: { notifyOn },
            set: { newValue in
                notifyOn = newValue
                Task { await model.setNotifySetting(newValue, podcastID: podcast.id) }
            }
        )
    }

    private var autoDownloadBinding: Binding<Bool> {
        Binding(
            get: { autoDownload },
            set: { newValue in
                autoDownload = newValue
                Task {
                    try? await model.podcasts.setAutoDownload(newValue, podcastID: podcast.id)
                    await model.reloadLibrary()
                }
            }
        )
    }

    private func limitLabel(_ choice: Int?) -> String {
        guard let choice else { return "All episodes" }
        return choice == 1 ? "1 newest episode" : "\(choice) newest episodes"
    }
}
