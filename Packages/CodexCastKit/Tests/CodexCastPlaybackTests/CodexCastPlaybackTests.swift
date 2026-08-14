import CodexCastCore
import Foundation
import Testing

@testable import CodexCastPlayback

@Suite("Display timeline — identity case")
struct DisplayTimelineIdentityTests {
    /// With nothing skipped the mapping is the identity, which is why this can
    /// be built and trusted before skipping exists at all.
    @Test("With no skip blocks, display time equals media time")
    func identityMapping() {
        let timeline = DisplayTimeline(mediaDurationMs: 3_600_000)

        #expect(timeline.displayDurationMs == 3_600_000)
        #expect(timeline.displayMs(forMedia: 0) == 0)
        #expect(timeline.displayMs(forMedia: 1_234_567) == 1_234_567)
        #expect(timeline.mediaMs(forDisplay: 1_234_567) == 1_234_567)
        #expect(timeline.boundaryTimesMs.isEmpty)
    }

    @Test("Times outside the media are clamped rather than extrapolated")
    func clamping() {
        let timeline = DisplayTimeline(mediaDurationMs: 1_000)

        #expect(timeline.displayMs(forMedia: -500) == 0)
        #expect(timeline.displayMs(forMedia: 5_000) == 1_000)
        #expect(timeline.mediaMs(forDisplay: -500) == 0)
        #expect(timeline.mediaMs(forDisplay: 5_000) == 1_000)
    }

    @Test("A zero-length episode does not divide by zero")
    func zeroDuration() {
        let timeline = DisplayTimeline(mediaDurationMs: 0)

        #expect(timeline.displayDurationMs == 0)
        #expect(timeline.flaggedFraction() == 0)
        #expect(timeline.displayMs(forMedia: 100) == 0)
    }
}

@Suite("Display timeline — with skips")
struct DisplayTimelineSkipTests {
    /// A 60-minute episode with a 60-second pre-roll and a 90-second mid-roll.
    private var timeline: DisplayTimeline {
        DisplayTimeline(
            mediaDurationMs: 3_600_000,
            blocks: [
                SkipBlock(startMs: 0, endMs: 60_000),
                SkipBlock(startMs: 1_800_000, endMs: 1_890_000),
            ]
        )
    }

    @Test("Displayed duration excludes every skipped region")
    func displayDuration() {
        #expect(timeline.totalSkippedMs == 150_000)
        #expect(timeline.displayDurationMs == 3_450_000)
    }

    @Test("Media time after a skip maps back by the skipped amount")
    func mediaToDisplay() {
        // Just after the pre-roll: the listener has heard nothing yet.
        #expect(timeline.displayMs(forMedia: 60_000) == 0)
        #expect(timeline.displayMs(forMedia: 120_000) == 60_000)
        // After both blocks, both are subtracted.
        #expect(timeline.displayMs(forMedia: 1_890_000) == 1_740_000)
        #expect(timeline.displayMs(forMedia: 3_600_000) == 3_450_000)
    }

    /// Inside a skipped region no time passes from the listener's perspective.
    @Test("Media time inside a skipped block maps to the block's start")
    func insideBlock() {
        #expect(timeline.displayMs(forMedia: 30_000) == 0)
        #expect(timeline.displayMs(forMedia: 1_850_000) == 1_740_000)
    }

    /// This is the "dead zone" bug in other apps: scrubbing to a point that
    /// lands inside an ad.
    @Test("Scrubbing never lands inside a skipped block")
    func scrubbingAvoidsDeadZones() {
        for displayMs in stride(from: 0, through: 3_450_000, by: 9_973) {
            let mediaMs = timeline.mediaMs(forDisplay: displayMs)
            #expect(timeline.block(at: mediaMs) == nil, "display \(displayMs) landed inside a skip")
        }
    }

    @Test("Display and media conversions round-trip")
    func roundTrip() {
        for displayMs in stride(from: 0, through: 3_450_000, by: 7_919) {
            let mediaMs = timeline.mediaMs(forDisplay: displayMs)
            #expect(timeline.displayMs(forMedia: mediaMs) == displayMs)
        }
    }

    @Test("Boundary observers fire at block starts, ignoring a zero start")
    func boundaryTimes() {
        // A pre-roll starting at zero needs no observer — playback begins there
        // and the initial seek handles it.
        #expect(timeline.boundaryTimesMs == [1_800_000])
    }

