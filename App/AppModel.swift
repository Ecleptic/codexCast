import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import CodexCastPipeline
import CodexCastPlayback
import Foundation
import Observation

/// Composition root: owns the database, repositories, and playback engine.
/// MV(VM-lite) per §3 — views observe this and the playback engine directly;
/// there is no coordinator layer to invent.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let podcasts: PodcastRepository
    let episodes: EpisodeRepository
    let transcripts: TranscriptRepository
    let fetcher: FeedFetcher
    let search: ITunesSearchClient
    let player: PlaybackEngine

    private(set) var library: [PodcastRecord] = []
    private(set) var refreshError: String?

    init() throws {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        database = try AppDatabase.open(
            at: support.appendingPathComponent("CodexCast/codexcast.sqlite")
        )
        podcasts = PodcastRepository(database: database)
        episodes = EpisodeRepository(database: database)
        transcripts = TranscriptRepository(database: database)
        fetcher = FeedFetcher()
        search = ITunesSearchClient()
        player = PlaybackEngine()
    }

    // MARK: - Library

    func reloadLibrary() async {
        library = (try? await podcasts.all()) ?? []
    }

    /// Subscribes to a feed URL: fetch, parse, store the show and episodes.
    func subscribe(feedURL: URL, itunesCollectionID: Int? = nil) async throws {
        let result = try await fetcher.fetch(feedURL)
        guard case .updated(let feed, let validators) = result else { return }

        let record = try await podcasts.subscribe(
            feedURL: feedURL,
            title: feed.title,
            author: feed.author,
            summary: feed.summary,
            imageURL: feed.imageURL,
            itunesCollectionID: itunesCollectionID
        )
        try await storeEpisodes(feed, podcastID: record.id)
        try await podcasts.updateCacheValidators(
            podcastID: record.id,
            etag: validators.etag,
            lastModified: validators.lastModified
        )
        await reloadLibrary()
    }

    /// Refreshes one show, using conditional GET so an unchanged feed is a
    /// single cheap round trip.
    func refresh(_ podcast: PodcastRecord) async {
        guard let url = URL(string: podcast.feedURL) else { return }
        do {
            let validators = HTTPCacheValidators(etag: podcast.etag, lastModified: podcast.lastModified)
            switch try await fetcher.fetch(url, validators: validators) {
            case .notModified:
                break
            case .updated(let feed, let fresh):
                try await storeEpisodes(feed, podcastID: podcast.id)
                try await podcasts.updateCacheValidators(
                    podcastID: podcast.id, etag: fresh.etag, lastModified: fresh.lastModified
                )
            }
        } catch {
            // A broken feed must not take the library down (§8.2).
            try? await podcasts.recordError(podcastID: podcast.id, description: "\(error)")
            refreshError = "\(podcast.title): \(error.localizedDescription)"
        }
    }

    private func storeEpisodes(_ feed: ParsedFeed, podcastID: Podcast.ID) async throws {
        let encoder = JSONEncoder()
        let inputs = feed.episodes.map { episode in
            ParsedEpisodeInput(
                guid: episode.guid,
                title: episode.title,
                summary: episode.summary,
                publishedAt: episode.publishedAt,
                durationMs: episode.declaredDurationMs,
                imageURL: episode.imageURL?.absoluteString,
                episodeNumber: episode.episodeNumber,
                seasonNumber: episode.seasonNumber,
                renditionsJSON: (try? encoder.encode(episode.renditions))
                    .flatMap { String(data: $0, encoding: .utf8) },
                feedTranscriptsJSON: (try? encoder.encode(episode.transcripts))
                    .flatMap { String(data: $0, encoding: .utf8) },
                feedChaptersURL: episode.chaptersURL?.absoluteString
            )
        }
        try await episodes.upsert(inputs, podcastID: podcastID)
    }

    // MARK: - Playback

    private(set) var nowPlaying: EpisodeRecord?

    /// Streams an episode's primary audio. Download-first arrives with the
    /// pipeline UI; streaming makes the player usable immediately.
    func play(_ episode: EpisodeRecord) {
        guard let renditionData = episode.renditions?.data(using: .utf8),
              let renditions = try? JSONDecoder().decode([Rendition].self, from: renditionData),
              let url = renditions.first(where: \.isPrimaryEnclosure)?.sources.first
                ?? renditions.first?.sources.first
        else { return }

        // No detected segments yet, so the timeline is the identity mapping —
        // exactly why DisplayTimeline was built before skipping existed.
        let timeline = DisplayTimeline(mediaDurationMs: episode.durationMs ?? 0)
        player.load(url: url, timeline: timeline, startAtMs: episode.playbackPositionMs)
        player.play()
        nowPlaying = episode
    }
}
