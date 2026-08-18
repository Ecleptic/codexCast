import CarPlay
import CodexCastCore
import CodexCastPersistence
import UIKit

/// CarPlay: a driving-safe way into the same library and the same player.
///
/// Deliberately shallow — three tabs, one level of drilling, then Now
/// Playing. Everything plays through `AppModel`, so ad skipping, Smart
/// Speed, position saving, and the queue behave exactly as they do on the
/// phone.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    /// CarPlay lists are capped by the system and long lists are unsafe to
    /// read while driving; the most relevant handful is the whole point.
    private static let listLimit = 24

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor in
            let root = await makeRootTemplate()
            interfaceController.setRootTemplate(root, animated: false, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    @MainActor
    private func makeRootTemplate() async -> CPTemplate {
        let continuing = CPListTemplate(
            title: "Continue", sections: [await continueSection()]
        )
        continuing.tabTitle = "Continue"
        continuing.tabImage = UIImage(systemName: "play.circle")

        let shows = CPListTemplate(title: "Shows", sections: [showsSection()])
        shows.tabTitle = "Shows"
        shows.tabImage = UIImage(systemName: "square.grid.2x2")

        let queue = CPListTemplate(title: "Up Next", sections: [await queueSection()])
        queue.tabTitle = "Up Next"
        queue.tabImage = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")

        return CPTabBarTemplate(templates: [continuing, shows, queue])
    }

    @MainActor
    private func continueSection() async -> CPListSection {
        guard let model = AppModel.shared else { return CPListSection(items: []) }
        let episodes = (try? await model.episodes.inProgress(limit: Self.listLimit)) ?? []
        return CPListSection(items: episodes.map { episodeItem($0, model: model) })
    }

    @MainActor
    private func queueSection() async -> CPListSection {
        guard let model = AppModel.shared,
              let queue = model.playlists.first(where: { $0.name == Playlist.upNextName })
        else { return CPListSection(items: []) }
        let episodes = await model.episodes(in: queue).prefix(Self.listLimit)
        return CPListSection(items: episodes.map { episodeItem($0, model: model) })
    }

    @MainActor
    private func showsSection() -> CPListSection {
        guard let model = AppModel.shared else { return CPListSection(items: []) }
        // Followed shows only: the browsing library is not a driving surface.
        let shows = model.library.filter(\.isFollowed).prefix(Self.listLimit)
        let items = shows.map { podcast -> CPListItem in
            let item = CPListItem(text: podcast.title, detailText: podcast.author)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.pushEpisodes(for: podcast)
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }

    @MainActor
    private func pushEpisodes(for podcast: PodcastRecord) async {
        guard let model = AppModel.shared else { return }
        let episodes = (try? await model.episodes.episodes(
            podcastID: podcast.id, limit: Self.listLimit
        )) ?? []
        let template = CPListTemplate(
            title: podcast.title,
            sections: [CPListSection(items: episodes.map { episodeItem($0, model: model) })]
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// One tappable episode. Tapping plays it and shows Now Playing — the
    /// shortest possible path, which is the only safe one in a car.
    @MainActor
    private func episodeItem(_ episode: EpisodeRecord, model: AppModel) -> CPListItem {
        let item = CPListItem(text: episode.title, detailText: detail(for: episode, model: model))
        item.isPlaying = model.nowPlaying?.id == episode.id
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                model.play(episode)
                self?.interfaceController?.pushTemplate(
                    CPNowPlayingTemplate.shared, animated: true, completion: nil
                )
                completion()
            }
        }
        return item
    }

    @MainActor
    private func detail(for episode: EpisodeRecord, model: AppModel) -> String {
        var parts: [String] = []
        if let show = model.library.first(where: { $0.id == episode.podcastId })?.title {
            parts.append(show)
        }
        if let duration = episode.durationMs {
            let remaining = max(0, duration - episode.playbackPositionMs) / 60_000
            parts.append(episode.playbackPositionMs > 15_000 ? "\(remaining) min left" : "\(duration / 60_000) min")
        }
        return parts.joined(separator: " · ")
    }
}