    @Test("Resuming from inside a block continues at its end")
    func resumePosition() {
        #expect(timeline.resumePosition(afterSkippingFrom: 1_820_000) == 1_890_000)
        #expect(timeline.resumePosition(afterSkippingFrom: 500_000) == 500_000)
    }

    @Test("Flagged fraction feeds the runaway guard")
    func flaggedFraction() {
        #expect(abs(timeline.flaggedFraction() - 150_000.0 / 3_600_000.0) < 0.0001)
    }
}

@Suite("Display timeline — block normalization")
struct DisplayTimelineNormalizationTests {
    /// Overlapping blocks are not merely untidy: double-counting them in the
    /// duration arithmetic is exactly how the two timelines drift apart.
    @Test("Overlapping blocks are merged so their duration is not double-counted")
    func mergesOverlapping() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [
                SkipBlock(startMs: 10_000, endMs: 30_000),
                SkipBlock(startMs: 20_000, endMs: 40_000),
            ]
        )

        #expect(timeline.blocks.count == 1)
        #expect(timeline.blocks.first?.startMs == 10_000)
        #expect(timeline.blocks.first?.endMs == 40_000)
        #expect(timeline.totalSkippedMs == 30_000)
    }

    @Test("Touching blocks merge into one contiguous skip")
    func mergesTouching() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [
                SkipBlock(startMs: 10_000, endMs: 20_000),
                SkipBlock(startMs: 20_000, endMs: 30_000),
            ]
        )

        #expect(timeline.blocks.count == 1)
        #expect(timeline.totalSkippedMs == 20_000)
    }

    /// Corrections still apply per segment, so a merged block keeps every
    /// constituent id — rejecting one spot must not discard the others.
    @Test("Merging preserves the constituent segment ids")
    func mergePreservesSegmentIDs() {
        let first = DetectedSegment.ID()
        let second = DetectedSegment.ID()
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [
                SkipBlock(startMs: 10_000, endMs: 25_000, segmentIDs: [first]),
                SkipBlock(startMs: 20_000, endMs: 30_000, segmentIDs: [second]),
            ]
        )

        #expect(Set(timeline.blocks.first?.segmentIDs ?? []) == [first, second])
    }

    @Test("Blocks are sorted regardless of input order")
    func sortsBlocks() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [
                SkipBlock(startMs: 50_000, endMs: 60_000),
                SkipBlock(startMs: 10_000, endMs: 20_000),
            ]
        )

        #expect(timeline.blocks.map(\.startMs) == [10_000, 50_000])
    }

    @Test("Empty and inverted blocks are discarded")
    func discardsDegenerateBlocks() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [
                SkipBlock(startMs: 10_000, endMs: 10_000),
                SkipBlock(startMs: 50_000, endMs: 40_000),
                SkipBlock(startMs: 20_000, endMs: 30_000),
            ]
        )

        #expect(timeline.blocks.count == 1)
        #expect(timeline.blocks.first?.startMs == 20_000)
    }

    @Test("Blocks extending past the media are clamped to it")
    func clampsToMedia() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [SkipBlock(startMs: 90_000, endMs: 200_000)]
        )

        #expect(timeline.totalSkippedMs == 10_000)
        #expect(timeline.displayDurationMs == 90_000)
    }

    /// An episode that is entirely ads should report zero remaining rather than
    /// a negative duration.
    @Test("A fully-skipped episode reports zero display duration")
    func fullySkipped() {
        let timeline = DisplayTimeline(
            mediaDurationMs: 100_000,
            blocks: [SkipBlock(startMs: 0, endMs: 100_000)]
        )

        #expect(timeline.displayDurationMs == 0)
        #expect(timeline.displayMs(forMedia: 50_000) == 0)
    }
}

@Suite("Silence detection")
struct SilenceDetectorTests {
    /// Builds a signal at 16kHz: alternating tone and silence in known places.
    private func makeSamples(
        segments: [(isSpeech: Bool, durationMs: Int)],
        sampleRate: Double = 16_000
    ) -> [Float] {
        var samples: [Float] = []
        var phase = 0.0
        for segment in segments {
            let count = Int(sampleRate * Double(segment.durationMs) / 1000)
            for _ in 0..<count {
                if segment.isSpeech {
                    phase += 2 * Double.pi * 300 / sampleRate
                    samples.append(Float(sin(phase) * 0.5))
                } else {
                    samples.append(0)
                }
            }
        }
        return samples
    }

