import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct EpisodeListView: View {
    @Environment(AppModel.self) private var model
    let podcast: PodcastRecord

    @State private var episodes: [EpisodeRecord] = []
    @State private var descriptionExpanded = false

    var body: some View {
        List {
            showHeader
            ForEach(episodes, id: \.id) { episode in
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
            .contextMenu {
                EpisodeContextMenu(episode: episode) {
                    Task { episodes = (try? await model.episodes.episodes(podcastID: podcast.id)) ?? [] }
                }
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
        }
        .listStyle(.plain)
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

    /// Hero header (ux invariant 5): artwork, author, description — the show's
    /// identity, not just its rows.
    @ViewBuilder
    private var showHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                }
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 5) {
                    Text(podcast.title).font(.title3.bold())
                    if let author = podcast.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        let unplayed = episodes.filter { !$0.isPlayed }.count
                        Text("\(episodes.count) episodes")
                        if unplayed > 0 { Text("· \(unplayed) unplayed") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let summary = podcast.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .onTapGesture {
                        withAnimation { descriptionExpanded.toggle() }
                    }
                if !descriptionExpanded {
                    Button("more") {
                        withAnimation { descriptionExpanded = true }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if let latest = episodes.first(where: { !$0.isPlayed }) ?? episodes.first {
                Button {
                    model.play(latest)
                } label: {
                    Label(
                        latest.playbackPositionMs > 15_000 ? "Resume Latest" : "Play Latest",
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
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
