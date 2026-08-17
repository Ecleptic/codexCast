import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Playlists as one compact row of chips — capsule per playlist, like the
/// filter chips in Apple Music. Long-press for rename/delete; "+" creates.
struct PlaylistStrip: View {
    @Environment(AppModel.self) private var model
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlists")
                .font(.title3.bold())
                .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.playlists, id: \.id) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistChip(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !playlist.isBuiltIn {
                                Button {
                                    renaming = playlist
                                    renameText = playlist.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await model.deletePlaylist(playlist) }
                                } label: {
                                    Label("Delete Playlist", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        showNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New playlist")
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") {
                Task { await model.createPlaylist(named: newName); newName = "" }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let playlist = renaming {
                    Task { await model.renamePlaylist(playlist, to: renameText) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct PlaylistChip: View {
    let playlist: Playlist

    private var tint: Color {
        switch playlist.colorName {
        case "orange": .orange
        case "yellow": .yellow
        case "blue": .blue
        case "brown": .brown
        default: .indigo
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: playlist.iconName ?? "list.bullet")
                .font(.caption.weight(.semibold))
            Text(playlist.name)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// The episodes inside one playlist, across shows.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    @State private var episodes: [EpisodeRecord] = []
    @State private var showAddEpisodes = false
    @State private var showManageShows = false

    var body: some View {
        List {
            ForEach(episodes, id: \.id) { episode in
                Button {
                    model.play(episode)
                } label: {
                    HStack(spacing: 12) {
                        // The show's artwork — a playlist mixes shows, and
                        // titles alone don't say which is which.
                        AsyncImage(url: artworkURL(for: episode)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(episode.title).font(.headline).lineLimit(2)
                            HStack(spacing: 4) {
                                if episode.localPath != nil {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                                if let show = showTitle(for: episode) {
                                    Text(show).lineLimit(1)
                                }
                                if let published = episode.publishedAt {
                                    Text("· ").foregroundStyle(.tertiary)
                                        + Text(published, style: .date)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .onMove { indices, destination in
                // Only hand-curated lists are reorderable; a rules-based list
                // is a live query and has no manual order to rewrite.
                guard playlist.decodedRules == nil else { return }
                episodes.move(fromOffsets: indices, toOffset: destination)
                Task {
                    await model.reorderPlaylist(playlist.id, episodeIDs: episodes.map(\.id))
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !playlist.isBuiltIn || playlist.decodedRules == nil {
                Menu {
                    if !playlist.isBuiltIn {
                        Button {
                            showManageShows = true
                        } label: {
                            Label("Manage Shows…", systemImage: "square.stack")
                        }
                    }
                    Button {
                        showAddEpisodes = true
                    } label: {
                        Label("Add Episodes…", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                EditButton()
            }
        }
        .sheet(isPresented: $showManageShows) {
            ManageShowsSheet(playlist: playlist) {
                Task { episodes = await model.episodes(in: playlist) }
            }
        }
        .sheet(isPresented: $showAddEpisodes) {
            AddEpisodesSheet(playlist: playlist) {
                Task { episodes = await model.episodes(in: playlist) }
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "list.bullet",
                    description: Text("Episodes matching this playlist will appear here.")
                )
            }
        }
        .task {
            episodes = await model.episodes(in: playlist)
        }
    }

    private func artworkURL(for episode: EpisodeRecord) -> URL? {
        model.library.first { $0.id == episode.podcastId }?
            .imageURL.flatMap(URL.init(string:))
    }

    private func showTitle(for episode: EpisodeRecord) -> String? {
        model.library.first { $0.id == episode.podcastId }?.title
    }
}

/// Picker for adding episodes to a hand-curated playlist: recent episodes
/// across every show, searchable, tap to add.
private struct AddEpisodesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    var onDone: () -> Void

    @State private var candidates: [EpisodeRecord] = []
    @State private var added: Set<Episode.ID> = []
    @State private var searchText = ""

    private var visible: [EpisodeRecord] {
        guard !searchText.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(visible, id: \.id) { episode in
                Button {
                    Task {
                        await model.add(episode, to: playlist)
                        added.insert(episode.id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: model.library.first(where: { $0.id == episode.podcastId })?
                            .imageURL.flatMap(URL.init(string:))) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title).font(.subheadline).lineLimit(2)
                            if let show = model.library.first(where: { $0.id == episode.podcastId })?.title {
                                Text(show).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: added.contains(episode.id) ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .disabled(added.contains(episode.id))
            }
            .searchable(text: $searchText, prompt: "Search episodes")
            .navigationTitle("Add to \(playlist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    onDone()
                    dismiss()
                }
            }
            .task {
                var all: [EpisodeRecord] = []
                for podcast in model.library {
                    all += (try? await model.episodes.episodes(podcastID: podcast.id, limit: 15)) ?? []
                }
                candidates = all.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            }
        }
    }
}

/// Category membership: pick whole shows whose new episodes flow into this
/// playlist automatically — "Daily always has my daily podcasts".
private struct ManageShowsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    var onDone: () -> Void

    @State private var selected: Set<Podcast.ID> = []

    var body: some View {
        NavigationStack {
            List(model.library, id: \.id) { podcast in
                Button {
                    if selected.contains(podcast.id) {
                        selected.remove(podcast.id)
                    } else {
                        selected.insert(podcast.id)
                    }
                } label: {
                    HStack {
                        Text(podcast.title).lineLimit(1)
                        Spacer()
                        if selected.contains(podcast.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Shows in \(playlist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await model.playlistRepository.setIncludedShows(
                                Array(selected), playlistID: playlist.id
                            )
                            await model.reloadLibrary()
                            onDone()
                            dismiss()
                        }
                    }
                }
            }
            .task {
                selected = Set(
                    (try? await model.playlistRepository.includedShows(playlistID: playlist.id)) ?? []
                )
            }
        }
    }
}
