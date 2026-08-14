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
            storageBytes = try? await model.retention.downloadedByteCount(podcastID: podcast.id)
        }
    }

    private func limitLabel(_ choice: Int?) -> String {
        guard let choice else { return "All episodes" }
        return choice == 1 ? "1 newest episode" : "\(choice) newest episodes"
    }
}
