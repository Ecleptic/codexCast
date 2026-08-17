import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import CodexCastPipeline
import AVFoundation
import AVKit
import BackgroundTasks
import CodexCastDetection
import MediaPlayer
import NaturalLanguage
import UIKit
import UserNotifications
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
    let patternRepository: AdPatternRepository
    let corrections: CorrectionRepository
    let chapters: ChapterRepository
    let positionRules: PositionRuleRepository
    let calibration: CalibrationRepository
    let sponsors: SponsorRepository
    let neverSkip: NeverSkipRepository
    let fingerprints: FingerprintRepository
    let charts = TopChartsClient()

    private(set) var library: [PodcastRecord] = []
    private(set) var playlists: [Playlist] = []
    private(set) var refreshError: String?
    /// Global audio settings (A5.4), persisted across launches. Per-show
    /// overrides resolve against these.
    var audioSettings: AudioSettings {
        didSet { persistAudioSettings() }
    }

    private func persistAudioSettings() {
        if let data = try? JSONEncoder().encode(audioSettings) {
            UserDefaults.standard.set(data, forKey: "audioSettings")
        }
    }

    private static func loadAudioSettings() -> AudioSettings {
        guard let data = UserDefaults.standard.data(forKey: "audioSettings"),
              let decoded = try? JSONDecoder().decode(AudioSettings.self, from: data)
        else { return AudioSettings() }
        return decoded
    }

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
        audioSettings = Self.loadAudioSettings()
        showDefaults = Self.loadShowDefaults()
        patternRepository = AdPatternRepository(database: database)
        corrections = CorrectionRepository(database: database)
        chapters = ChapterRepository(database: database)
        positionRules = PositionRuleRepository(database: database)
        calibration = CalibrationRepository(database: database)
        sponsors = SponsorRepository(database: database)
        neverSkip = NeverSkipRepository(database: database)
        fingerprints = FingerprintRepository(database: database)
    }

    // MARK: - Library

    /// A2 badges: which promotional-content kinds have been found per show.
    private(set) var showBadges: [Podcast.ID: Set<SegmentKind>] = [:]

    func reloadLibrary() async {
        library = (try? await podcasts.all()) ?? []
        try? await playlistRepository.ensureBuiltIns()
        playlists = (try? await playlistRepository.all()) ?? []
        showBadges = (try? await segmentRepository.kindsByShow()) ?? [:]
    }

    // MARK: - Global show defaults ("set once, applies to my regulars")

    /// Per-class defaults: followed shows (the regulars) usually want the
    /// full pipeline; added shows (the browsing library) usually want
    /// nothing automatic.
    struct ShowDefaults: Codable, Hashable {
        var episodeLimit: Int?
        var autoDownload = false
        var autoTranscribe = false
        var autoScan = false
        var notifyOn: NotifyOn = .never
    }

    struct GlobalShowDefaults: Codable, Hashable {
        var followed = ShowDefaults()
        var added = ShowDefaults()
    }

    var showDefaults: GlobalShowDefaults {
        didSet {
            if let data = try? JSONEncoder().encode(showDefaults) {
                UserDefaults.standard.set(data, forKey: "showDefaults")
            }
        }
    }

    static func loadShowDefaults() -> GlobalShowDefaults {
        guard let data = UserDefaults.standard.data(forKey: "showDefaults"),
              let decoded = try? JSONDecoder().decode(GlobalShowDefaults.self, from: data)
        else { return GlobalShowDefaults() }
        return decoded
    }

    /// Writes one class's defaults onto one show — used for newly subscribed
    /// shows and by the explicit "apply to all" buttons. Never runs behind
    /// the user's back on existing shows.
    func applyDefaults(_ defaults: ShowDefaults, to podcastID: Podcast.ID) async {
        try? await retention.setLimit(defaults.episodeLimit, podcastID: podcastID)
        try? await podcasts.setAutoDownload(defaults.autoDownload, podcastID: podcastID)
        await savePipelinePrefs(
            ShowPipelinePrefs(autoTranscribe: defaults.autoTranscribe, autoScan: defaults.autoScan),
            podcastID: podcastID
        )
        await setNotifySetting(defaults.notifyOn, podcastID: podcastID)
    }

    func applyDefaultsToAll(followedShows: Bool) async {
        let defaults = followedShows ? showDefaults.followed : showDefaults.added
        for podcast in library where podcast.isFollowed == followedShows {
            await applyDefaults(defaults, to: podcast.id)
        }
        await reloadLibrary()
    }

    /// Clears an episode's progress so it leaves Continue Listening; if it's
    /// the one playing right now, playback stops and the mini player goes
    /// with it — "remove" means gone, not lurking.
    func removeFromContinueListening(_ episode: EpisodeRecord) async {
        if nowPlaying?.id == episode.id {
            player.pause()
            nowPlaying = nil
            UserDefaults.standard.removeObject(forKey: "lastEpisodeID")
        }
        try? await episodes.savePosition(episodeID: episode.id, positionMs: 0, durationMs: nil)
    }

    func setFollowed(_ followed: Bool, podcast: PodcastRecord) async {
        try? await podcasts.setFollowed(followed, podcastID: podcast.id)
        await reloadLibrary()
    }

    // MARK: - Playlists (A5.2)

    func episodes(in playlist: Playlist) async -> [EpisodeRecord] {
        (try? await playlistRepository.episodes(in: playlist)) ?? []
    }

    func reorderPlaylist(_ id: Playlist.ID, episodeIDs: [Episode.ID]) async {
        try? await playlistRepository.reorder(playlistID: id, episodeIDs: episodeIDs)
    }

    func playNext(_ episode: EpisodeRecord) async {
        guard let queue = playlists.first(where: { $0.name == Playlist.upNextName }) else { return }
        try? await playlistRepository.append(episodeID: episode.id, to: queue.id)
        let ids = ((try? await playlistRepository.episodes(in: queue)) ?? []).map(\.id)
        // Move to the front.
        var reordered = ids.filter { $0 != episode.id }
        reordered.insert(episode.id, at: 0)
        try? await playlistRepository.reorder(playlistID: queue.id, episodeIDs: reordered)
    }

    func togglePlayed(_ episode: EpisodeRecord) async {
        try? await episodes.setPlayed(!episode.isPlayed, episodeID: episode.id)
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
                let fileName = (eviction.localPath as NSString).lastPathComponent
                let url = mediaDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: SilenceMap.sidecarURL(for: url))
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

    /// A live sentence for whatever step is running, preferred over the scan
    /// chain's coarser label whenever fine-grained work state exists.
    func workLabel(for episodeID: Episode.ID) -> String? {
        switch episodeWork[episodeID] {
        case .downloading(let fraction):
            if let fraction {
                return "Downloading… \(Int(fraction * 100))%"
            }
            return "Downloading the episode…"
        case .preparingSpeechModel:
            return "Preparing the speech model…"
        case .transcribing:
            return "Transcribing on this iPhone…"
        case nil:
            return nil
        }
    }

    /// The episode's media file as it exists RIGHT NOW, or nil.
    ///
    /// Stored `localPath` values are absolute and embed the app's
    /// data-container UUID — which iOS changes across app updates. Field
    /// bug: the file survived a reinstall but its stored address didn't, so
    /// every "does the file exist" check silently failed (no waveform, no
    /// local playback, re-downloads). Resolution goes by FILENAME against
    /// wherever the media directory lives today; the stored path is only a
    /// legacy fallback.
    func localFileURL(for episode: EpisodeRecord) -> URL? {
        guard let stored = episode.localPath else { return nil }
        let fileName = (stored as NSString).lastPathComponent
        let resolved = mediaDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }
        if FileManager.default.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored)
        }
        return nil
    }

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
        if let existing = localFileURL(for: episode) {
            return existing
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

        // If this episode is playing right now (the scan chain downloads
        // mid-listen), refresh the in-memory record and give the seek bar
        // its waveform — the visible proof the download happened.
        if nowPlaying?.id == episode.id,
           let fresh = try? await episodes.find(id: episode.id) {
            nowPlaying = fresh
            await loadWaveform(for: fresh)
        }
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
        /// The chain's long non-window steps — downloading, transcribing,
        /// drift check, candidate verification — each named so the UI is
        /// never silent while minutes of real work happen.
        case preparing(String)
        case scanning(windowsDone: Int, windowsTotal: Int)
        case done(found: Int, seconds: Int)
        case unavailable(String)
    }

    private(set) var scanState: [Episode.ID: ScanState] = [:]

    /// Runs Stage 2 over an episode's transcript on this device and stores the
    /// results. Sponsor hints from the show notes feed the model's context
    /// (A6) — who to look for, known before any learning has happened.
    func scanForAds(_ episode: EpisodeRecord) async {
        // No transcript yet? Do the whole chain — download (transcription
        // already requires the file), transcribe, then scan. One tap should
        // never dead-end into "do the other thing first".
        if !((try? await transcripts.hasTranscript(episodeID: episode.id)) ?? false) {
            let needsDownload = localFileURL(for: episode) == nil
            scanState[episode.id] = .preparing(
                needsDownload ? "Downloading the episode…" : "Transcribing on this iPhone…"
            )
            await transcribeOnDevice(episode)
        }
        guard var transcript = try? await transcripts.transcript(episodeID: episode.id) else {
            scanState[episode.id] = .unavailable(
                episodeWorkErrors[episode.id] ?? "Couldn't transcribe this episode."
            )
            return
        }

        // A1: a feed transcript's timestamps must be verified against the
        // audio we actually downloaded before detection trusts them — a
        // transcript made from the ad-free master runs minutes early after
        // dynamic insertion, and it is silent about exactly the ads we're
        // looking for. Three 20s samples, once per episode.
        if transcript.source == .podcasting20,
           let audioURL = localFileURL(for: episode),
           !((try? await transcripts.isDriftChecked(episodeID: episode.id)) ?? true) {
            scanState[episode.id] = .preparing("Verifying the feed transcript against the audio…")
            let engine = TranscriptionEngine()
            if let samples = try? await engine.sampleTranscripts(fileAt: audioURL) {
                let verdict = TranscriptDriftDetector.verdict(feed: transcript, samples: samples)
                if verdict.isDesynced,
                   let local = try? await engine.transcribe(fileAt: audioURL) {
                    // Correct timestamps beat prettier text: replace the feed
                    // transcript with one made from this exact file.
                    try? await transcripts.save(local, episodeID: episode.id)
                    transcript = local
                }
            }
            try? await transcripts.markDriftChecked(episodeID: episode.id)
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

        // §6.6: passages the model previously called ads on this show and the
        // listener overruled. Their text goes back into the prompt as "this
        // is content" — the cheapest per-show teaching there is.
        var exemplars: [String] = []
        if let rejections = try? await segmentRepository.recentRejections(podcastID: episode.podcastId) {
            for span in rejections {
                let spanTranscript: TimedTranscript?
                if span.episodeID == episode.id {
                    spanTranscript = transcript
                } else {
                    spanTranscript = try? await transcripts.transcript(episodeID: span.episodeID)
                }
                guard let spanTranscript else { continue }
                let text = spanTranscript.text(fromMs: span.startMs, toMs: span.endMs)
                if !text.isEmpty { exemplars.append(String(text.prefix(400))) }
            }
        }
        // Cold start: a show with no correction history gets built-in
        // exemplars of the demonstrated failure mode — tech coverage that
        // reads like sponsor copy. The first field test produced five
        // confident false positives on exactly this, before any teaching
        // signal existed to prevent it.
        if exemplars.isEmpty {
            exemplars = Self.coldStartNegativeExemplars
        }

        let context = ClassificationContext(
            showName: showName,
            knownSponsors: hints.map(\.name),
            negativeExemplars: exemplars,
            showNotes: loadCombinedPrefs(for: episode.podcastId).classifierNotes
        )

        let started = Date()
        var segments: [DetectedSegment] = []

        // Stage 0 (§5.1): position rules — free, and on regularly-heard shows
        // they resolve the pre-roll before any model spends a token. Their
        // confidence is their measured reliability, so a young machine rule
        // proposes below the auto-skip bar and earns its way up.
        let episodeDurationMs = episode.durationMs ?? transcript.durationMs
        if let rules = try? await positionRules.rules(podcastID: episode.podcastId) {
            for rule in rules {
                var markerMs: Int?
                if case .afterMarker(let marker) = rule.anchor {
                    markerMs = transcript.segments
                        .first { $0.text.localizedCaseInsensitiveContains(marker) }?
                        .endMs
                }
                guard let proposal = rule.propose(
                    episodeDurationMs: episodeDurationMs, markerMs: markerMs
                ) else { continue }
                segments.append(DetectedSegment(
                    episodeID: episode.id,
                    startMs: proposal.startMs, endMs: proposal.endMs,
                    kind: .ad,
                    confidence: proposal.confidence,
                    provenance: .positionPrior(ruleID: rule.id.rawValue),
                    rationale: rule.userCreated
                        ? "You always skip this part of the show"
                        : "This show usually has an ad here (\(rule.anchor.label.lowercased()))"
                ))
            }
        }

        // Stage 1b: audio fingerprints of confirmed ads. Byte-identical
        // repeats match with near-zero false positives, across shows —
        // Shazam's matcher pointed at our own catalog, on device.
        if let audioURL = localFileURL(for: episode),
           let stored = try? await fingerprints.all(), !stored.isEmpty {
            scanState[episode.id] = .preparing("Listening for ads you've confirmed before…")
            let references = stored.map {
                AdFingerprinter.Reference(id: $0.id, signature: $0.signature, durationMs: $0.durationMs)
            }
            let hits = await Task.detached(priority: .userInitiated) {
                await AdFingerprinter.matches(fileURL: audioURL, references: references)
            }.value
            for hit in hits {
                guard !segments.contains(where: {
                    $0.overlaps(startMs: hit.startMs, endMs: hit.endMs)
                }) else { continue }
                segments.append(DetectedSegment(
                    episodeID: episode.id,
                    startMs: hit.startMs, endMs: hit.endMs,
                    kind: .ad,
                    confidence: 0.96,
                    provenance: .acoustic(signal: "fingerprint"),
                    rationale: "Same audio as an ad you've confirmed",
                    sponsorID: stored.first { $0.id == hit.referenceID }?.sponsorID
                ))
            }
        }

        // Stage 1: patterns the listener has taught. Text, not
        // timestamps, so they survive dynamic insertion — and they are the
        // trustworthy tier, unlike the model's self-reported confidence.
        if let patternRecords = try? await patternRepository.all() {
            let patterns = patternRecords
                .filter { $0.podcastId == nil || $0.podcastId == episode.podcastId }
                .map { PatternBaselineDetector.Pattern(text: $0.text, durationMs: 60_000, sponsor: nil) }
            if !patterns.isEmpty {
                let detector = PatternBaselineDetector(patterns: patterns)
                for match in detector.detect(in: transcript) {
                    // A position prior already covering this span keeps it;
                    // two overlapping segments would double-fire the skip.
                    guard !segments.contains(where: {
                        $0.overlaps(startMs: match.startMs, endMs: match.endMs)
                    }) else { continue }
                    segments.append(DetectedSegment(
                        episodeID: episode.id,
                        startMs: match.startMs, endMs: match.endMs,
                        kind: .ad,
                        confidence: min(0.95, 0.6 + match.score),
                        provenance: .patternMatch(patternID: UUID(), score: match.score),
                        rationale: "Matches an ad you've marked before"
                    ))
                }
            }
        }

        // Stage 2 dispatch honors what Stages 0/1 already resolved (§5.3.2):
        // fully-resolved windows are never sent to the model at all, and
        // partially-resolved ones carry "[already identified]" annotations —
        // which both cuts inference time on well-learned shows (the Phase 3
        // acceptance metric) and helps the model spot the next spot in a
        // stacked ad break.
        let resolved = segments.map {
            TranscriptWindow.ResolvedRegion(
                startMs: $0.startMs, endMs: $0.endMs,
                label: $0.kind == .ad ? "AD" : $0.kind.rawValue.uppercased()
            )
        }

        // §5.3.2: window size derives from the model's context and this
        // transcript's measured density — never a hardcoded token budget.
        let windowConfiguration = TranscriptWindower.Configuration.fitted(
            to: transcript,
            contextTokens: OnDeviceClassifier.contextWindowTokens,
            reservedTokens: classifier.reservedTokens(for: context)
        )
        let windows = TranscriptWindower.windows(
            for: transcript, resolved: resolved, configuration: windowConfiguration
        )
        // A4, checked FIRST: many shows run a music bed under ad reads.
        // Music regions are computed before any model pass and used as a
        // suspicion source — evidence, never a verdict (transitions and
        // intros are music too; the verifier still decides from the words).
        var musicRegions: [MusicBedDetector.Region] = []
        if let audioURL = localFileURL(for: episode) {
            scanState[episode.id] = .preparing("Listening for music beds…")
            musicRegions = await Task.detached(priority: .userInitiated) {
                MusicBedDetector.musicRegions(fileURL: audioURL)
            }.value
        }

        scanState[episode.id] = .scanning(windowsDone: 0, windowsTotal: windows.count)
        classifier.prewarm(context: context)

        // Two-pass Stage 2, measured 6x better than single-pass on the
        // corpus (strict F1 0.07→0.42, boundary error 49s→11s).
        // Pass 1: recall-tuned sweep for candidate stretches.
        var rawSweeps: [(startMs: Int, endMs: Int)] = []
        for (index, window) in windows.enumerated() {
            // Thermal courtesy (§5.3.6): back off rather than cook the phone.
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                break
            }
            if let spans = try? await classifier.sweep(window: window) {
                rawSweeps.append(contentsOf: spans)
            }
            scanState[episode.id] = .scanning(windowsDone: index + 1, windowsTotal: windows.count)
        }
        // Chapter-shaped candidates (hybrid architecture, measured recall
        // 0.36→0.82 on the corpus): topic-segment the transcript, then a
        // chapter earns verification if the sweep flagged inside it OR it
        // contains a lexical ad marker — "use promo code" can't appear in
        // editorial content by accident, and unlike the sweep it can't doze
        // off an hour into the episode.
        let chapters = await Task.detached(priority: .userInitiated) { [transcript] in
            TopicSegmenter.chapters(for: transcript)
        }.value
        var candidates: [(span: ClosedRange<Int>, agreement: Int)]
        if let chapters {
            candidates = []
            for chapter in chapters {
                let overlappingSweeps = rawSweeps.filter {
                    $0.startMs < chapter.endMs && chapter.startMs < $0.endMs
                }.count
                let marker = LexicalAdMarkers.hit(
                    transcript.text(fromMs: chapter.startMs, toMs: chapter.endMs)
                )
                let musicOverlapMs = musicRegions.reduce(0) { total, region in
                    total + max(0, min(region.endMs, chapter.endMs) - max(region.startMs, chapter.startMs))
                }
                let music = musicOverlapMs >= 5_000
                guard overlappingSweeps > 0 || marker || music else { continue }
                candidates.append((
                    chapter.startMs...chapter.endMs,
                    overlappingSweeps + (marker ? 1 : 0) + (music ? 1 : 0)
                ))
            }
        } else {
            // Embedding assets unavailable: sweep hits plus music regions.
            candidates = Self.mergeCandidates(
                rawSweeps + musicRegions.map { ($0.startMs, $0.endMs) }
            )
        }

        // §5.7 calibration inputs.
        let calibrator = ConfidenceCalibrator(bins: (try? await calibration.bins()) ?? [])
        let recentRaw = (try? await calibration.recentModelRawConfidences()) ?? []
        // Learned per-show boundary bias from adjust corrections, applied to
        // edges the quote anchors couldn't ground.
        let boundaryBias = try? await corrections.meanBoundaryOffsets(podcastID: episode.podcastId)

        // Pass 2: precision-tuned verification of each candidate. The
        // verdict must cite evidence, and boundaries come from the quoted
        // first/last words located in the transcript — the model copies far
        // better than it counts.
        var verdictConfidences: [Double] = []
        var verified: [(candidate: (span: ClosedRange<Int>, agreement: Int),
                        verdict: OnDeviceClassifier.Verification,
                        startMs: Int, endMs: Int)] = []
        for (candidateIndex, candidate) in candidates.enumerated() {
            scanState[episode.id] = .preparing(
                "Double-checking suspicious section \(candidateIndex + 1) of \(candidates.count)…"
            )
            let excerpt = Self.excerptPrompt(for: candidate.span, transcript: transcript)
            guard let verdict = try? await classifier.verify(excerpt: excerpt, context: context),
                  verdict.isAd
            else { continue }
            verdictConfidences.append(verdict.confidence)

            let startAnchor = verdict.firstWords.flatMap {
                TranscriptQuoteLocator.locate(quote: $0, in: transcript, nearMs: candidate.span.lowerBound)
            }
            let endAnchor = verdict.lastWords.flatMap {
                TranscriptQuoteLocator.locate(quote: $0, in: transcript, nearMs: candidate.span.upperBound)
            }
            // Evidence must ground: a verdict whose quoted words appear
            // nowhere in the transcript is a rubber stamp, and on the corpus
            // the ungrounded approvals were exactly the false positives and
            // the chapter-width boundary blowouts.
            guard startAnchor != nil || endAnchor != nil else { continue }
            let fallbackStart = candidate.span.lowerBound + ((boundaryBias ?? nil)?.startMs ?? 0)
            let fallbackEnd = candidate.span.upperBound + ((boundaryBias ?? nil)?.endMs ?? 0)
            let start = startAnchor?.startMs
                ?? transcript.nearestBoundary(toMs: fallbackStart)
                ?? fallbackStart
            let end = endAnchor?.endMs
                ?? transcript.nearestBoundary(toMs: fallbackEnd)
                ?? fallbackEnd
            // Sub-5s output is noise; the gate floor applies at storage too.
            guard end > start, end - start >= 5_000 else { continue }
            guard !segments.contains(where: { $0.overlaps(startMs: start, endMs: end) }) else { continue }
            verified.append((candidate, verdict, start, end))
        }

        let degenerate = ConfidenceCalibrator.isDegenerate(
            recentRawConfidences: recentRaw + verdictConfidences
        )

        for entry in verified {
            // §6.2: a sponsor the model named becomes (or joins) a registry
            // entity, so the same sponsor on a different show is recognized.
            var sponsorID: UUID?
            if let sponsorName = entry.verdict.sponsor {
                sponsorID = try? await sponsors.findOrCreate(name: sponsorName)
            }

            let raw = entry.verdict.confidence
            let confidence: Double
            if degenerate {
                let possible = windows.filter { window in
                    guard let first = window.cues.first, let last = window.cues.last else { return false }
                    return first.startMs < entry.endMs && last.endMs > entry.startMs
                }.count
                confidence = ConfidenceCalibrator.agreementConfidence(
                    agreeing: entry.candidate.agreement, possible: max(possible, 1)
                )
            } else if calibrator.hasHistory(stage: "onDeviceModel") {
                confidence = calibrator.calibrated(stage: "onDeviceModel", rawConfidence: raw)
            } else {
                confidence = min(0.98, raw)
            }

            segments.append(DetectedSegment(
                episodeID: episode.id,
                startMs: entry.startMs, endMs: entry.endMs,
                kind: entry.verdict.kind,
                confidence: confidence,
                rawConfidence: raw,
                provenance: .onDeviceModel(windowIndex: 0, modelTier: "afm-device"),
                rationale: entry.verdict.sponsor.map { "Sponsor read for \($0)" }
                    ?? "Promotional read detected",
                sponsorID: sponsorID
            ))
        }

        // §6.4: regions the listener protected are dropped before storage —
        // a rejected span must never resurface on a re-scan.
        if let protections = try? await neverSkip.rules(
            episodeID: episode.id, podcastID: episode.podcastId
        ), !protections.isEmpty {
            segments.removeAll { segment in
                protections.contains { $0.startMs < segment.endMs && segment.startMs < $0.endMs }
            }
        }

        // Stage 3 (§5.4): snap machine boundaries to real silence in the
        // audio. Transcript boundaries wobble by a sentence; a skip that cuts
        // mid-word is instantly noticeable. Uses the same silence map Smart
        // Speed keeps, computing it here if playback hasn't yet.
        if let audioURL = localFileURL(for: episode) {
            var map = SilenceMap.load(for: audioURL)
            if map == nil {
                map = await Task.detached(priority: .utility) {
                    let computed = try? SilenceMap.analyze(fileURL: audioURL)
                    try? computed?.save(for: audioURL)
                    return computed
                }.value
            }
            if let map, !map.gaps.isEmpty {
                let detector = SilenceDetector()
                for index in segments.indices {
                    if let snapped = detector.snap(boundaryMs: segments[index].startMs, toGaps: map.gaps) {
                        segments[index].startMs = snapped
                    }
                    if let snapped = detector.snap(boundaryMs: segments[index].endMs, toGaps: map.gaps),
                       snapped > segments[index].startMs {
                        segments[index].endMs = snapped
                    }
                }
            }
        }

        // §5.5: adjacent spots in one ad break share a chunk, so playback
        // skips the whole break in one jump instead of skip-play-skip.
        segments = DetectionPipeline.assignChunks(segments.sorted { $0.startMs < $1.startMs })

        try? await segmentRepository.replaceMachineSegments(segments, episodeID: episode.id)

        // Every stored proposal opens its calibration bin (§6.4's table).
        var proposalDeciles: [String: [Int]] = [:]
        for segment in segments {
            proposalDeciles[segment.provenance.stageIdentifier, default: []]
                .append(ConfidenceCalibrator.decile(for: segment.rawConfidence ?? segment.confidence))
        }
        for (stage, deciles) in proposalDeciles {
            try? await calibration.recordProposals(stage: stage, deciles: deciles)
        }

        let elapsed = Int(Date().timeIntervalSince(started))
        scanState[episode.id] = .done(found: segments.count, seconds: elapsed)

        // §5.8: where the feed ships no chapters, the topic segmentation the
        // scan already computed becomes user-facing chapters — titled by the
        // model, marked as generated, never confused with authored ones.
        if let chapters, episode.feedChaptersURL == nil,
           ((try? await self.chapters.chapters(episodeID: episode.id)) ?? []).isEmpty {
            var generated: [Chapter] = []
            for chapter in chapters.prefix(40) {
                let excerpt = transcript.text(fromMs: chapter.startMs, toMs: chapter.endMs)
                let title = (try? await classifier.chapterTitle(excerpt: excerpt)) ?? "Chapter"
                generated.append(Chapter(
                    startMs: chapter.startMs, title: title, source: .generated
                ))
            }
            if !generated.isEmpty {
                try? await self.chapters.save(generated, episodeID: episode.id)
            }
        }
    }

    /// Overlapping sweep spans collapse into one candidate; the count of
    /// spans that merged is the §5.7 agreement signal.
    static func mergeCandidates(
        _ spans: [(startMs: Int, endMs: Int)]
    ) -> [(span: ClosedRange<Int>, agreement: Int)] {
        let sorted = spans.sorted { $0.startMs < $1.startMs }
        var merged: [(span: ClosedRange<Int>, agreement: Int)] = []
        for span in sorted {
            guard span.endMs > span.startMs else { continue }
            if let last = merged.last, span.startMs <= last.span.upperBound + 5_000 {
                merged[merged.count - 1] = (
                    min(last.span.lowerBound, span.startMs)...max(last.span.upperBound, span.endMs),
                    last.agreement + 1
                )
            } else {
                merged.append((span.startMs...span.endMs, 1))
            }
        }
        return merged
    }

    /// The verify prompt: the candidate ±60s of transcript, timestamped,
    /// with the flagged range stated up front.
    static func excerptPrompt(for span: ClosedRange<Int>, transcript: TimedTranscript) -> String {
        let lines = transcript.segments
            .filter { $0.endMs > span.lowerBound - 60_000 && $0.startMs < span.upperBound + 60_000 }
            .map { cue in
                let seconds = cue.startMs / 1000
                return String(format: "[%d:%02d] %@", seconds / 60, seconds % 60, cue.text)
            }
        let from = span.lowerBound / 1000
        let to = span.upperBound / 1000
        return """
        A first pass flagged [\(from / 60):\(String(format: "%02d", from % 60))] to \
        [\(to / 60):\(String(format: "%02d", to % 60))] as possible advertising.

        \(lines.joined(separator: "\n"))
        """
    }

    /// §6.6 cold-start exemplars: product NEWS that superficially resembles
    /// sponsor copy — specs, pricing, availability — but addresses nobody
    /// and asks nothing. Used only until a show has its own rejections.
    private static let coldStartNegativeExemplars = [
        """
        The new flagship ships next month starting at seven ninety nine with \
        the upgraded camera system and the faster chip they announced at the \
        event. Reviewers who got early units say battery life is the real \
        story — nearly two days in mixed use. Preorders open Friday and \
        analysts expect it to outsell last year's model.
        """,
        """
        The startup raised a forty million dollar series B to expand its \
        developer platform. Their pitch is that you write the config once \
        and it deploys anywhere. The CEO told us the free tier isn't going \
        anywhere, though enterprise pricing is going up in January.
        """,
    ]

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

    // MARK: - Sleep timer (§10.4)

    enum SleepTimer: Equatable {
        case off
        case minutes(Int, firesAt: Date)
        case endOfEpisode
    }

    private(set) var sleepTimer: SleepTimer = .off
    private var sleepTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else {
            sleepTimer = .off
            return
        }
        let fireDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimer = .minutes(minutes, firesAt: fireDate)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.player.pause()
            self?.sleepTimer = .off
        }
    }

    func setSleepAtEndOfEpisode() {
        sleepTask?.cancel()
        sleepTimer = .endOfEpisode
    }

    // MARK: - Chapters (§8.2 / §5.8 display side)

    func loadChapters(for episode: EpisodeRecord) async -> [Chapter] {
        if let stored = try? await chapters.chapters(episodeID: episode.id), !stored.isEmpty {
            return stored
        }
        guard let urlString = episode.feedChaptersURL, let url = URL(string: urlString),
              let fetched = try? await fetcher.fetchChapters(url), !fetched.isEmpty
        else { return [] }
        try? await chapters.save(fetched, episodeID: episode.id)
        return fetched
    }

    // MARK: - Per-show playback overrides (§10.4)

    struct ShowPlaybackOverrides: Codable, Hashable {
        var speed: Double?
        var autoSkipAds: Bool?
    }

    func overrides(for podcastID: Podcast.ID) -> ShowPlaybackOverrides {
        let combined = loadCombinedPrefs(for: podcastID)
        return ShowPlaybackOverrides(speed: combined.speed, autoSkipAds: combined.autoSkipAds)
    }

    /// Merges into the combined envelope so playback overrides and pipeline
    /// prefs — which share the storage column — can never clobber each other.
    func saveOverrides(_ overrides: ShowPlaybackOverrides, podcastID: Podcast.ID) async {
        var combined = loadCombinedPrefs(for: podcastID)
        combined.speed = overrides.speed
        combined.autoSkipAds = overrides.autoSkipAds
        await saveCombinedPrefs(combined, podcastID: podcastID)
    }

    // MARK: - Skip undo (§11.2)

    /// Mirrors the engine's last skip for the banner; undo routes the
    /// correction — the single most important entry point in the app.
    var lastSkip: SkipEvent? { player.lastSkip }

    func undoLastSkip() {
        guard let event = player.lastSkip else { return }
        player.undoLastSkip()
        Task {
            for segmentID in event.block.segmentIDs {
                try? await database.write { db in
                    try db.execute(
                        sql: "UPDATE detected_segments SET userState = 'rejected', reviewedAt = ? WHERE id = ?",
                        arguments: [Date(), segmentID.rawValue.uuidString]
                    )
                }
            }
            if let episode = nowPlaying {
                try? await corrections.append(
                    episodeID: episode.id, segmentID: event.block.segmentIDs.first,
                    type: "undoSkip", source: .explicit
                )
                nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
            }
        }
    }

    // MARK: - Segment review (§6.4 confirm / reject from any screen)

    func confirmSegment(_ segment: DetectedSegment, episode: EpisodeRecord) async {
        try? await database.write { db in
            try db.execute(
                sql: "UPDATE detected_segments SET userState = 'confirmed', reviewedAt = ? WHERE id = ?",
                arguments: [Date(), segment.id]
            )
        }
        try? await corrections.append(
            episodeID: episode.id, segmentID: segment.id, type: "confirm", source: .explicit
        )
        // Confirmation is a teaching moment: the confirmed span's words become
        // a pattern, exactly as a manual mark does (§6.4).
        if let transcript = try? await transcripts.transcript(episodeID: episode.id) {
            let text = transcript.text(fromMs: segment.startMs, toMs: segment.endMs)
            if text.split(separator: " ").count >= 8 {
                try? await patternRepository.insert(AdPatternRecord(
                    podcastId: episode.podcastId, text: text,
                    confirmCount: 1, createdFrom: "confirm"
                ))
            }
        }
        await learnPosition(from: segment, episode: episode)
        await recordCalibrationOutcome(for: segment, confirmed: true)
        await linkSponsor(for: segment, episode: episode)
        captureFingerprint(for: segment, episode: episode)
    }

    /// Fingerprints the confirmed span's AUDIO (roadmap round 2 #1):
    /// dynamically inserted ads repeat byte-identically, so one confirmation
    /// becomes an acoustic detector across the whole library. Background —
    /// the user never waits on learning (§6.4).
    private func captureFingerprint(for segment: DetectedSegment, episode: EpisodeRecord) {
        guard let url = localFileURL(for: episode) else { return }
        let startMs = segment.startMs
        let endMs = segment.endMs
        let podcastID = episode.podcastId
        let sponsorID = segment.sponsorID
        let label = segment.rationale
        Task.detached(priority: .utility) { [fingerprints] in
            guard let data = try? AdFingerprinter.signature(
                fileURL: url, startMs: startMs, endMs: endMs
            ) else { return }
            try? await fingerprints.save(
                signature: data, durationMs: endMs - startMs,
                podcastID: podcastID, sponsorID: sponsorID, label: label
            )
        }
    }

    /// §6.2: a confirmation is when a sponsor becomes real. Prefer the
    /// model's sponsor field (already linked at scan time); fall back to
    /// named-entity extraction over the confirmed span's words.
    private func linkSponsor(for segment: DetectedSegment, episode: EpisodeRecord) async {
        var sponsorID = segment.sponsorID
        if sponsorID == nil,
           let transcript = try? await transcripts.transcript(episodeID: episode.id) {
            let text = transcript.text(fromMs: segment.startMs, toMs: segment.endMs)
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            var organization: String?
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word, scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, range in
                if tag == .organizationName {
                    organization = String(text[range])
                    return false
                }
                return true
            }
            if let organization {
                sponsorID = try? await sponsors.findOrCreate(name: organization)
                if let sponsorID {
                    try? await database.write { db in
                        try db.execute(
                            sql: "UPDATE detected_segments SET sponsorId = ? WHERE id = ?",
                            arguments: [sponsorID.uuidString, segment.id]
                        )
                    }
                }
            }
        }
        if let sponsorID {
            try? await sponsors.recordConfirmation(sponsorID)
        }
    }

    /// §6.4: every explicit verdict lands in the §5.7 calibration bins,
    /// keyed by the stage's RAW score decile.
    private func recordCalibrationOutcome(for segment: DetectedSegment, confirmed: Bool) async {
        guard !segment.provenance.isUserOriginated else { return }
        try? await calibration.recordOutcome(
            stage: segment.provenance.stageIdentifier,
            decile: ConfidenceCalibrator.decile(for: segment.rawConfidence ?? segment.confidence),
            confirmed: confirmed
        )
    }

    // MARK: - Learning export/import (§6.10, A3.3)

    /// The whole learning store as pretty-printed JSON — the file that goes
    /// to a frontier model for distillation.
    func exportLearningJSON() async -> String? {
        let notes = library.compactMap { podcast -> LearningTransfer.Archive.ShowNote? in
            guard let note = classifierNotes(for: podcast.id) else { return nil }
            return LearningTransfer.Archive.ShowNote(feedURL: podcast.feedURL, note: note)
        }
        guard let archive = try? await LearningTransfer(database: database).export(showNotes: notes)
        else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Imports a raw or distilled learning file. Returns a user-facing
    /// summary line.
    func importLearningJSON(from url: URL) async -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let archive = try? decoder.decode(LearningTransfer.Archive.self, from: data)
        else { return "Couldn't read that learning file." }
        guard let summary = try? await LearningTransfer(database: database).importArchive(archive)
        else { return "That file couldn't be imported." }
        // Notes ride the archive too; apply any for shows we have.
        for note in archive.showNotes {
            if let podcast = library.first(where: { $0.feedURL == note.feedURL }) {
                await saveClassifierNotes(note.note, podcastID: podcast.id)
            }
        }
        return "Added \(summary.patternsAdded) patterns, \(summary.sponsorsAdded) sponsors, \(summary.rulesAdded) position rules."
    }

    // MARK: - Position rules (§5.1/§6.3)

    /// Every confirmed ad teaches the show's position statistics: which
    /// anchor it fits, and how long ads there run (Welford, never samples).
    private func learnPosition(from segment: DetectedSegment, episode: EpisodeRecord) async {
        let episodeDuration = episode.durationMs ?? player.timeline.mediaDurationMs
        guard episodeDuration > 0 else { return }
        let anchor = PositionRule.anchor(
            forSegmentStartMs: segment.startMs, endMs: segment.endMs,
            episodeDurationMs: episodeDuration
        )
        let existing = (try? await positionRules.rules(
            podcastID: episode.podcastId, includeDisabled: true
        )) ?? []
        var rule = existing.first { $0.anchor == anchor }
            ?? PositionRule(podcastID: episode.podcastId, anchor: anchor)
        rule.recordHit(durationMs: segment.endMs - segment.startMs)
        try? await positionRules.save(rule)
    }

    /// A rejected Stage 0 proposal counts against its rule; unreliable
    /// machine rules disable themselves (§6.3).
    private func recordPositionMiss(for segment: DetectedSegment, podcastID: Podcast.ID) async {
        guard case .positionPrior(let ruleID) = segment.provenance else { return }
        let existing = (try? await positionRules.rules(
            podcastID: podcastID, includeDisabled: true
        )) ?? []
        guard var rule = existing.first(where: { $0.id.rawValue == ruleID }) else { return }
        rule.recordMiss()
        try? await positionRules.save(rule)
    }

    /// Adjust boundaries (§6.4): as Confirm, but the pattern comes from the
    /// CORRECTED span — the wrong span teaches the wrong text — and the
    /// old→new delta feeds boundary-offset learning.
    func adjustSegment(
        _ segment: DetectedSegment,
        newStartMs: Int,
        newEndMs: Int,
        episode: EpisodeRecord
    ) async {
        guard newEndMs > newStartMs + 1_000 else { return }
        try? await database.write { db in
            try db.execute(
                sql: """
                UPDATE detected_segments
                SET startMs = ?, endMs = ?, userState = 'adjusted', reviewedAt = ?
                WHERE id = ?
                """,
                arguments: [newStartMs, newEndMs, Date(), segment.id]
            )
        }
        let encoder = JSONEncoder()
        let previous = String(
            data: (try? encoder.encode(["startMs": segment.startMs, "endMs": segment.endMs])) ?? Data(),
            encoding: .utf8
        )
        let corrected = String(
            data: (try? encoder.encode(["startMs": newStartMs, "endMs": newEndMs])) ?? Data(),
            encoding: .utf8
        )
        try? await corrections.append(
            episodeID: episode.id, segmentID: segment.id,
            type: "adjustBoundaries", source: .explicit,
            previousValue: previous, newValue: corrected
        )

        var adjusted = segment
        adjusted.startMs = newStartMs
        adjusted.endMs = newEndMs
        if let transcript = try? await transcripts.transcript(episodeID: episode.id) {
            let text = transcript.text(fromMs: newStartMs, toMs: newEndMs)
            if text.split(separator: " ").count >= 8 {
                try? await patternRepository.insert(AdPatternRecord(
                    podcastId: episode.podcastId, text: text,
                    confirmCount: 1, createdFrom: "adjustBoundaries"
                ))
            }
        }
        await learnPosition(from: adjusted, episode: episode)
        await recordCalibrationOutcome(for: segment, confirmed: true)
        await linkSponsor(for: adjusted, episode: episode)
        captureFingerprint(for: adjusted, episode: episode)

        if nowPlaying?.id == episode.id {
            nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
        }
    }

    /// "Never skip this show's intro" (§6.4): protects the opening stretch of
    /// every episode of this show, and rejects the segment that prompted it.
    func neverSkipIntro(_ segment: DetectedSegment, episode: EpisodeRecord) async {
        try? await neverSkip.addShowRule(
            podcastID: episode.podcastId,
            startMs: 0, endMs: max(segment.endMs, 60_000),
            reason: "This show's intro"
        )
        await rejectSegment(segment, episode: episode)
    }

    /// "Always skip this position" — one tap from a segment (§6.4). Promotes
    /// the matching rule to user-created, which never auto-disables.
    func alwaysSkipPosition(_ segment: DetectedSegment, episode: EpisodeRecord) async {
        let episodeDuration = episode.durationMs ?? player.timeline.mediaDurationMs
        guard episodeDuration > 0 else { return }
        let anchor = PositionRule.anchor(
            forSegmentStartMs: segment.startMs, endMs: segment.endMs,
            episodeDurationMs: episodeDuration
        )
        let existing = (try? await positionRules.rules(
            podcastID: episode.podcastId, includeDisabled: true
        )) ?? []
        var rule = existing.first { $0.anchor == anchor }
            ?? PositionRule(podcastID: episode.podcastId, anchor: anchor)
        rule.userCreated = true
        rule.enabled = true
        if rule.sampleCount == 0 {
            rule.recordHit(durationMs: segment.endMs - segment.startMs)
        }
        try? await positionRules.save(rule)
        await confirmSegment(segment, episode: episode)
    }

    func rejectSegment(_ segment: DetectedSegment, episode: EpisodeRecord) async {
        try? await database.write { db in
            try db.execute(
                sql: "UPDATE detected_segments SET userState = 'rejected', reviewedAt = ? WHERE id = ?",
                arguments: [Date(), segment.id]
            )
        }
        try? await corrections.append(
            episodeID: episode.id, segmentID: segment.id, type: "notAnAd", source: .explicit
        )
        await recordPositionMiss(for: segment, podcastID: episode.podcastId)
        await recordCalibrationOutcome(for: segment, confirmed: false)
        // §6.4: a rejection protects this span from ever being re-flagged on
        // a future scan of the same episode.
        try? await neverSkip.addEpisodeRule(
            episodeID: episode.id,
            startMs: segment.startMs, endMs: segment.endMs,
            reason: "Rejected by you"
        )
    }

    // MARK: - Video (§8.3 minimal)

    /// A video rendition URL when the episode has one. Playback uses the same
    /// timeline; the sheet hosts AVPlayerViewController.
    func videoURL(for episode: EpisodeRecord) -> URL? {
        guard let json = episode.renditions?.data(using: .utf8),
              let renditions = try? JSONDecoder().decode([Rendition].self, from: json)
        else { return nil }
        return renditions.first(where: \.isVideo)?.sources.first
    }

    // MARK: - Background work (§9.3, §9.7)

    nonisolated static let refreshTaskID = "app.ckg.codexcast.refresh"
    nonisolated static let processingTaskID = "app.ckg.codexcast.processing"

    nonisolated static func registerBackgroundTasks(model: AppModel) {
        // BGTask is not Sendable but setTaskCompleted is documented
        // thread-safe; the unsafe capture is confined to completing the task.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            nonisolated(unsafe) let bgTask = task
            Task { @MainActor in
                await model.performBackgroundRefresh(nil)
                bgTask.setTaskCompleted(success: true)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            nonisolated(unsafe) let bgTask = task
            Task { @MainActor in
                await model.performOvernightProcessing(nil)
                bgTask.setTaskCompleted(success: true)
            }
        }
    }

    func scheduleBackgroundWork() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        // Overnight: charging + network, per §9.7.
        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    /// Feed refresh + auto-download of the newest episode for opted-in shows.
    func performBackgroundRefresh(_ task: BGAppRefreshTask?) async {
        defer { scheduleBackgroundWork() }
        await reloadLibrary()
        for podcast in library {
            let newGuids = await refreshReturningNew(podcast)
            let notify = notifySetting(for: podcast.id)

            if notify == .newEpisode, !newGuids.isEmpty {
                postNotification(
                    title: podcast.title,
                    body: newGuids.count == 1 ? "New episode available" : "\(newGuids.count) new episodes",
                    id: "new-\(podcast.id)"
                )
            }

            guard podcast.autoDownloadEnabled,
                  let newest = (try? await episodes.episodes(podcastID: podcast.id, limit: 1))?.first,
                  localFileURL(for: newest) == nil,
                  (try? await downloadAudio(for: newest)) != nil
            else { continue }

            if notify == .downloaded {
                postNotification(title: podcast.title, body: "\(newest.title) is ready to listen", id: "dl-\(newest.id)")
            }

            // The per-show pipeline steps (§9.3): download → transcribe → scan,
            // each only if the show opted in.
            let prefs = pipelinePrefs(for: podcast.id)
            if prefs.autoTranscribe {
                await transcribeOnDevice(newest)
                if prefs.autoScan {
                    await scanForAds(newest)
                    if notify == .processed {
                        postNotification(
                            title: podcast.title,
                            body: "\(newest.title) is ready — ads scanned",
                            id: "proc-\(newest.id)"
                        )
                    }
                }
            }
        }
        await enforceRetention()
    }

    /// Overnight transcription: one episode at a time (§9.7), newest first,
    /// downloaded-but-untranscribed only. Scanning stays manual until the
    /// model earns trust.
    func performOvernightProcessing(_ task: BGProcessingTask?) async {
        defer { scheduleBackgroundWork() }
        await reloadLibrary()
        for podcast in library {
            guard let candidates = try? await episodes.episodes(podcastID: podcast.id, limit: 3)
            else { continue }
            for episode in candidates where localFileURL(for: episode) != nil {
                let has = (try? await transcripts.hasTranscript(episodeID: episode.id)) ?? false
                if !has {
                    await transcribeOnDevice(episode)
                    return   // one per wake; the scheduler calls us again
                }
            }
        }
        await sweepStaleScans()
    }

    /// §6.9 background sweep: when new patterns have been learned since an
    /// episode was scanned, unplayed transcribed episodes get a re-scan —
    /// overnight, on power, one per wake. Corrections never re-run; a
    /// re-scan cannot erase user-touched segments (repository invariant).
    private func sweepStaleScans() async {
        let newestPatternDate = try? await database.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(createdAt) FROM ad_patterns")
        }
        guard let newestPattern = newestPatternDate ?? nil else { return }

        for podcast in library {
            guard let candidates = try? await episodes.episodes(podcastID: podcast.id, limit: 3)
            else { continue }
            for episode in candidates where !episode.isPlayed {
                guard (try? await transcripts.hasTranscript(episodeID: episode.id)) ?? false
                else { continue }
                let lastScan = try? await database.read { db in
                    try Date.fetchOne(
                        db,
                        sql: "SELECT MAX(createdAt) FROM detected_segments WHERE episodeId = ?",
                        arguments: [episode.id]
                    )
                }
                guard let lastScan = lastScan ?? nil, lastScan < newestPattern else { continue }
                await scanForAds(episode)
                return   // one per wake, same battery courtesy as transcription
            }
        }
    }

    // MARK: - Teaching: mark an ad during playback (§6.4)

    /// Set when the listener has pressed "Ad starts here" and the end is
    /// pending. Media time, captured at the tap.
    private(set) var pendingAdStartMs: Int?

    func markAdStart() {
        pendingAdStartMs = player.mediaPositionMs
    }

    func cancelAdMark() {
        pendingAdStartMs = nil
    }

    /// Completes the mark: stores a confirmed manual segment, extracts the
    /// transcript text as a learned pattern scoped to the show, and logs the
    /// correction. The single highest-value input the system can receive —
    /// this exact text is what Stage 1 matches in every future episode.
    func markAdEnd() async {
        guard let episode = nowPlaying, let startMs = pendingAdStartMs else { return }
        let endMs = player.mediaPositionMs
        pendingAdStartMs = nil
        guard endMs > startMs + 1_000 else { return }

        let segment = DetectedSegment(
            episodeID: episode.id,
            startMs: startMs, endMs: endMs,
            kind: .ad,
            confidence: 1.0,
            provenance: .manual,
            rationale: "Marked during playback",
            userState: .confirmed
        )
        try? await segmentRepository.insert(segment)
        nowPlayingSegments.append(segment)

        try? await corrections.append(
            episodeID: episode.id, segmentID: segment.id,
            type: "markMissedAd", source: .explicit
        )

        // The learning step: the words inside the marked span become a pattern.
        if let transcript = try? await transcripts.transcript(episodeID: episode.id) {
            let text = transcript.segments
                .filter { $0.startMs < endMs && startMs < $0.endMs }
                .map(\.text)
                .joined(separator: " ")
            if text.split(separator: " ").count >= 8 {
                try? await patternRepository.insert(
                    AdPatternRecord(
                        podcastId: episode.podcastId,
                        text: text,
                        confirmCount: 1,
                        createdFrom: "markMissedAd"
                    )
                )
            }
        }
        await learnPosition(from: segment, episode: episode)
        captureFingerprint(for: segment, episode: episode)
    }

    /// Rejects a detected segment on the playing episode — "this is not an
    /// ad" (§6.4) — and refreshes the player's segment list.
    func rejectSegment(_ segment: DetectedSegment) async {
        guard let episode = nowPlaying else { return }
        await rejectSegment(segment, episode: episode)
        nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
    }

    // MARK: - Audio settings (A5.4)

    func applyAudioSettings() {
        let override = nowPlaying.map { overrides(for: $0.podcastId) }
        player.setRate(override?.speed ?? audioSettings.speed)
        player.setProcessing(audioSettings.resolvedDefaults)
        if let episode = nowPlaying {
            prepareTrimSilence(for: episode, localURL: localFileURL(for: episode))
        }
    }

    /// Loads or computes the episode's silence map off the main actor, then
    /// hands the gaps to the engine — if this episode is still the one
    /// playing by the time the analysis lands.
    private func prepareTrimSilence(for episode: EpisodeRecord, localURL: URL?) {
        guard audioSettings.trimSilence, let localURL else {
            player.setTrimSilence(gaps: [], enabled: false)
            return
        }
        let episodeID = episode.id
        Task.detached(priority: .utility) { [weak self] in
            let map: SilenceMap
            if let cached = SilenceMap.load(for: localURL) {
                map = cached
            } else if let computed = try? SilenceMap.analyze(fileURL: localURL) {
                try? computed.save(for: localURL)
                map = computed
            } else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.nowPlaying?.id == episodeID else { return }
                self.player.setTrimSilence(gaps: map.trimGaps, enabled: true)
            }
        }
    }

    /// The bug Cam hit: skip blocks were computed only at play() time, so the
    /// toggle changed nothing mid-episode. Flipping it now rebuilds the
    /// playing timeline immediately.
    func setAutoSkip(_ enabled: Bool) async {
        audioSettings.autoSkipAds = enabled
        guard let episode = nowPlaying else { return }
        var blocks: [SkipBlock] = []
        let effective = overrides(for: episode.podcastId).autoSkipAds ?? enabled
        if effective, let outcome = await gatedSegments(for: episode) {
            blocks = skipBlocks(from: outcome.autoSkippable)
        }
        player.updateTimeline(DisplayTimeline(
            mediaDurationMs: episode.durationMs ?? player.timeline.mediaDurationMs,
            blocks: blocks
        ))
    }

    // MARK: - Per-show pipeline steps (§9.2/§9.3, simplified per-show form)

    struct ShowPipelinePrefs: Codable, Hashable {
        /// After a new episode downloads, transcribe it automatically.
        var autoTranscribe: Bool = false
        /// After transcription, scan for ads automatically.
        var autoScan: Bool = false
    }

    func pipelinePrefs(for podcastID: Podcast.ID) -> ShowPipelinePrefs {
        guard let record = library.first(where: { $0.id == podcastID }),
              let json = record.playbackSettings?.data(using: .utf8),
              let combined = try? JSONDecoder().decode(CombinedShowPrefs.self, from: json)
        else { return ShowPipelinePrefs() }
        return combined.pipeline ?? ShowPipelinePrefs()
    }

    /// Playback overrides and pipeline prefs share the podcast row's settings
    /// column; this envelope keeps them from clobbering each other.
    struct CombinedShowPrefs: Codable, Hashable {
        var speed: Double?
        var autoSkipAds: Bool?
        var pipeline: ShowPipelinePrefs?
        /// The listener's free-text guidance to the ad classifier (§6.5) —
        /// "the host reads listener mail at the start, it is not an ad".
        var classifierNotes: String?
    }

    func classifierNotes(for podcastID: Podcast.ID) -> String? {
        loadCombinedPrefs(for: podcastID).classifierNotes
    }

    func saveClassifierNotes(_ notes: String, podcastID: Podcast.ID) async {
        var combined = loadCombinedPrefs(for: podcastID)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        combined.classifierNotes = trimmed.isEmpty ? nil : String(trimmed.prefix(300))
        await saveCombinedPrefs(combined, podcastID: podcastID)
    }

    func savePipelinePrefs(_ prefs: ShowPipelinePrefs, podcastID: Podcast.ID) async {
        var combined = loadCombinedPrefs(for: podcastID)
        combined.pipeline = prefs
        await saveCombinedPrefs(combined, podcastID: podcastID)
    }

    private func loadCombinedPrefs(for podcastID: Podcast.ID) -> CombinedShowPrefs {
        guard let record = library.first(where: { $0.id == podcastID }),
              let json = record.playbackSettings?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CombinedShowPrefs.self, from: json)
        else { return CombinedShowPrefs() }
        return decoded
    }

    private func saveCombinedPrefs(_ prefs: CombinedShowPrefs, podcastID: Podcast.ID) async {
        let json = (try? JSONEncoder().encode(prefs)).flatMap { String(data: $0, encoding: .utf8) }
        try? await podcasts.setPlaybackSettings(json, podcastID: podcastID)
        await reloadLibrary()
    }

    // MARK: - Notifications (§9.5)

    enum NotifyOn: String, Codable, CaseIterable {
        case never, newEpisode, downloaded, processed
    }

    func notifySetting(for podcastID: Podcast.ID) -> NotifyOn {
        guard let record = library.first(where: { $0.id == podcastID }),
              let raw = record.notificationSettingsRaw,
              let value = NotifyOn(rawValue: raw)
        else { return .never }
        return value
    }

    func setNotifySetting(_ value: NotifyOn, podcastID: Podcast.ID) async {
        if value != .never {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
        try? await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET notificationSettings = ? WHERE id = ?",
                arguments: [value.rawValue, podcastID]
            )
        }
        await reloadLibrary()
    }

    private func postNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Deletion (Cam: "no way to delete them")

    func deleteDownload(_ episode: EpisodeRecord) async {
        guard episode.id != nowPlaying?.id, let url = localFileURL(for: episode) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: SilenceMap.sidecarURL(for: url))
        try? await retention.markEvicted([episode.id])
    }

    func deleteTranscript(_ episode: EpisodeRecord) async {
        try? await transcripts.delete(episodeID: episode.id)
        try? await segmentRepository.replaceMachineSegments([], episodeID: episode.id)
    }

    /// Deletes any segment — machine or user-marked (Cam's request). Also
    /// clears it from the playing overlay immediately.
    func deleteSegment(_ segment: DetectedSegment) async {
        try? await segmentRepository.delete(segment.id)
        nowPlayingSegments.removeAll { $0.id == segment.id }
    }

    // MARK: - Waveform (seek-bar backdrop)

    /// Downsampled peak amplitudes for downloaded episodes, cached in memory.
    /// Streaming episodes have no local file, so the flat bar remains their
    /// fallback.
    private(set) var waveforms: [Episode.ID: [Float]] = [:]

    func loadWaveform(for episode: EpisodeRecord) async {
        guard waveforms[episode.id] == nil else { return }
        // The caller's record may be a snapshot from before a download
        // finished (the scan chain downloads mid-playback) — check the
        // database for the current file, not the stale copy.
        var resolved = localFileURL(for: episode)
        if resolved == nil, let fresh = try? await episodes.find(id: episode.id) {
            resolved = localFileURL(for: fresh)
        }
        guard let url = resolved else { return }
        let peaks = await Task.detached(priority: .userInitiated) {
            Self.computePeaks(url: url, bins: 160)
        }.value
        if !peaks.isEmpty {
            waveforms[episode.id] = peaks
        }
    }

    /// RMS loudness per bin, SAMPLED — seek to each bin and decode only half
    /// a second there, never the whole file. Measured: full decode of a
    /// 2-hour MP3 took 12.7s on an M-series Mac (minutes for a 4-hour file
    /// on the phone — the waveform "never appeared" because it genuinely
    /// hadn't finished); sampling produces a comparable picture in 0.21s.
    /// RMS rather than peak amplitude: peaks of mastered speech are
    /// 0.73–1.0 in every bin, which renders as a solid block.
    nonisolated private static func computePeaks(url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let totalFrames = file.length
        guard totalFrames > AVAudioFramePosition(bins) else { return [] }
        let framesPerBin = totalFrames / AVAudioFramePosition(bins)
        let format = file.processingFormat
        let sampleFrames = AVAudioFrameCount(
            min(Double(framesPerBin), format.sampleRate * 0.5)
        )
        guard sampleFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleFrames)
        else { return [] }

        var values: [Float] = []
        values.reserveCapacity(bins)
        for bin in 0..<bins {
            file.framePosition = AVAudioFramePosition(bin) * framesPerBin + framesPerBin / 2
            do { try file.read(into: buffer, frameCount: sampleFrames) }
            catch { values.append(0); continue }
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                values.append(0)
                continue
            }
            var sum = 0.0
            var count = 0
            var index = 0
            while index < Int(buffer.frameLength) {
                let value = Double(channel[index])
                sum += value * value
                count += 1
                index += 4
            }
            values.append(count > 0 ? Float((sum / Double(count)).squareRoot()) : 0)
        }

        // Stretch min…max to the full bar height with a gentle curve and a
        // floor, so quiet stretches read as valleys instead of vanishing.
        guard let lowest = values.min(), let highest = values.max(), highest > lowest
        else { return values }
        return values.map { value in
            let normalized = (value - lowest) / (highest - lowest)
            return 0.12 + 0.88 * pow(normalized, 0.7)
        }
    }

    // MARK: - Playlist management (user-facing)

    func createPlaylist(named name: String) async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? await playlistRepository.create(
            name: name,
            colorName: ["yellow", "brown", "orange", "blue"].randomElement(),
            iconName: "list.bullet"
        )
        await reloadLibrary()
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !playlist.isBuiltIn else { return }
        try? await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET name = ? WHERE id = ?",
                arguments: [trimmed, playlist.id]
            )
        }
        await reloadLibrary()
    }

    func deletePlaylist(_ playlist: Playlist) async {
        try? await playlistRepository.delete(playlist.id)
        await reloadLibrary()
    }

    func add(_ episode: EpisodeRecord, to playlist: Playlist) async {
        try? await playlistRepository.append(episodeID: episode.id, to: playlist.id)
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
        // Only genuinely NEW shows inherit the followed-class defaults —
        // re-subscribing (Discover follow of an OPML show, repeat import)
        // must never silently rewrite a show's customized settings.
        if !library.contains(where: { $0.id == record.id }) {
            await applyDefaults(showDefaults.followed, to: record.id)
        }
        await reloadLibrary()
    }

    @discardableResult
    func refreshReturningNew(_ podcast: PodcastRecord) async -> [String] {
        await refresh(podcast)
        return lastInsertedGuids
    }

    private var lastInsertedGuids: [String] = []

    /// Refreshes one show, using conditional GET so an unchanged feed is a
    /// single cheap round trip.
    func refresh(_ podcast: PodcastRecord) async {
        lastInsertedGuids = []
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
        lastInsertedGuids = (try? await episodes.upsert(inputs, podcastID: podcastID)) ?? []
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
        nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []

        // Auto-skip is opt-in while the model is unproven: first field test
        // found five confident false positives and zero real ads. Segments are
        // always *drawn* on the seek bar; skipping them is the user's call.
        var blocks: [SkipBlock] = []
        let skipEnabled = overrides(for: episode.podcastId).autoSkipAds ?? audioSettings.autoSkipAds
        if skipEnabled, let outcome = await gatedSegments(for: episode) {
            blocks = skipBlocks(from: outcome.autoSkippable)
        }
        startPlayback(episode, startAtMs: startAtMs, blocks: blocks)
    }

    /// §5.5: segments sharing a chunk are one ad break — one block, one jump,
    /// no skip-play-skip stutter through a stack of back-to-back spots.
    private func skipBlocks(from segments: [DetectedSegment]) -> [SkipBlock] {
        var byChunk: [UUID: [DetectedSegment]] = [:]
        var singles: [DetectedSegment] = []
        for segment in segments {
            if let chunk = segment.chunkID {
                byChunk[chunk, default: []].append(segment)
            } else {
                singles.append(segment)
            }
        }
        var blocks = singles.map {
            SkipBlock(startMs: $0.startMs, endMs: $0.endMs, segmentIDs: [$0.id])
        }
        for group in byChunk.values {
            blocks.append(SkipBlock(
                startMs: group.map(\.startMs).min() ?? 0,
                endMs: group.map(\.endMs).max() ?? 0,
                segmentIDs: group.map(\.id)
            ))
        }
        return blocks.sorted { $0.startMs < $1.startMs }
    }

    /// Segments of the playing episode, for the seek-bar overlay.
    private(set) var nowPlayingSegments: [DetectedSegment] = []

    func refreshNowPlayingSegments() async {
        guard let episode = nowPlaying else { return }
        nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
    }

    /// Media playback, not a sound effect: without the .playback category,
    /// audio follows the ringer switch and dies when the screen locks — the
    /// exact behavior Cam hit on the first real listen.
    ///
    /// Category only. Activation lives in `activateAudioSession`, called from
    /// the engine's onWillPlay hook: activating is what interrupts every
    /// other app's audio, and doing it at launch (session restore loads the
    /// last episode paused) silenced whatever Cam was listening to.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Wired once: engine callbacks for persistence, lock screen, and the
    /// queue session. Idempotent.
    private var callbacksInstalled = false
    private var lastSavedPositionMs = 0

    private func installPlaybackCallbacks() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

        player.onWillPlay = { [weak self] in
            self?.activateAudioSession()
        }

        // §6.8 implicit signals: weak evidence, logged but never acted on
        // alone. A long manual fast-forward is a "maybe I just skipped an ad
        // you missed" hint; a quick rewind right after an auto-skip is a
        // "that skip felt wrong" hint.
        player.onUserSeek = { [weak self] fromMs, toMs in
            guard let self, let episode = self.nowPlaying else { return }
            let episodeID = episode.id
            if toMs - fromMs > 20_000 {
                Task {
                    try? await self.corrections.recordSignal(
                        episodeID: episodeID, kind: "manualFastForward", positionMs: fromMs
                    )
                }
            } else if fromMs - toMs > 5_000,
                      let skip = self.player.lastSkip,
                      Date().timeIntervalSince(skip.occurredAt) < 30 {
                Task {
                    try? await self.corrections.recordSignal(
                        episodeID: episodeID, kind: "rewindAfterSkip", positionMs: toMs
                    )
                }
            }
        }

        player.onPositionTick = { [weak self] positionMs in
            guard let self, let episode = self.nowPlaying else { return }
            self.updateNowPlayingInfo()
            // Persist every ~5 seconds, not every tick.
            guard abs(positionMs - self.lastSavedPositionMs) >= 5_000 else { return }
            self.lastSavedPositionMs = positionMs
            Task {
                try? await self.episodes.savePosition(
                    episodeID: episode.id, positionMs: positionMs, durationMs: episode.durationMs
                )
            }
        }

        player.onPlaybackEnded = { [weak self] in
            guard let self else { return }
            Task { await self.advanceQueue() }
        }

        installRemoteCommands()
    }

    // MARK: - End-of-episode review (A3)

    /// Queued when an episode finishes with unreviewed detections — the batch
    /// version of the undo affordance, catching corrections the listener
    /// didn't make in the moment.
    struct EpisodeReview: Identifiable {
        var id: Episode.ID { episode.id }
        var episode: EpisodeRecord
        var segments: [DetectedSegment]
    }

    var pendingReview: EpisodeReview?

    /// Episode finished: mark it played, drop it from Up Next, start the next
    /// queued episode. Listening is a session (ux-architecture invariant 2).
    private func advanceQueue() async {
        if case .endOfEpisode = sleepTimer {
            sleepTimer = .off
            player.pause()
            return
        }
        if let finished = nowPlaying {
            try? await episodes.setPlayed(true, episodeID: finished.id)
            if let queue = playlists.first(where: { $0.name == Playlist.upNextName }) {
                try? await playlistRepository.remove(episodeID: finished.id, from: queue.id)
            }
            let unreviewed = ((try? await segmentRepository.segments(episodeID: finished.id)) ?? [])
                .filter { $0.userState == .unreviewed }
            if !unreviewed.isEmpty {
                pendingReview = EpisodeReview(episode: finished, segments: unreviewed)
            }
        }
        guard let queue = playlists.first(where: { $0.name == Playlist.upNextName }),
              let next = (try? await playlistRepository.episodes(in: queue))?.first
        else {
            nowPlaying = nil
            return
        }
        play(next)
    }

    // MARK: - Lock screen / Control Center (§10.5)

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player.play(); self?.updateNowPlayingInfo(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause(); self?.updateNowPlayingInfo(); return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.seek(toMediaMs: self.player.mediaPositionMs - 15_000)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.seek(toMediaMs: self.player.mediaPositionMs + 30_000)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            // The lock-screen scrubber speaks display time (§11.4).
            self.player.seek(toDisplayMs: Int(positionEvent.positionTime * 1000))
            return .success
        }
    }

    /// Artwork for the lock screen, fetched once per episode and cached.
    private var lockScreenArtwork: (episodeID: Episode.ID, artwork: MPMediaItemArtwork)?

    private func loadLockScreenArtwork(for episode: EpisodeRecord) {
        guard lockScreenArtwork?.episodeID != episode.id else { return }
        let urlString = episode.imageURL
            ?? library.first { $0.id == episode.podcastId }?.imageURL
        guard let urlString, let url = URL(string: urlString) else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return }
            // The artwork's image-provider closure is invoked by MediaPlayer
            // on ITS queue. Built inline here it inherits main-actor isolation
            // and the runtime's executor check traps (SIGTRAP on launch, seen
            // in the field). Construct it in a nonisolated context instead.
            let artwork = Self.makeArtwork(image)
            self?.lockScreenArtwork = (episode.id, artwork)
            self?.updateNowPlayingInfo()
        }
    }

    /// Nonisolated on purpose — see loadLockScreenArtwork.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Elapsed time on the lock screen comes from the display timeline, so it
    /// stays coherent across skips (§10.5, §11.4).
    private func updateNowPlayingInfo() {
        guard let episode = nowPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyPlaybackDuration: Double(player.displayDurationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(player.displayPositionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? audioSettings.speed : 0,
        ]
        if let show = library.first(where: { $0.id == episode.podcastId })?.title {
            info[MPMediaItemPropertyArtist] = show
        }
        if let cached = lockScreenArtwork, cached.episodeID == episode.id {
            info[MPMediaItemPropertyArtwork] = cached.artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Restores the last session paused, so the mini player is present from
    /// launch and "continue where I was" is one tap (ux invariant 1 + 3).
    func restoreSession() async {
        guard nowPlaying == nil,
              let idString = UserDefaults.standard.string(forKey: "lastEpisodeID"),
              let uuid = UUID(uuidString: idString),
              let episode = try? await episodes.find(id: Episode.ID(uuid)),
              !episode.isPlayed
        else { return }
        nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
        startPlayback(episode, startAtMs: episode.playbackPositionMs, blocks: [], autoplay: false)
    }

    /// Plays the episode's video rendition through the shared engine — same
    /// timeline, same skip blocks, same position persistence (§8.3).
    func playVideo(_ episode: EpisodeRecord) async {
        guard let url = videoURL(for: episode) else { return }
        nowPlayingSegments = (try? await segmentRepository.segments(episodeID: episode.id)) ?? []
        var blocks: [SkipBlock] = []
        let skipEnabled = overrides(for: episode.podcastId).autoSkipAds ?? audioSettings.autoSkipAds
        if skipEnabled, let outcome = await gatedSegments(for: episode) {
            blocks = skipBlocks(from: outcome.autoSkippable)
        }
        startPlayback(
            episode, startAtMs: episode.playbackPositionMs, blocks: blocks, overrideURL: url
        )
    }

    private func startPlayback(
        _ episode: EpisodeRecord, startAtMs: Int?, blocks: [SkipBlock], autoplay: Bool = true,
        overrideURL: URL? = nil
    ) {
        configureAudioSession()
        installPlaybackCallbacks()
        UserDefaults.standard.set(episode.id.rawValue.uuidString, forKey: "lastEpisodeID")
        lastSavedPositionMs = startAtMs ?? episode.playbackPositionMs
        // A downloaded copy always beats streaming: instant start, works
        // offline, and it is the only source Smart Speed can pre-analyze.
        // A video override (§8.3) beats both — the caller picked a rendition.
        let localURL = overrideURL != nil ? nil : localFileURL(for: episode)
        guard let url = overrideURL ?? localURL ?? {
            guard let renditionData = episode.renditions?.data(using: .utf8),
                  let renditions = try? JSONDecoder().decode([Rendition].self, from: renditionData)
            else { return nil }
            return renditions.first(where: \.isPrimaryEnclosure)?.sources.first
                ?? renditions.first?.sources.first
        }() else { return }

        let timeline = DisplayTimeline(
            mediaDurationMs: episode.durationMs ?? 0,
            blocks: blocks
        )
        player.load(url: url, timeline: timeline, startAtMs: startAtMs ?? episode.playbackPositionMs)
        // Per-show speed override beats the global (§10.4).
        let override = overrides(for: episode.podcastId)
        player.setRate(override.speed ?? audioSettings.speed)
        player.setProcessing(audioSettings.resolvedDefaults)
        prepareTrimSilence(for: episode, localURL: localURL)
        if autoplay {
            player.play()
        }
        nowPlaying = episode
        loadLockScreenArtwork(for: episode)
        updateNowPlayingInfo()
    }
}
