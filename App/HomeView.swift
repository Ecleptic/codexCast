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
    @State private var showActivity = false

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
                                        // A Menu button, not a context menu.
                                        // Every card in this shelf lives in
                                        // ONE List row, and a row can host
                                        // exactly one context menu — so the
                                        // first card's menu was answering for
                                        // all of them (long-pressing card two
                                        // acted on card one). A Menu anchors
                                        // to its own button, so each card gets
                                        // its own, correctly.
                                        .overlay(alignment: .topTrailing) {
                                            Menu {
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
                                            } label: {
                                                Image(systemName: "ellipsis")
                                                    .font(.caption.weight(.bold))
                                                    .frame(width: 28, height: 28)
                                            }
                                            .buttonStyle(.glass)
                                            .clipShape(Circle())
                                            .padding(6)
                                            .accessibilityLabel("Actions for \(episode.title)")
                                        }
                                }
                            }
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.bottom, 4)
                        }
                        .scrollIndicators(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
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
                            .modifier(EpisodeRowMenu(
                                episode: episode,
                                artworkURL: artworkURL(for: episode),
                                showTitle: showTitle(for: episode),
                                onChange: { Task { await reload() } },
                                onGoToEpisode: { router.homePath.append(episode) },
                                onGoToShow: { router.homePath.append(episode.podcastId) }
                            ))
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
                            .modifier(EpisodeRowMenu(
                                episode: episode,
                                artworkURL: artworkURL(for: episode),
                                showTitle: showTitle(for: episode),
                                onChange: { Task { await reload() } },
                                onGoToEpisode: { router.homePath.append(episode) },
                                onGoToShow: { router.homePath.append(episode.podcastId) }
                            ))
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
            .toolbar {
                // Top left: what the phone is busy with. Top right: make it
                // check now. Both were previously buried three taps deep in
                // Settings, which is why "is it downloading?" was unanswerable
                // from the screen you actually look at.
                ToolbarItem(placement: .topBarLeading) {
                    ActivityToolbarButton(isPresented: $showActivity)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Check for New Episodes", systemImage: "arrow.clockwise") {
                        Task {
                            await model.refreshFollowedNow()
                            await reload()
                        }
                    }
                    .disabled(model.isRefreshing)
                }
            }
            .sheet(isPresented: $showActivity) {
                ActivityView().environment(router)
            }
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
                await model.refreshConcurrently(model.library.filter { !$0.isFollowed })
                await reload()
            }
            .task { await reload() }
            // An episode finishing changes Continue Listening and Up Next;
            // without this the shelf kept showing what just ended.
            .onChange(of: model.nowPlaying?.id) {
                Task { await reload() }
            }
        }
    }

    private func artworkURL(for episode: EpisodeRecord) -> URL? {
        episode.imageURL.flatMap(URL.init(string:))
            ?? model.library.first { $0.id == episode.podcastId }?
                .imageURL.flatMap(URL.init(string:))
    }

    private func showTitle(for episode: EpisodeRecord) -> String? {
        model.library.first { $0.id == episode.podcastId }?.title
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

/// The row-level context menu, with an explicit preview so the lift shows
/// the episode rather than whichever control the system picked.
private struct EpisodeRowMenu: ViewModifier {
    let episode: EpisodeRecord
    let artworkURL: URL?
    let showTitle: String?
    var onChange: () -> Void
    var onGoToEpisode: () -> Void
    var onGoToShow: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            EpisodeContextMenu(
                episode: episode,
                onChange: onChange,
                onGoToEpisode: onGoToEpisode,
                onGoToShow: onGoToShow
            )
        } preview: {
            ContinuePreview(
                artworkURL: artworkURL,
                title: episode.title,
                showTitle: showTitle
            )
        }
    }
}

/// What a long press lifts: this episode, not the shelf it sits in.
///
/// Deliberately takes PLAIN VALUES and reads no environment. A context-menu
/// preview is rendered in a detached SwiftUI host that does not inherit the
/// app's environment, so an `@Environment(AppModel.self)` read inside one
/// traps — it crashed on long press, the same failure that once killed the
/// player sheet when it lost the router.
private struct ContinuePreview: View {
    let artworkURL: URL?
    let title: String
    let showTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)
                if let showTitle {
                    Text(showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 252)
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
                EpisodeArtwork(episode: episode, size: Metrics.cardArtwork)

                Text(episode.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                ProgressView(value: fraction)
                    .tint(.accentColor)

                HStack(spacing: 5) {
                    if let duration = episode.durationMs {
                        Text(remaining(duration: duration))
                    }
                    Spacer(minLength: 0)
                    DownloadStateIcon(episode: episode)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(width: Metrics.cardArtwork)
        }
        .buttonStyle(.plain)
    }

    private func remaining(duration: Int) -> String {
        let left = max(0, duration - episode.playbackPositionMs) / 60_000
        return left <= 1 ? "Almost done" : "\(left) min left"
    }
}

/// Standard episode row for Home shelves.
///
/// A thin wrapper now: the row itself is `EpisodeRowContent`, shared with
/// playlists, the player queue and Activity, so an episode looks the same
/// wherever it is listed and gains state indicators everywhere at once.
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
        HStack(spacing: 0) {
            Button(action: onOpen) {
                EpisodeRowContent(
                    episode: episode,
                    showTitle: model.library.first { $0.id == episode.podcastId }?.title
                )
            }
            .buttonStyle(.borderless)
            .tint(.primary)

            RowPlayButton(episode: episode)
        }
        .padding(.horizontal, Metrics.gutter)
        // No .contextMenu here on purpose: attached inside the row, the
        // system picks one of these buttons as the lift source — which is
        // why long-press magnified only the play circle. The owning List
        // attaches it to the whole row instead.
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
        ShowArtwork(
            url: url,
            size: size,
            fallbackText: model.library.first { $0.id == episode.podcastId }?.title
        )
    }
}
