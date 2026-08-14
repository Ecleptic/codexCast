import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct EpisodeListView: View {
    @Environment(AppModel.self) private var model
    let podcast: PodcastRecord

    @State private var episodes: [EpisodeRecord] = []

    var body: some View {
        List(episodes, id: \.id) { episode in
            Button {
                model.play(episode)
            } label: {
                EpisodeRow(episode: episode, isPlaying: model.nowPlaying?.id == episode.id)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "waveform",
                    description: Text("Pull the Library to refresh this show's feed.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.nowPlaying != nil {
                MiniPlayerView()
            }
        }
        .task {
            episodes = (try? await model.episodes.episodes(podcastID: podcast.id)) ?? []
        }
    }
}

private struct EpisodeRow: View {
    let episode: EpisodeRecord
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                }
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let published = episode.publishedAt {
                    Text(published, style: .date)
                }
                if let duration = episode.durationMs {
                    Text(Duration.milliseconds(duration), format: .units(allowed: [.hours, .minutes], width: .narrow))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
