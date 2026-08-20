import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The long-press menu every episode surface shares. One definition, so Home,
/// show pages, playlists, and search all offer the same verbs.
struct EpisodeContextMenu: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord
    /// Called after an action that changes the row (played, deleted…).
    var onChange: () -> Void = {}
    /// Navigation hooks: provided by screens that own a navigation path, so
    /// "where can this take me" is answered from every episode surface.
    var onGoToEpisode: (() -> Void)? = nil
    var onGoToShow: (() -> Void)? = nil

    var body: some View {
        Button {
            model.play(episode)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        if let onGoToEpisode {
            Button {
                onGoToEpisode()
            } label: {
                Label("Episode Details", systemImage: "doc.text.magnifyingglass")
            }
        }

        if let onGoToShow {
            Button {
                onGoToShow()
            } label: {
                Label("Go to Show", systemImage: "square.stack")
            }
        }

        Button {
            Task { await model.playNext(episode); onChange() }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task { await model.addToUpNext(episode); onChange() }
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        AddToPlaylistMenu(episode: episode)

        Divider()

        if !model.isDownloaded(episode) {
            Button {
                Task { _ = try? await model.downloadAudio(for: episode); onChange() }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Button {
            Task { await model.transcribeOnDevice(episode); onChange() }
        } label: {
            Label("Transcribe", systemImage: "waveform")
        }

        Button {
            Task { await model.scanForAds(episode); onChange() }
        } label: {
            Label("Scan for Ads", systemImage: "sparkle.magnifyingglass")
        }

        Divider()

        Button {
            Task { await model.togglePlayed(episode); onChange() }
        } label: {
            Label(
                episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
            )
        }

        if model.isDownloaded(episode) {
            Button(role: .destructive) {
                Task { await model.deleteDownload(episode); onChange() }
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        }

        Button(role: .destructive) {
            Task { await model.deleteTranscript(episode); onChange() }
        } label: {
            Label("Delete Transcript & Segments", systemImage: "text.badge.minus")
        }
    }
}

/// "Add to Playlist ▸" — user playlists plus a create flow.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    var body: some View {
        Menu {
            ForEach(model.playlists.filter { !$0.isBuiltIn }, id: \.id) { playlist in
                Button(playlist.name) {
                    Task { await model.add(episode, to: playlist) }
                }
            }
            if model.playlists.filter({ !$0.isBuiltIn }).isEmpty {
                Text("No playlists yet")
            }
        } label: {
            Label("Add to Playlist", systemImage: "music.note.list")
        }
    }
}

/// The long-press menu for a show tile.
struct PodcastContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let podcast: PodcastRecord

    var body: some View {
        Button {
            router.openShow(podcast.id)
        } label: {
            Label("Show Details", systemImage: "info.circle")
        }

        Button {
            Task {
                try? await model.podcasts.setPinned(!podcast.isPinned, podcastID: podcast.id)
                await model.reloadLibrary()
            }
        } label: {
            Label(
                podcast.isPinned ? "Unpin" : "Pin to Top",
                systemImage: podcast.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            Task {
                try? await model.podcasts.setFollowed(!podcast.isFollowed, podcastID: podcast.id)
                await model.reloadLibrary()
            }
        } label: {
            Label(
                podcast.isFollowed ? "Unfollow" : "Follow",
                systemImage: podcast.isFollowed ? "bell.slash" : "bell"
            )
        }

        Button {
            Task {
                if let latest = (try? await model.episodes.episodes(podcastID: podcast.id, limit: 1))?.first {
                    model.play(latest)
                }
            }
        } label: {
            Label("Play Latest", systemImage: "play.fill")
        }

        Button {
            Task {
                await model.refresh(podcast)
                await model.reloadLibrary()
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }

        Button {
            Task {
                let enabled = !podcast.autoDownloadEnabled
                try? await model.podcasts.setAutoDownload(enabled, podcastID: podcast.id)
                await model.reloadLibrary()
            }
        } label: {
            Label(
                podcast.autoDownloadEnabled ? "Auto-Download: On" : "Auto-Download: Off",
                systemImage: podcast.autoDownloadEnabled ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }

        Divider()

        Button(role: .destructive) {
            Task {
                try? await model.podcasts.unsubscribe(podcastID: podcast.id)
                await model.reloadLibrary()
            }
        } label: {
            Label("Unsubscribe", systemImage: "minus.circle")
        }
    }
}
