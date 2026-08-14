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
        patternRepository = AdPatternRepository(database: database)
        corrections = CorrectionRepository(database: database)
        chapters = ChapterRepository(database: database)
        positionRules = PositionRuleRepository(database: database)
        calibration = CalibrationRepository(database: database)
        sponsors = SponsorRepository(database: database)
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
                try? FileManager.default.removeItem(atPath: eviction.localPath)
                try? FileManager.default.removeItem(
                    at: SilenceMap.sidecarURL(for: URL(fileURLWithPath: eviction.localPath))
                )
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
        guard var transcript = try? await transcripts.transcript(episodeID: episode.id) else {
            scanState[episode.id] = .unavailable("Transcribe the episode first.")
            return
        }

        // A1: a feed transcript's timestamps must be verified against the
        // audio we actually downloaded before detection trusts them — a
        // transcript made from the ad-free master runs minutes early after
        // dynamic insertion, and it is silent about exactly the ads we're
        // looking for. Three 20s samples, once per episode.
        if transcript.source == .podcasting20,
           let path = episode.localPath, FileManager.default.fileExists(atPath: path),
           !((try? await transcripts.isDriftChecked(episodeID: episode.id)) ?? true) {
            let engine = TranscriptionEngine()
            let audioURL = URL(fileURLWithPath: path)
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

        let context = ClassificationContext(
            showName: showName,
            knownSponsors: hints.map(\.name),
            negativeExemplars: exemplars,
            showNotes: loadCombinedPrefs(for: episode.podcastId).classifierNotes
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

        // §5.7: calibrate the model's self-reported scores against the
        // listener's own correction history — or, when the model reports the
        // same number for everything, fall back to how many overlapping
        // windows agreed.
        let calibrator = ConfidenceCalibrator(bins: (try? await calibration.bins()) ?? [])
        let recentRaw = (try? await calibration.recentModelRawConfidences()) ?? []
        let degenerate = ConfidenceCalibrator.isDegenerate(
            recentRawConfidences: recentRaw + findings.map(\.confidence)
        )

        // Snap, dedupe, gate — the same post-processing the harness uses.
        for finding in TranscriptWindower.deduplicate(findings) {
            guard let start = transcript.nearestBoundary(toMs: finding.startMs),
                  let end = transcript.nearestBoundary(toMs: finding.endMs),
                  end > start,
                  // Sub-5s output is noise (a "0:51–0:51 sponsor read" was
                  // stored on the first device run); the gate floor applies
                  // at storage, not just playback.
                  end - start >= 5_000
            else { continue }
            let overlapsPattern = segments.contains { $0.overlaps(startMs: start, endMs: end) }
            guard !overlapsPattern else { continue }

            // §6.2: a sponsor the model named becomes (or joins) a registry
            // entity, so the same sponsor on a different show is recognized.
            var sponsorID: UUID?
            if let sponsorName = finding.sponsor, !sponsorName.isEmpty {
                sponsorID = try? await sponsors.findOrCreate(name: sponsorName)
            }

            let raw = finding.confidence
            let confidence: Double
            if degenerate {
                let possible = windows.filter { window in
                    guard let first = window.cues.first, let last = window.cues.last else { return false }
                    return first.startMs < end && last.endMs > start
                }.count
                confidence = ConfidenceCalibrator.agreementConfidence(
                    agreeing: finding.agreementCount, possible: possible
                )
            } else if calibrator.hasHistory(stage: "onDeviceModel") {
                confidence = calibrator.calibrated(stage: "onDeviceModel", rawConfidence: raw)
            } else {
                confidence = min(0.98, raw)
            }

            segments.append(DetectedSegment(
                episodeID: episode.id,
                startMs: start, endMs: end,
                kind: finding.kind,
                confidence: confidence,
                rawConfidence: raw,
                provenance: .onDeviceModel(windowIndex: 0, modelTier: "afm-device"),
                rationale: finding.rationale,
                sponsorID: sponsorID
            ))
        }

        // Stage 3 (§5.4): snap machine boundaries to real silence in the
        // audio. Transcript boundaries wobble by a sentence; a skip that cuts
        // mid-word is instantly noticeable. Uses the same silence map Smart
        // Speed keeps, computing it here if playback hasn't yet.
        if let path = episode.localPath, FileManager.default.fileExists(atPath: path) {
            let audioURL = URL(fileURLWithPath: path)
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
                  newest.localPath == nil,
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
            for episode in candidates where episode.localPath != nil {
                let has = (try? await transcripts.hasTranscript(episodeID: episode.id)) ?? false
                if !has {
                    await transcribeOnDevice(episode)
                    return   // one per wake; the scheduler calls us again
                }
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
            let localURL = episode.localPath.flatMap { path in
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
            prepareTrimSilence(for: episode, localURL: localURL)
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
                self.player.setTrimSilence(gaps: map.gaps, enabled: true)
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
            blocks = outcome.autoSkippable.map {
                SkipBlock(startMs: $0.startMs, endMs: $0.endMs, segmentIDs: [$0.id])
            }
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
        guard let path = episode.localPath, episode.id != nowPlaying?.id else { return }
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(
            at: SilenceMap.sidecarURL(for: URL(fileURLWithPath: path))
        )
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
        guard waveforms[episode.id] == nil,
              let path = episode.localPath,
              FileManager.default.fileExists(atPath: path)
        else { return }
        let url = URL(fileURLWithPath: path)
        let peaks = await Task.detached(priority: .utility) {
            Self.computePeaks(url: url, bins: 160)
        }.value
        if !peaks.isEmpty {
            waveforms[episode.id] = peaks
        }
    }

    nonisolated private static func computePeaks(url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = Int(file.length)
        guard frameCount > bins else { return [] }
        let framesPerBin = frameCount / bins
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBin)
        ) else { return [] }

        var peaks: [Float] = []
        peaks.reserveCapacity(bins)
        for _ in 0..<bins {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerBin)) }
            catch { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            var peak: Float = 0
            let length = Int(buffer.frameLength)
            // Stride: this is a picture, not a measurement.
            var index = 0
            while index < length {
                let value = abs(channel[index])
                if value > peak { peak = value }
                index += 32
            }
            peaks.append(peak)
        }
        let maximum = peaks.max() ?? 1
        return maximum > 0 ? peaks.map { $0 / maximum } : peaks
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
            blocks = outcome.autoSkippable.map { segment in
                SkipBlock(startMs: segment.startMs, endMs: segment.endMs, segmentIDs: [segment.id])
            }
        }
        startPlayback(episode, startAtMs: startAtMs, blocks: blocks)
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
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
    }

    /// Wired once: engine callbacks for persistence, lock screen, and the
    /// queue session. Idempotent.
    private var callbacksInstalled = false
    private var lastSavedPositionMs = 0

    private func installPlaybackCallbacks() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

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

    private func startPlayback(
        _ episode: EpisodeRecord, startAtMs: Int?, blocks: [SkipBlock], autoplay: Bool = true
    ) {
        configureAudioSession()
        installPlaybackCallbacks()
        UserDefaults.standard.set(episode.id.rawValue.uuidString, forKey: "lastEpisodeID")
        lastSavedPositionMs = startAtMs ?? episode.playbackPositionMs
        // A downloaded copy always beats streaming: instant start, works
        // offline, and it is the only source Smart Speed can pre-analyze.
        let localURL = episode.localPath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let url = localURL ?? {
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
