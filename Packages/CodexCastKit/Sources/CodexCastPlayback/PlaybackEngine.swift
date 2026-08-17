import AVFoundation
import CodexCastCore
import Foundation
import Observation

/// What just happened, so the UI can show "Skipped 2 ads · 68s" with an Undo
/// affordance (§11.2).
public struct SkipEvent: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var block: SkipBlock
    public var occurredAt: Date

    public init(id: UUID = UUID(), block: SkipBlock, occurredAt: Date = Date()) {
        self.id = id
        self.block = block
        self.occurredAt = occurredAt
    }

    /// The undo affordance persists for eight seconds after the skip.
    public static let undoWindow: TimeInterval = 8
}

/// Holds `AVPlayer` time-observer tokens.
///
/// Exists so the tokens can be removed in a nonisolated `deinit`. Leaving them
/// attached would keep the closures — and the engine — alive after the player
/// screen is gone.
private final class ObserverBox: @unchecked Sendable {
    private let player: AVPlayer
    var boundary: Any?
    var periodic: Any?
    var trimBoundary: Any?

    init(player: AVPlayer) {
        self.player = player
    }

    func removeTrim() {
        if let trimBoundary {
            player.removeTimeObserver(trimBoundary)
            self.trimBoundary = nil
        }
    }

    func removeAll() {
        if let boundary {
            player.removeTimeObserver(boundary)
            self.boundary = nil
        }
        if let periodic {
            player.removeTimeObserver(periodic)
            self.periodic = nil
        }
        removeTrim()
    }

    deinit {
        removeAll()
    }
}

/// Drives `AVPlayer` and applies skip blocks.
///
/// Identical for audio and video renditions: the same boundary observers on the
/// same timeline, because the renditions are the same content (§8.3, §11.1).
@MainActor
@Observable
public final class PlaybackEngine {
    public private(set) var timeline: DisplayTimeline
    public private(set) var isPlaying = false
    /// True media position. Everything the user sees is derived from this via
    /// `timeline`, never tracked separately (§11.4).
    public private(set) var mediaPositionMs: Int = 0
    /// The most recent skip, cleared once its undo window expires.
    public private(set) var lastSkip: SkipEvent?
    /// Set while the user is dragging the scrubber. Skipping is suspended
    /// throughout — seeking out from under someone's finger is hostile (§11.2).
    public var isScrubbing = false

    /// Called when a block is skipped, so corrections and playback signals can
    /// be recorded without this type knowing about the database.
    public var onSkip: (@MainActor (SkipEvent) -> Void)?
    /// Called when the user undoes a skip. §11.2 calls this the single most
    /// important correction entry point in the app: one tap, at exactly the
    /// moment the user noticed.
    public var onUndoSkip: (@MainActor (SkipEvent) -> Void)?
    /// Fires roughly twice a second with the current media position — the
    /// hook position persistence hangs off, so progress survives relaunch.
    public var onPositionTick: (@MainActor (Int) -> Void)?
    /// Fires when the loaded item plays to its end — the hook queue
    /// advancement hangs off. Listening is a session, not one-off plays.
    public var onPlaybackEnded: (@MainActor () -> Void)?
    /// Fires on USER seeks only (never the engine's own skip/undo/glide
    /// seeks) with (fromMs, toMs) — the §6.8 implicit-signal tap: a long
    /// manual fast-forward hints at a missed ad; a rewind right after a
    /// skip hints the skip was wrong.
    public var onUserSeek: (@MainActor (Int, Int) -> Void)?
    /// Set while the engine itself is seeking, so those don't count.
    private var isProgrammaticSeek = false

    /// Fires just before playback actually starts — where the app activates
    /// the audio session. Activation interrupts every other app's audio, so
    /// it must happen HERE and never merely on load: restoring the last
    /// episode paused at launch must not silence whatever the user is
    /// listening to.
    public var onWillPlay: (@MainActor () -> Void)?

    private let player: AVPlayer
    /// Observer tokens live outside the actor so they can be removed from
    /// `deinit`, which is nonisolated and cannot touch main-actor state.
    private let observers: ObserverBox

    /// The wrapped player, for surfaces that must render it directly —
    /// the inline video layer (§8.3). Same player, same timeline, same
    /// skips; renditions are the same content.
    public var underlyingPlayer: AVPlayer { player }

    /// Whether the LOADED item actually carries video — asked of the asset,
    /// not guessed from the feed, because a downloaded file from a video
    /// feed is video whatever the rendition list claimed.
    public private(set) var hasVideo = false
    /// Guards against a slow track query landing after the next episode.
    private var videoProbeToken = UUID()

    /// Bumped on every `load`. Observer callbacks capture the value current
    /// when they were installed: a block already queued for the PREVIOUS
    /// item runs after the next episode is loaded, and without this it
    /// reports the old item's position as the new episode's — which wrote a
    /// finished episode's end-position onto its successor.
    private var loadGeneration = 0

    // MARK: DSP (§10.1/§10.4) — Voice Boost, mono, normalization via audio tap

