import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import CodexCastPipeline
import CodexCastPlayback
import CodexCastTranscription
import CryptoKit
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
    let playlistRepository: PlaylistRepository
    let retention: RetentionPolicy

    private(set) var library: [PodcastRecord] = []
    private(set) var playlists: [Playlist] = []
    private(set) var refreshError: String?
    /// Global audio settings (A5.4). Per-show overrides resolve against these.
    var audioSettings = AudioSettings()

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
        playlistRepository = PlaylistRepository(database: database)
        retention = RetentionPolicy(database: database)
    }

    // MARK: - Library

    func reloadLibrary() async {
        library = (try? await podcasts.all()) ?? []
        try? await playlistRepository.ensureBuiltIns()
        playlists = (try? await playlistRepository.all()) ?? []
    }

    // MARK: - Playlists (A5.2)

    func episodes(in playlist: Playlist) async -> [EpisodeRecord] {
        (try? await playlistRepository.episodes(in: playlist)) ?? []
    }

    func reorderPlaylist(_ id: Playlist.ID, episodeIDs: [Episode.ID]) async {
        try? await playlistRepository.reorder(playlistID: id, episodeIDs: episodeIDs)
    }

    func addToUpNext(_ episode: EpisodeRecord) async {
        guard let queue = playlists.first(where: { $0.name == Playlist.upNextName }) else { return }
        try? await playlistRepository.append(episodeID: episode.id, to: queue.id)
    }

    // MARK: - Retention (A5.3)

    func setEpisodeLimit(_ limit: Int?, for podcastID: Podcast.ID) async {
        try? await retention.setLimit(limit, podcastID: podcastID)
        await reloadLibrary()
    }

    /// Applies every show's retention limit, deleting media only.
    func enforceRetention() async {
        for podcast in library {
            guard let evictions = try? await retention.evictions(
                podcastID: podcast.id,
                nowPlayingEpisodeID: nowPlaying?.id
            ) else { continue }

            for eviction in evictions {
                try? FileManager.default.removeItem(atPath: eviction.localPath)
            }
            try? await retention.markEvicted(evictions.map(\.episodeID))
        }
    }

    // MARK: - OPML (A5.1)

    func exportOPML() -> String {
        OPML.export(
            library.compactMap { podcast in
                URL(string: podcast.feedURL).map { OPMLEntry(title: podcast.title, feedURL: $0) }
            }
        )
    }

    /// Subscribes to everything in an OPML file, skipping what fails so one
    /// broken feed cannot abort the whole import.
    func importOPML(_ entries: [OPMLEntry]) async -> Int {
        var added = 0
        for entry in entries {
            do {
                try await subscribe(feedURL: entry.feedURL)
                added += 1
            } catch {
                continue
            }
        }
        await reloadLibrary()
        return added
    }

    // MARK: - Transcripts

    /// Fetches a feed-supplied transcript and stores it, so it is fetched once
    /// and never re-derived (§8.2, §9.9).
    ///
    /// Trust caveat from addendum A1: a feed transcript made from an ad-free
    /// master drifts against audio containing inserted ads. Verification lands
    /// with the detection pipeline; until then the source is recorded so a
    /// desynced transcript can be identified and replaced later.
    func loadFeedTranscript(for episode: EpisodeRecord) async throws -> TimedTranscript? {
        guard let json = episode.feedTranscripts?.data(using: .utf8),
              let references = try? JSONDecoder().decode([FeedTranscriptReference].self, from: json),
              let best = references.preferred
        else { return nil }

        let transcript = try await fetcher.fetchTranscript(best)
        try await transcripts.save(transcript, episodeID: episode.id)
        return transcript
    }

    // MARK: - Download and on-device transcription

    enum EpisodeWork: Equatable {
        case downloading(fraction: Double?)
        case preparingSpeechModel
        case transcribing
    }

    /// Per-episode work in flight, driving progress UI.
    private(set) var episodeWork: [Episode.ID: EpisodeWork] = [:]
    private(set) var episodeWorkErrors: [Episode.ID: String] = [:]

    private var mediaDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("CodexCast/media")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// Downloads the analysis rendition — always audio, and the cheapest one,
    /// since detection and transcription are all it exists for (§8.3).
    func downloadAudio(for episode: EpisodeRecord) async throws -> URL {
        if let path = episode.localPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        guard let json = episode.renditions?.data(using: .utf8),
              let renditions = try? JSONDecoder().decode([Rendition].self, from: json)
        else { throw WorkError.noAudio }

        let core = Episode(
            podcastID: episode.podcastId, guid: episode.guid, title: episode.title,
            renditions: renditions
        )
        guard let source = core.analysisRendition?.sources.first
            ?? renditions.first(where: \.isPrimaryEnclosure)?.sources.first
        else { throw WorkError.noAudio }

        episodeWork[episode.id] = .downloading(fraction: nil)
        defer { if case .downloading = episodeWork[episode.id] { episodeWork[episode.id] = nil } }

        let (temp, _) = try await URLSession.shared.download(from: source)
        let destination = mediaDirectory
            .appendingPathComponent(episode.id.rawValue.uuidString)
            .appendingPathExtension(source.pathExtension.isEmpty ? "mp3" : source.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)

        // Content hash: if a re-download differs, dynamic insertion changed the
        // ads and cached segments die with the old file (§4.1).
        let digest = SHA256.hash(data: try Data(contentsOf: destination, options: .mappedIfSafe))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        _ = try await episodes.recordDownload(
            episodeID: episode.id, localPath: destination.path, mediaHash: hash
        )
        return destination
    }

    /// The full on-device path: download, transcribe, persist. This is the
    /// primary transcript path — only ~9% of a real library publishes usable
    /// feed transcripts (A6), so the phone does the work for the rest.
    func transcribeOnDevice(_ episode: EpisodeRecord) async {
        episodeWorkErrors[episode.id] = nil
        do {
            let file = try await downloadAudio(for: episode)

            let engine = TranscriptionEngine()
            episodeWork[episode.id] = .preparingSpeechModel
            if let request = try await engine.assetInstallationRequest() {
                try await request.downloadAndInstall()
            }

            episodeWork[episode.id] = .transcribing
            let transcript = try await engine.transcribe(fileAt: file)

            // §9.8: a music show or corrupt file is marked, not retried forever.
            let durationMs = episode.durationMs ?? transcript.durationMs
            if TranscriptQualityGate.verdict(transcript, mediaDurationMs: durationMs) != nil {
                episodeWorkErrors[episode.id] =
                    "This episode doesn't seem to be mostly speech, so the transcript was discarded."
            } else {
                try await transcripts.save(transcript, episodeID: episode.id)
            }
        } catch {
            episodeWorkErrors[episode.id] = "Transcription failed: \(error.localizedDescription)"
        }
        episodeWork[episode.id] = nil
    }

    enum WorkError: LocalizedError {
        case noAudio
        var errorDescription: String? { "This episode has no downloadable audio." }
    }

    // MARK: - Audio settings (A5.4)

    func applyAudioSettings() {
        player.setRate(audioSettings.speed)
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
                renditionsJSON: episode.renditions.isEmpty ? nil
                    : (try? encoder.encode(episode.renditions))
                        .flatMap { String(data: $0, encoding: .utf8) },
                // Empty must be stored as absent: "[]" is not "has transcripts",
                // and the distinction drives which action the episode screen offers.
                feedTranscriptsJSON: episode.transcripts.isEmpty ? nil
                    : (try? encoder.encode(episode.transcripts))
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
    func play(_ episode: EpisodeRecord, startAtMs: Int? = nil) {
        guard let renditionData = episode.renditions?.data(using: .utf8),
              let renditions = try? JSONDecoder().decode([Rendition].self, from: renditionData),
              let url = renditions.first(where: \.isPrimaryEnclosure)?.sources.first
                ?? renditions.first?.sources.first
        else { return }

        // No detected segments yet, so the timeline is the identity mapping —
        // exactly why DisplayTimeline was built before skipping existed.
        let timeline = DisplayTimeline(mediaDurationMs: episode.durationMs ?? 0)
        player.load(url: url, timeline: timeline, startAtMs: startAtMs ?? episode.playbackPositionMs)
        player.play()
        nowPlaying = episode
    }
}
