import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The first screen: what you were listening to, what's queued, what's new
/// (ux-architecture invariant 3). Not the subscription list.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var inProgress: [EpisodeRecord] = []
    @State private var upNext: [EpisodeRecord] = []
    @State private var newReleases: [EpisodeRecord] = []

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.homePath) {
            // A native List, not a custom ScrollView of shelves: rows get
            // the system's own swipe actions, separators, and hit-testing.
            List {
                if !inProgress.isEmpty {
                    Section("Continue Listening") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(inProgress, id: \.id) { episode in
                                    ContinueCard(episode: episode)
                                        .contextMenu {
                                            EpisodeContextMenu(
                                                episode: episode,
                                                onChange: { Task { await reload() } },
                                                onGoToEpisode: { router.homePath.append(episode) },
                                                onGoToShow: { router.homePath.append(episode.podcastId) }
                                            )
                                            Button(role: .destructive) {
                                                Task {
                                                    await model.removeFromContinueListening(episode)
                                                    await reload()
                                                }
                                            } label: {
                                                Label("Remove from Continue Listening", systemImage: "xmark.circle")
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .scrollIndicators(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                if !upNext.isEmpty {
                    Section("Up Next") {
                        ForEach(upNext.prefix(3), id: \.id) { episode in
                            HomeEpisodeRow(
                                episode: episode,
                                onOpen: { router.homePath.append(episode) },
                                onGoToShow: { router.homePath.append($0) }
                            )
                            .listRowInsets(EdgeInsets())
                        }
                        if upNext.count > 3, let queue = queuePlaylist {
                            NavigationLink("See all \(upNext.count)") {
                                PlaylistDetailView(playlist: queue)
                            }
                            .font(.callout)
                        }
                    }
                }

                if !model.playlists.isEmpty {
                    Section {
                        PlaylistStrip()
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }

                Section("New Releases") {
                    if newReleases.isEmpty {
                        ContentUnavailableView(
                            "Nothing New",
                            systemImage: "sparkles",
                            description: Text("New episodes from your shows appear here.")
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(newReleases, id: \.id) { episode in
                            HomeEpisodeRow(
                                episode: episode,
                                onOpen: { router.homePath.append(episode) },
                                onGoToShow: { router.homePath.append($0) }
                            )
                            .listRowInsets(EdgeInsets())
                                // Native two-edge idiom: swipe right to
                                // queue, swipe left to dismiss. Full swipes
                                // on both.
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        Task {
                                            await model.addToUpNext(episode)
                                            await reload()
                                        }
                                    } label: {
                                        Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await model.togglePlayed(episode)
                                            await reload()
                                        }
                                    } label: {
                                        Label("Dismiss", systemImage: "xmark.bin")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .headerProminence(.increased)
            .navigationTitle("Home")
            .navigationDestination(for: Playlist.ID.self) { id in
                if let playlist = model.playlists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlist: playlist)
                }
            }
            .navigationDestination(for: Podcast.ID.self) { id in
                if let podcast = model.library.first(where: { $0.id == id }) {
                    EpisodeListView(podcast: podcast)
                }
            }
            .navigationDestination(for: EpisodeRecord.self) { episode in
                EpisodeDetailView(episode: episode)
            }
            .refreshable {
                // Followed shows first so "anything new?" answers fast; the
                // rest of the library follows.
                await model.refreshFollowedNow()
                await reload()
                for podcast in model.library where !podcast.isFollowed {
                    await model.refresh(podcast)
                }
                await reload()
            }
            .task { await reload() }
        }
    }

    private var queuePlaylist: Playlist? {
        model.playlists.first { $0.name == Playlist.upNextName }
    }

    private func reload() async {
        await model.reloadLibrary()
        inProgress = (try? await model.episodes.inProgress()) ?? []
        newReleases = (try? await model.episodes.newReleases()) ?? []
        if let queue = queuePlaylist {
            upNext = await model.episodes(in: queue)
        }
    }

}

/// Card with a progress bar — resuming is one tap.
private struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    private var fraction: Double {
        guard let duration = episode.durationMs, duration > 0 else { return 0 }
        return min(1, Double(episode.playbackPositionMs) / Double(duration))
    }

    var body: some View {
        Button {
            model.play(episode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                EpisodeArtwork(episode: episode, size: 140)

                Text(episode.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                ProgressView(value: fraction)
                    .tint(.accentColor)

                if let duration = episode.durationMs {
                    Text(remaining(duration: duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func remaining(duration: Int) -> String {
        let left = max(0, duration - episode.playbackPositionMs) / 60_000
        return left <= 1 ? "Almost done" : "\(left) min left"
    }
}

/// Standard episode row for Home shelves: artwork, state, one-tap play.
struct HomeEpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord
    /// Opens the episode's detail page — the row's own tap.
    var onOpen: () -> Void = {}
    /// Pushes a show onto the owning stack — "Go to Show" from any row.
    var onGoToShow: ((Podcast.ID) -> Void)? = nil

    var body: some View {
        // A Button row, not a NavigationLink: links draw a disclosure
        // chevron, and chevron + play control in one row reads as clutter.
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    EpisodeArtwork(episode: episode, size: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        if let published = episode.publishedAt {
                            Text(published, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(episode.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(episode.isPlayed ? .secondary : .primary)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)

            Button {
                model.play(episode)
            } label: {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contextMenu {
            EpisodeContextMenu(
                episode: episode,
                onGoToShow: onGoToShow.map { handler in { handler(episode.podcastId) } }
            )
        }
    }
}

/// Episode artwork with the show's art as fallback.
struct EpisodeArtwork: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord
    let size: CGFloat

    private var url: URL? {
        episode.imageURL.flatMap(URL.init(string:))
            ?? model.library.first { $0.id == episode.podcastId }?
                .imageURL.flatMap(URL.init(string:))
    }

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: size > 100 ? 10 : 8).fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 10 : 8))
    }
}