    private let tapController = AudioTapController()
    private var processing = PlaybackSettings.globalDefaults

    /// Applies (or re-applies) the processing chain. Safe mid-playback: live
    /// taps read the shared state, so the change lands within a buffer.
    public func setProcessing(_ settings: ResolvedPlaybackSettings) {
        processing = settings
        tapController.update(settings)
    }

    // MARK: Smart Speed (§10.2) — glide the rate up through silences

    /// Silence gaps of the loaded media, from its `SilenceMap`.
    private var trimGaps: [SilenceDetector.Gap] = []
    private var trimEnabled = false
    /// Wall-clock milliseconds saved by trimming, this app-session. Feed for
    /// the eventual stats screen; also proof the feature is doing something.
    public private(set) var timeSavedByTrimMs: Int = 0

    /// Minimum quiet time between two trim hops. A one-syllable sentence
    /// between two pauses would otherwise sit squeezed between two seek
    /// stalls and barely be heard (field report); after any hop, the next
    /// pause plays out naturally.
    private static let trimCooldownMs = 2_500
    private var lastTrimHopAtMediaMs = -1_000_000

    /// Kept clear of BOTH edges of every gap. The energy detector counts a
    /// sentence's trailing fade-out as "silence", so gliding edge-to-edge
    /// whipped sentence tails through at 3x — heard in the field as
    /// "sentences getting cut off". Only the interior is ever sped up.
    private static let trimEdgePaddingMs = 220

    public func setTrimSilence(gaps: [SilenceDetector.Gap], enabled: Bool) {
        trimGaps = gaps
            .map {
                SilenceDetector.Gap(
                    startMs: $0.startMs + Self.trimEdgePaddingMs,
                    endMs: $0.endMs - Self.trimEdgePaddingMs
                )
            }
            .filter { $0.durationMs >= 250 }
            .sorted { $0.startMs < $1.startMs }
        trimEnabled = enabled && !trimGaps.isEmpty
        configureTrimObservers()
        applyTrimRate()
    }

    public init(player: AVPlayer = AVPlayer(), timeline: DisplayTimeline = DisplayTimeline(mediaDurationMs: 0)) {
        self.player = player
        self.timeline = timeline
        self.observers = ObserverBox(player: player)
        // Boundary observers are cheap and exact; polling a timer would both
        // burn battery and miss the boundary (§11.1).
        configureObservers()
    }

    // MARK: - Loading

