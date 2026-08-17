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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !inProgress.isEmpty {
                        shelf("Continue Listening") {
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
                        }
                    }

                    if !upNext.isEmpty {
                        shelf("Up Next") {
                            VStack(spacing: 0) {
                                ForEach(upNext.prefix(3), id: \.id) { episode in
                                    HomeEpisodeRow(episode: episode) { router.homePath.append($0) }
                                    Divider().padding(.leading, 74)
                                }
                                if upNext.count > 3, let queue = queuePlaylist {
                                    NavigationLink("See all \(upNext.count)") {
                                        PlaylistDetailView(playlist: queue)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }

                    if !model.playlists.isEmpty {
                        PlaylistStrip()
                    }

                    shelf("New Releases") {
                        if newReleases.isEmpty {
                            ContentUnavailableView(
                                "Nothing New",
                                systemImage: "sparkles",
                                description: Text("New episodes from your shows appear here.")
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach(newReleases, id: \.id) { episode in
                                    HomeEpisodeRow(episode: episode) { router.homePath.append($0) }
                                        // One gesture, two stages: a short
                                        // pull queues, keep pulling and it
                                        // turns red to dismiss (mark played).
                                        .modifier(TwoStageSwipe(
                                            queueAction: {
                                                Task {
                                                    await model.addToUpNext(episode)
                                                    await reload()
                                                }
                                            },
                                            removeAction: {
                                                Task {
                                                    await model.togglePlayed(episode)
                                                    await reload()
                                                }
                                            }
                                        ))
                                    Divider().padding(.leading, 74)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
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
                for podcast in model.library { await model.refresh(podcast) }
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

    private func shelf(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)
            content()
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
    /// Pushes a show onto the owning stack — "Go to Show" from any row.
    var onGoToShow: ((Podcast.ID) -> Void)? = nil

    var body: some View {
        NavigationLink {
            EpisodeDetailView(episode: episode)
        } label: {
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

                Spacer()

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
        }
        .buttonStyle(.plain)
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

/// Mail-style two-stage trailing swipe for rows living in a ScrollView
/// (where List swipe actions don't exist): a short pull reveals the queue
/// action in blue; pulling past the second threshold turns it red and
/// releasing dismisses instead.
struct TwoStageSwipe: ViewModifier {
    var queueAction: () -> Void
    var removeAction: () -> Void

    @GestureState private var drag: CGFloat = 0

    private let queueThreshold: CGFloat = 60
    private let removeThreshold: CGFloat = 170

    func body(content: Content) -> some View {
        let engaged = max(0, -drag)
        content
            .offset(x: min(0, drag))
            .background(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    Rectangle()
                        .fill(engaged >= removeThreshold ? Color.red : Color.blue)
                    Label(
                        engaged >= removeThreshold ? "Dismiss" : "Up Next",
                        systemImage: engaged >= removeThreshold
                            ? "xmark.bin.fill"
                            : "text.line.first.and.arrowtriangle.forward"
                    )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .padding(.trailing, 20)
                }
                .opacity(engaged > 8 ? 1 : 0)
            }
            .clipped()
            // simultaneousGesture, not .gesture: a plain gesture on a row
            // inside a ScrollView loses the touch to the scroll pan and
            // never fires — the swipe read as dead.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in
                        // Horizontal intent only; the shelf scrolls vertically.
                        if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                            state = value.translation.width
                        }
                    }
                    .onEnded { value in
                        let final = max(0, -value.translation.width)
                        if final >= removeThreshold {
                            removeAction()
                        } else if final >= queueThreshold {
                            queueAction()
                        }
                    }
            )
            .animation(.snappy(duration: 0.25), value: drag == 0)
            .sensoryFeedback(.impact(weight: .medium), trigger: engaged >= removeThreshold)
    }
}
