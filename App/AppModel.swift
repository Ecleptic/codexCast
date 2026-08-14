import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import CodexCastPipeline
import CodexCastDetection
import CodexCastDetectionAFM
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
    let segmentRepository: SegmentRepository

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
        segmentRepository = SegmentRepository(database: database)
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

    // MARK: - Ad detection (§5, first on-device pass)

    enum ScanState: Equatable {
        case scanning(windowsDone: Int, windowsTotal: Int)
        case done(found: Int, seconds: Int)
        case unavailable(String)
    }

    private(set) var scanState: [Episode.ID: ScanState] = [:]

    /// Runs Stage 2 over an episode's transcript on this device and stores the
    /// results. Sponsor hints from the show notes feed the model's context
    /// (A6) — who to look for, known before any learning has happened.
    func scanForAds(_ episode: EpisodeRecord) async {
        guard let transcript = try? await transcripts.transcript(episodeID: episode.id) else {
            scanState[episode.id] = .unavailable("Transcribe the episode first.")
            return
        }

        let classifier = OnDeviceClassifier()
        guard await classifier.isAvailable else {
            scanState[episode.id] = .unavailable(
                "Apple Intelligence isn't available on this device or isn't enabled."
            )
            return
        }

        let showName = library.first { $0.id == episode.podcastId }?.title ?? "this show"
        let hints = SponsorHintExtractor.extract(from: episode.summary ?? "")
        let context = ClassificationContext(
            showName: showName,
            knownSponsors: hints.map(\.name)
        )

        let started = Date()
        let windows = TranscriptWindower.windows(for: transcript)
        scanState[episode.id] = .scanning(windowsDone: 0, windowsTotal: windows.count)
        classifier.prewarm(context: context)

        var findings: [WindowFinding] = []
        for (index, window) in windows.enumerated() {
            // Thermal courtesy (§5.3.6): back off rather than cook the phone.
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                break
            }
            if let result = try? await classifier.classify(window: window, context: context) {
                findings.append(contentsOf: result)
            }
            scanState[episode.id] = .scanning(windowsDone: index + 1, windowsTotal: windows.count)
        }

        // Snap, dedupe, gate — the same post-processing the harness uses.
        var segments: [DetectedSegment] = []
        for finding in TranscriptWindower.deduplicate(findings) {
            guard let start = transcript.nearestBoundary(toMs: finding.startMs),
                  let end = transcript.nearestBoundary(toMs: finding.endMs),
                  end > start
            else { continue }
            segments.append(DetectedSegment(
                episodeID: episode.id,
                startMs: start, endMs: end,
                kind: finding.kind,
                confidence: finding.confidence,
                provenance: .onDeviceModel(windowIndex: 0, modelTier: "afm-device"),
                rationale: finding.rationale,
                sponsorID: nil
            ))
        }

        try? await segmentRepository.replaceMachineSegments(segments, episodeID: episode.id)

        let elapsed = Int(Date().timeIntervalSince(started))
        scanState[episode.id] = .done(found: segments.count, seconds: elapsed)
    }

    /// The gate's verdict for an episode, driving both the UI and skipping.
    func gatedSegments(for episode: EpisodeRecord) async -> ValidationGate.Outcome? {
        guard let segments = try? await segmentRepository.segments(episodeID: episode.id),
              !segments.isEmpty
        else { return nil }
        return ValidationGate().evaluate(
            segments: segments,
            episodeDurationMs: episode.durationMs ?? segments.map(\.endMs).max() ?? 0
        )
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

    /// Streams an episode's primary audio, with any gated ad segments loaded
    /// as skip blocks — detection's output becomes playback behavior here.
    func play(_ episode: EpisodeRecord, startAtMs: Int? = nil) {
        Task {
            await playWithSegments(episode, startAtMs: startAtMs)
        }
    }

    private func playWithSegments(_ episode: EpisodeRecord, startAtMs: Int?) async {
        let outcome = await gatedSegments(for: episode)
        let blocks = (outcome?.autoSkippable ?? []).map { segment in
            SkipBlock(startMs: segment.startMs, endMs: segment.endMs, segmentIDs: [segment.id])
        }
        startPlayback(episode, startAtMs: startAtMs, blocks: blocks)
    }

    private func startPlayback(_ episode: EpisodeRecord, startAtMs: Int?, blocks: [SkipBlock]) {
        guard let renditionData = episode.renditions?.data(using: .utf8),
              let renditions = try? JSONDecoder().decode([Rendition].self, from: renditionData),
              let url = renditions.first(where: \.isPrimaryEnclosure)?.sources.first
                ?? renditions.first?.sources.first
        else { return }

        let timeline = DisplayTimeline(
            mediaDurationMs: episode.durationMs ?? 0,
            blocks: blocks
        )
        player.load(url: url, timeline: timeline, startAtMs: startAtMs ?? episode.playbackPositionMs)
        player.play()
        nowPlaying = episode
    }
}
