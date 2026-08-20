import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct EpisodeListView: View {
    @Environment(AppModel.self) private var model
    let podcast: PodcastRecord

    @State private var episodes: [EpisodeRecord] = []
    @State private var descriptionExpanded = false
    @State private var searchText = ""
    @State private var selection = Set<Episode.ID>()
    @Environment(\.editMode) private var editMode

    private var isSelecting: Bool { editMode?.wrappedValue.isEditing == true }

    private var selectedEpisodes: [EpisodeRecord] {
        episodes.filter { selection.contains($0.id) }
    }

    private var visibleEpisodes: [EpisodeRecord] {
        guard !searchText.isEmpty else { return episodes }
        return episodes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(selection: $selection) {
            showHeader
            ForEach(visibleEpisodes, id: \.id) { episode in
            NavigationLink {
                EpisodeDetailView(episode: episode)
            } label: {
                EpisodeRow(episode: episode)
            }
            .tag(episode.id)
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
        .searchable(text: $searchText, prompt: "Search episodes")
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Bulk verbs: whole-show sweeps from the menu, or select
            // specific episodes with Edit and act on just those.
            Menu {
                if isSelecting {
                    Button {
                        if selection.count == visibleEpisodes.count {
                            selection.removeAll()
                        } else {
                            selection = Set(visibleEpisodes.map(\.id))
                        }
                    } label: {
                        Label(
                            selection.count == visibleEpisodes.count ? "Deselect All" : "Select All",
                            systemImage: "checklist"
                        )
                    }
                    bulkActions(on: selectedEpisodes, label: "\(selection.count) Selected")
                } else {
                    bulkActions(on: episodes, label: "All Episodes")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            EditButton()
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

    @ViewBuilder
    private func bulkActions(on targets: [EpisodeRecord], label: String) -> some View {
        Section(label) {
            Button {
                bulk(targets) { episode in
                    if !episode.isPlayed { await model.togglePlayed(episode) }
                }
            } label: {
                Label("Mark Played", systemImage: "checkmark.circle")
            }
            Button {
                bulk(targets) { episode in
                    if episode.isPlayed { await model.togglePlayed(episode) }
                }
            } label: {
                Label("Mark Unplayed", systemImage: "circle")
            }
            Button {
                bulk(targets) { episode in
                    _ = try? await model.downloadAudio(for: episode)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) {
                bulk(targets) { episode in
                    await model.deleteDownload(episode)
                }
            } label: {
                Label("Delete Downloads", systemImage: "trash")
            }
        }
    }

    private func bulk(_ targets: [EpisodeRecord], _ action: @escaping (EpisodeRecord) async -> Void) {
        Task {
            for episode in targets {
                await action(episode)
            }
            episodes = (try? await model.episodes.episodes(podcastID: podcast.id)) ?? []
            selection.removeAll()
            editMode?.wrappedValue = .inactive
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

            if let since = model.dormancy(for: podcast.id) {
                Label(
                    "No new episodes since \(since.formatted(date: .abbreviated, time: .omitted))",
                    systemImage: "zzz"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // A2: what this app has actually found on this show, at a glance.
            if let kinds = model.showBadges[podcast.id], !kinds.isEmpty {
                HStack(spacing: 6) {
                    ForEach(DetectionBadge.badges(for: kinds), id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                .accessibilityLabel("Detected: \(DetectionBadge.badges(for: kinds).joined(separator: ", "))")
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
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text(latest.playbackPositionMs > 15_000 ? "Resume Latest" : "Play Latest")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }
}

/// The show page's row.
///
/// The shared component, with no show name — you are already inside the
/// show, so repeating it in every row is noise. Everything else about the
/// row is identical to Home, playlists and the queue, which is the point.
private struct EpisodeRow: View {
    let episode: EpisodeRecord

    var body: some View {
        EpisodeRowContent(episode: episode)
    }
}
