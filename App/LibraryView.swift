import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !model.playlists.isEmpty {
                        PlaylistStrip()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Podcasts")
                            .font(.title3.bold())
                            .padding(.horizontal)

                        if model.library.isEmpty {
                            ContentUnavailableView(
                                "No Subscriptions",
                                systemImage: "square.stack",
                                description: Text("Find shows in Discover, or add a feed by URL.")
                            )
                            .padding(.top, 40)
                        } else {
                            ForEach(model.library, id: \.id) { podcast in
                                NavigationLink(value: podcast.id) {
                                    PodcastRow(podcast: podcast)
                                        .padding(.horizontal)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 84)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Library")
            .navigationDestination(for: Podcast.ID.self) { id in
                if let podcast = model.library.first(where: { $0.id == id }) {
                    EpisodeListView(podcast: podcast)
                }
            }
            .navigationDestination(for: Playlist.ID.self) { id in
                if let playlist = model.playlists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlist: playlist)
                }
            }
            .refreshable {
                for podcast in model.library {
                    await model.refresh(podcast)
                }
                await model.reloadLibrary()
                await model.enforceRetention()
            }
            .safeAreaInset(edge: .bottom) {
                if model.nowPlaying != nil {
                    MiniPlayerView()
                }
            }
        }
        .task {
            await model.reloadLibrary()
        }
    }
}

private struct PodcastRow: View {
    let podcast: PodcastRecord

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = podcast.author {
                    Text(author.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let error = podcast.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