    public func load(url: URL, timeline: DisplayTimeline, startAtMs: Int = 0) {
        let item = AVPlayerItem(url: url)
        loadGeneration += 1
        player.replaceCurrentItem(with: item)
        hasVideo = false
        let token = UUID()
        videoProbeToken = token
        Task { [weak self] in
            let tracks = try? await item.asset.loadTracks(withMediaType: .video)
            guard let self, self.videoProbeToken == token else { return }
            self.hasVideo = !(tracks ?? []).isEmpty
        }
        tapController.attach(to: item)
        tapController.update(processing)
        // The old episode's silence map means nothing here; the caller
        // provides a new one via setTrimSilence once it is analyzed.
        trimGaps = []
        trimEnabled = false
        self.timeline = timeline
        seek(toMediaMs: startAtMs)
        configureObservers()

        // Replace, never accumulate: reassigning without removing left one
        // live observer per episode played.
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let generation = loadGeneration
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                self.isPlaying = false
                self.onPlaybackEnded?()
            }
        }
    }

    private var endObserver: (any NSObjectProtocol)?

    /// Replaces the skip blocks mid-episode, which happens when detection
    /// finishes ahead of the playhead on the just-in-time path (§9.3).
    public func updateTimeline(_ timeline: DisplayTimeline) {
        self.timeline = timeline
        configureObservers()
    }

    // MARK: - Transport

    public func play() {
        onWillPlay?()
        player.play()
        isPlaying = true
        applyTrimRate()
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func setRate(_ speed: Double) {
        player.defaultRate = Float(PlaybackSpeed.normalize(speed))
        if isPlaying {
            player.rate = player.defaultRate
        }
        applyTrimRate()
    }

    /// Seeks in true media time.
    ///
    /// Tolerances are zero deliberately: a tolerant seek lands mid-ad or clips
    /// content, and both are immediately noticeable (§11.1).
    public func seek(toMediaMs mediaMs: Int) {
        let clamped = max(0, min(mediaMs, timeline.mediaDurationMs))
        if !isProgrammaticSeek {
            onUserSeek?(mediaPositionMs, clamped)
        }
        mediaPositionMs = clamped
        player.seek(
            to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        applyTrimRate()
    }

    /// Seeks in the timeline the user sees. Never lands inside a skipped region.
    public func seek(toDisplayMs displayMs: Int) {
        seek(toMediaMs: timeline.mediaMs(forDisplay: displayMs))
    }

    // MARK: - Derived, user-facing position

    public var displayPositionMs: Int {
        timeline.displayMs(forMedia: mediaPositionMs)
    }

    public var displayDurationMs: Int {
        timeline.displayDurationMs
    }

    // MARK: - Skipping

    /// Skips the block containing the current position, if any.
    private func skipIfNeeded() {
        guard !isScrubbing else { return }
        guard let block = timeline.block(at: mediaPositionMs) else { return }

        let event = SkipEvent(block: block)
        isProgrammaticSeek = true
        seek(toMediaMs: block.endMs)
        isProgrammaticSeek = false
        lastSkip = event
        onSkip?(event)
    }

    /// Returns to the start of the last skipped block and reports it, so the
    /// caller can mark the constituent segments rejected and route corrections.
    public func undoLastSkip() {
        guard let event = lastSkip else { return }
        guard Date().timeIntervalSince(event.occurredAt) <= SkipEvent.undoWindow else {
            lastSkip = nil
            return
        }

        // Drop the block first, or seeking back into it would skip again.
        let remaining = timeline.blocks.filter { $0.id != event.block.id }
        updateTimeline(DisplayTimeline(mediaDurationMs: timeline.mediaDurationMs, blocks: remaining))

        isProgrammaticSeek = true
        seek(toMediaMs: event.block.startMs)
        isProgrammaticSeek = false
        lastSkip = nil
        onUndoSkip?(event)
    }

    // MARK: - Observers

    private func configureObservers() {
        observers.removeAll()
        defer { configureTrimObservers() }
        let generation = loadGeneration

        observers.periodic = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 500, timescale: 1000),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                self.mediaPositionMs = Int(time.seconds * 1000)
                self.onPositionTick?(self.mediaPositionMs)
                if Date().timeIntervalSince(self.lastSkip?.occurredAt ?? .distantPast) > SkipEvent.undoWindow {
                    self.lastSkip = nil
                }
            }
        }

        let boundaries = timeline.boundaryTimesMs
        guard !boundaries.isEmpty else { return }

        observers.boundary = player.addBoundaryTimeObserver(
            forTimes: boundaries.map { NSValue(time: CMTime(value: CMTimeValue($0), timescale: 1000)) },
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                self.mediaPositionMs = Int(self.player.currentTime().seconds * 1000)
                self.skipIfNeeded()
            }
        }
    }

    // MARK: - Silence trimming

    /// One boundary time at each gap start — the hop happens there, so the
    /// same exactness argument as ad skipping (§11.1), and far cheaper than
    /// polling.
    private func configureTrimObservers() {
        observers.removeTrim()
        guard trimEnabled else { return }

        // An hour of conversation can carry over a thousand gaps; keep the
        // longest if the count gets silly, they hold most of the win.
        var gaps = trimGaps
        if gaps.count > 1500 {
            gaps = gaps.sorted { $0.durationMs > $1.durationMs }.prefix(1500)
                .sorted { $0.startMs < $1.startMs }
        }

        let times = gaps.map {
            NSValue(time: CMTime(value: CMTimeValue($0.startMs), timescale: 1000))
        }
        guard !times.isEmpty else { return }

        observers.trimBoundary = player.addBoundaryTimeObserver(
            forTimes: times, queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mediaPositionMs = Int(self.player.currentTime().seconds * 1000)
                self.applyTrimRate()
            }
        }
    }

    private func trimGap(at mediaMs: Int) -> SilenceDetector.Gap? {
        // Sorted; a linear scan with early exit is fine at this size and this
        // call rate (gap starts + seeks, not per-frame).
        for gap in trimGaps {
            if gap.startMs > mediaMs { return nil }
            if mediaMs < gap.endMs { return gap }
        }
        return nil
    }

    /// Hops over a silent interior in one exact seek — NO rate changes.
    ///
    /// The first implementation glided the rate up through silences; every
    /// entry and exit re-ran the pitch-corrector and the transitions were
    /// audible ("weird jittering", field-confirmed by toggling the feature).
    /// A seek that starts and lands 220ms inside confirmed silence has
    /// nothing audible to glitch: the pause just gets shorter. Same proven
    /// machinery as ad skips. Name kept so call sites read unchanged.
    private func applyTrimRate() {
        guard isPlaying, trimEnabled, !isScrubbing, !isProgrammaticSeek else { return }
        guard let gap = trimGap(at: mediaPositionMs),
              // Inside a skip block the skip observer owns the playhead.
              timeline.block(at: mediaPositionMs) == nil
        else { return }

        let remainingMs = gap.endMs - mediaPositionMs
        guard remainingMs > 100 else { return }
        // Cooldown in MEDIA time so seeks and speed changes can't confuse it.
        guard abs(mediaPositionMs - lastTrimHopAtMediaMs) > Self.trimCooldownMs else { return }
        lastTrimHopAtMediaMs = gap.endMs
        isProgrammaticSeek = true
        seek(toMediaMs: gap.endMs)
        isProgrammaticSeek = false

        let base = max(0.5, Double(player.defaultRate))
        timeSavedByTrimMs += Int(Double(remainingMs) / base)
    }
}