    @Test("A silent gap between speech is found at the right place")
    func findsGap() {
        let samples = makeSamples(segments: [
            (true, 1_000),
            (false, 500),
            (true, 1_000),
        ])
        let detector = SilenceDetector()

        let gaps = detector.gaps(samples: samples, sampleRate: 16_000)

        #expect(gaps.count == 1)
        let gap = try! #require(gaps.first)
        #expect(abs(gap.startMs - 1_000) <= 40)
        #expect(abs(gap.endMs - 1_500) <= 40)
    }

    @Test("Gaps shorter than the minimum are ignored")
    func ignoresShortGaps() {
        let samples = makeSamples(segments: [
            (true, 500),
            (false, 60),
            (true, 500),
        ])
        let detector = SilenceDetector()

        let gaps = detector.gaps(samples: samples, sampleRate: 16_000, minimumDurationMs: 180)

        #expect(gaps.isEmpty)
    }

    @Test("Continuous speech produces no gaps")
    func continuousSpeech() {
        let samples = makeSamples(segments: [(true, 3_000)])
        let detector = SilenceDetector()

        #expect(detector.gaps(samples: samples, sampleRate: 16_000).isEmpty)
    }

    /// Stage 3 snaps a proposed boundary to the nearest silence, since authored
    /// or acoustic boundaries beat inferred ones.
    @Test("A boundary snaps to the nearest gap within tolerance")
    func snapsToNearestGap() {
        let detector = SilenceDetector()
        let gaps = [
            SilenceDetector.Gap(startMs: 1_000, endMs: 1_400),
            SilenceDetector.Gap(startMs: 5_000, endMs: 5_400),
        ]

        #expect(detector.snap(boundaryMs: 1_300, toGaps: gaps) == 1_200)
        #expect(detector.snap(boundaryMs: 5_100, toGaps: gaps) == 5_200)
    }

    /// With no gap in range, §5.4 says keep the transcript boundary rather than
    /// snapping to something distant — better a fragment of ad than clipped speech.
    @Test("No gap within tolerance means no snap")
    func noSnapWhenTooFar() {
        let detector = SilenceDetector()
        let gaps = [SilenceDetector.Gap(startMs: 1_000, endMs: 1_400)]

        #expect(detector.snap(boundaryMs: 20_000, toGaps: gaps, toleranceMs: 2_000) == nil)
    }

    @Test("An empty or too-short buffer yields no gaps rather than crashing")
    func handlesEmptyInput() {
        let detector = SilenceDetector()

        #expect(detector.gaps(samples: [], sampleRate: 16_000).isEmpty)
        #expect(detector.gaps(samples: [0, 0, 0], sampleRate: 16_000).isEmpty)
        #expect(detector.frameEnergies(samples: [0.5], sampleRate: 0).isEmpty)
    }
}

@Suite("Playback settings")
struct PlaybackSettingsTests {
    @Test("Unset per-show settings resolve to the global defaults")
    func resolvesToDefaults() {
        let resolved = PlaybackSettings().resolved()

        #expect(resolved.voiceBoost == .off)
        #expect(resolved.speed == 1.0)
        #expect(!resolved.trimSilence)
    }

    @Test("A per-show override wins over the global default")
    func overrideWins() {
        let settings = PlaybackSettings(voiceBoost: .override(.high), speed: .override(1.5))

        let resolved = settings.resolved()

        #expect(resolved.voiceBoost == .high)
        #expect(resolved.speed == 1.5)
    }

    @Test("Speed is clamped to the supported range and quantized to the step")
    func speedNormalization() {
        #expect(PlaybackSpeed.normalize(0.1) == 0.5)
        #expect(PlaybackSpeed.normalize(5.0) == 3.0)
        #expect(abs(PlaybackSpeed.normalize(1.23) - 1.25) < 0.0001)
    }

    @Test("Voice Boost levels carry distinct parameters, and off carries none")
    func voiceBoostParameters() {
        #expect(VoiceBoostParameters.parameters(for: .off) == nil)

        let low = try! #require(VoiceBoostParameters.parameters(for: .low))
        let high = try! #require(VoiceBoostParameters.parameters(for: .high))

        // High is a stronger version of the same chain, not a different one.
        #expect(high.presenceGainDb > low.presenceGainDb)
        #expect(high.compressionRatio > low.compressionRatio)
        #expect(high.compressionThresholdDb < low.compressionThresholdDb)
    }

    @Test("Voice Boost off contributes no audio nodes")
    func offProducesNoNodes() {
        let processor = DefaultVoiceBoostProcessor()

        #expect(processor.makeNodes(for: .off).isEmpty)
        #expect(!processor.makeNodes(for: .high).isEmpty)
    }
}
