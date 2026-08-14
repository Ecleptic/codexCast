import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct EpisodeListView: View {
    @Environment(AppModel.self) private var model
    let podcast: PodcastRecord

    @State private var episodes: [EpisodeRecord] = []

    var body: some View {
        List(episodes, id: \.id) { episode in
            NavigationLink {
                EpisodeDetailView(episode: episode)
            } label: {
                EpisodeRow(episode: episode, isPlaying: model.nowPlaying?.id == episode.id)
            }
            .swipeActions(edge: .leading) {
                Button {
                    model.play(episode)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(.accentColor)
                Button {
                    Task {
                        await model.togglePlayed(episode)
                        episodes = (try? await model.episodes.episodes(podcastID: podcast.id)) ?? []
                    }
                } label: {
                    Label(
                        episode.isPlayed ? "Unplayed" : "Played",
                        systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
                    )
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await model.playNext(episode) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.indigo)
                Button {
                    Task { await model.addToUpNext(episode) }
                } label: {
                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            NavigationLink {
                ShowSettingsView(podcast: podcast)
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "waveform",
                    description: Text("Pull the Library to refresh this show's feed.")
                )
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

    /// Fraction listened, for the row's progress bar.
    private var progress: Double? {
        guard episode.playbackPositionMs > 15_000,
              let duration = episode.durationMs, duration > 0,
              !episode.isPlayed
        else { return nil }
        return min(1, Double(episode.playbackPositionMs) / Double(duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                }
                if episode.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                if let published = episode.publishedAt {
                    Text(published, format: .relative(presentation: .named))
                }
                if let duration = episode.durationMs {
                    if let progress {
                        // Remaining, not total, once started — what every
                        // player shows because it is what you actually want.
                        Text("\(max(0, duration - episode.playbackPositionMs) / 60_000) min left")
                    } else {
                        Text(Duration.milliseconds(duration), format: .units(allowed: [.hours, .minutes], width: .narrow))
                    }
                }
                if episode.localPath != nil {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: progress)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.6)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
