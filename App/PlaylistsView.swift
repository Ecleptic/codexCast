import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The playlist strip on the Library screen (A5.2).
struct PlaylistStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlists")
                .font(.title3.bold())
                .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(model.playlists, id: \.id) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistBubble(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct PlaylistBubble: View {
    let playlist: Playlist

    private var tint: Color {
        switch playlist.colorName {
        case "orange": .orange
        case "yellow": .yellow
        case "blue": .blue
        case "brown": .brown
        default: .gray
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(tint.opacity(0.25))
                .frame(width: 68, height: 68)
                .overlay {
                    Image(systemName: playlist.iconName ?? "list.bullet")
                        .font(.title2)
                        .foregroundStyle(tint)
                }
            Text(playlist.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 84)
        }
    }
}

/// The episodes inside one playlist, across shows.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    @State private var episodes: [EpisodeRecord] = []

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
                EditButton()
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
