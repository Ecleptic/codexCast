import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Playlists as native list rows (Apple Library style): tinted icon in a
/// rounded square, name, chevron. Creation is an explicit row; rename and
/// delete live on long-press.
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

            VStack(spacing: 0) {
                ForEach(model.playlists, id: \.id) { playlist in
                    NavigationLink(value: playlist.id) {
                        PlaylistRow(playlist: playlist)
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
                    Divider().padding(.leading, 62)
                }

                Button {
                    showNewPlaylist = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                        Text("New Playlist…")
                            .foregroundStyle(.tint)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
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

private struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
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
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.gradient)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: playlist.iconName ?? "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

            Text(playlist.name)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The episodes inside one playlist, across shows.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    @State private var episodes: [EpisodeRecord] = []
    @State private var showAddEpisodes = false

    var body: some View {
        List {
            ForEach(episodes, id: \.id) { episode in
                Button {
                    model.play(episode)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title).font(.headline).lineLimit(2)
                        if let published = episode.publishedAt {
                            Text(published, style: .date)
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
            if playlist.decodedRules == nil {
                Button("Add", systemImage: "plus") {
                    showAddEpisodes = true
                }
                EditButton()
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
                    HStack {
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
