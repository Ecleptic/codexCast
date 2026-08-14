import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Per-show storage usage with bulk delete (§12). Deleting removes media
/// only — transcripts and learned data always survive (A5.3).
struct StorageView: View {
    @Environment(AppModel.self) private var model

    @State private var usage: [(podcast: PodcastRecord, bytes: Int64)] = []

    private var totalBytes: Int64 { usage.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            Section {
                LabeledContent("Total downloads") {
                    Text(ByteCountFormatStyle().format(totalBytes))
                        .font(.headline)
                }
            }

            Section {
                ForEach(usage, id: \.podcast.id) { entry in
                    HStack {
                        Text(entry.podcast.title).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatStyle().format(entry.bytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await deleteDownloads(for: entry.podcast) }
                        } label: {
                            Label("Delete Downloads", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Swipe to delete a show's downloads. Transcripts and everything Codex Cast has learned are always kept.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func reload() async {
        var rows: [(PodcastRecord, Int64)] = []
        for podcast in model.library {
            let bytes = (try? await model.retention.downloadedByteCount(podcastID: podcast.id)) ?? 0
            if bytes > 0 { rows.append((podcast, bytes)) }
        }
        usage = rows.sorted { $0.1 > $1.1 }
    }

    private func deleteDownloads(for podcast: PodcastRecord) async {
        let episodes = (try? await model.episodes.episodes(podcastID: podcast.id, limit: 500)) ?? []
        var evicted: [Episode.ID] = []
        for episode in episodes {
            guard let path = episode.localPath,
                  episode.id != model.nowPlaying?.id
            else { continue }
            try? FileManager.default.removeItem(atPath: path)
            evicted.append(episode.id)
        }
        try? await model.retention.markEvicted(evicted)
        await reload()
    }
}
