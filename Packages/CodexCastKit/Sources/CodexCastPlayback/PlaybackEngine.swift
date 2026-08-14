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

    private let player: AVPlayer
    /// Observer tokens live outside the actor so they can be removed from
    /// `deinit`, which is nonisolated and cannot touch main-actor state.
    private let observers: ObserverBox

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
    /// The gap the playhead is currently speeding through, if any.
    private var activeTrimGap: SilenceDetector.Gap?
    /// Wall-clock milliseconds saved by trimming, this app-session. Feed for
    /// the eventual stats screen; also proof the feature is doing something.
    public private(set) var timeSavedByTrimMs: Int = 0

    /// How much faster to run inside a silence. A glide, not a cut: pitch is
    /// preserved by the player's time-domain stretcher and there is nothing
    /// to clip because the region is silent.
    private static let trimMultiplier = 1.75
    private static let trimRateCap = 3.0

    public func setTrimSilence(gaps: [SilenceDetector.Gap], enabled: Bool) {
        trimGaps = gaps.sorted { $0.startMs < $1.startMs }
        trimEnabled = enabled && !gaps.isEmpty
        activeTrimGap = nil
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
        player.replaceCurrentItem(with: item)
        tapController.attach(to: item)
        tapController.update(processing)
        // The old episode's silence map means nothing here; the caller
        // provides a new one via setTrimSilence once it is analyzed.
        trimGaps = []
        trimEnabled = false
        activeTrimGap = nil
        self.timeline = timeline
        seek(toMediaMs: startAtMs)
        configureObservers()

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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
        // The base changed under the glide; recompute from scratch.
        activeTrimGap = nil
        applyTrimRate()
    }

    /// Seeks in true media time.
    ///
    /// Tolerances are zero deliberately: a tolerant seek lands mid-ad or clips
    /// content, and both are immediately noticeable (§11.1).
    public func seek(toMediaMs mediaMs: Int) {
        let clamped = max(0, min(mediaMs, timeline.mediaDurationMs))
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
        seek(toMediaMs: block.endMs)
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

        seek(toMediaMs: event.block.startMs)
        lastSkip = nil
        onUndoSkip?(event)
    }

    // MARK: - Observers

    private func configureObservers() {
        observers.removeAll()
        defer { configureTrimObservers() }

        observers.periodic = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 500, timescale: 1000),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
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
                guard let self else { return }
                self.mediaPositionMs = Int(self.player.currentTime().seconds * 1000)
                self.skipIfNeeded()
            }
        }
    }

    // MARK: - Silence trimming

    /// One boundary time at each gap edge, so the glide starts and ends
    /// exactly where the silence does — the same exactness argument as ad
    /// skipping (§11.1), and far cheaper than polling.
    private func configureTrimObservers() {
        observers.removeTrim()
        guard trimEnabled else { return }

        // An hour of conversation can carry over a thousand gap edges; keep
        // the longest gaps if the count gets silly, they hold most of the win.
        var gaps = trimGaps
        if gaps.count > 1500 {
            gaps = gaps.sorted { $0.durationMs > $1.durationMs }.prefix(1500)
                .sorted { $0.startMs < $1.startMs }
        }

        let times = gaps.flatMap { [$0.startMs, $0.endMs] }
            .map { NSValue(time: CMTime(value: CMTimeValue($0), timescale: 1000)) }
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
        // call rate (gap edges + seeks, not per-frame).
        for gap in trimGaps {
            if gap.startMs > mediaMs { return nil }
            if mediaMs < gap.endMs { return gap }
        }
        return nil
    }

    /// Moves between base rate and the glide rate depending on where the
    /// playhead is. Idempotent; called from every place position or intent
    /// can change.
    private func applyTrimRate() {
        guard isPlaying else { return }
        let base = Double(player.defaultRate)
        let inGap = trimEnabled && !isScrubbing
            ? trimGap(at: mediaPositionMs)
            : nil
        // Inside a skip block the skip observer owns the playhead.
        let target = (inGap != nil && timeline.block(at: mediaPositionMs) == nil)
            ? min(base * Self.trimMultiplier, Self.trimRateCap)
            : base

        if let leaving = activeTrimGap, leaving != inGap {
            // Credit the whole gap on exit; partial passes under-credit
            // occasionally, which is the honest direction to err.
            let boost = min(base * Self.trimMultiplier, Self.trimRateCap)
            if boost > base {
                let saved = Double(leaving.durationMs) * (1 / base - 1 / boost)
                timeSavedByTrimMs += max(0, Int(saved))
            }
        }
        activeTrimGap = inGap

        if abs(Double(player.rate) - target) > 0.01 {
            player.rate = Float(target)
        }
    }
}
