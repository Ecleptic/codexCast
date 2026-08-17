import CodexCastCore
import Foundation
import Testing

@testable import CodexCastDetection

@Suite("Detection pipeline")
struct DetectionPipelineTests {
    private func transcript(durationMs: Int, adText: String? = nil, adAtMs: Int = 0) -> TimedTranscript {
        let step = 10_000
        var segments: [TimedTranscript.Segment] = []
        for start in stride(from: 0, to: durationMs, by: step) {
            let isAd = adText != nil && start >= adAtMs && start < adAtMs + 60_000
            segments.append(
                .init(
                    startMs: start,
                    endMs: min(start + step, durationMs),
                    text: isAd ? adText! : "ordinary conversation about the news at \(start / 1000) seconds"
                )
            )
        }
        return TimedTranscript(source: .onDevice, segments: segments)
    }

    private var context: ClassificationContext {
        ClassificationContext(showName: "Test Show")
    }

    /// The economy of the design: what Stage 1 resolves never reaches the
    /// model, and a fully-learned episode dispatches nothing at all.
    @Test("A pattern-resolved region is not sent to the model")
    func resolvedRegionsSkipTheModel() async throws {
        let adText = "this episode is brought to you by squarespace visit squarespace dot com slash show"
        let episodeTranscript = transcript(durationMs: 600_000, adText: adText, adAtMs: 60_000)

        let pattern = PatternBaselineDetector.Pattern(
            text: String(repeating: adText + " ", count: 6),
            durationMs: 60_000,
            sponsor: "Squarespace"
        )

        let withPatterns = try await DetectionPipeline(classifier: StubClassifier()).run(
            .init(
                episodeID: Episode.ID(),
                transcript: episodeTranscript,
                episodeDurationMs: 600_000,
                context: context,
                patterns: [pattern]
            )
        )

        // The ad is found without the model, and its provenance says so.
        #expect(withPatterns.segments.count == 1)
        if case .patternMatch = withPatterns.segments[0].provenance {} else {
            Issue.record("expected patternMatch provenance")
        }
    }

    @Test("Model findings are snapped to transcript boundaries")
    func modelFindingsSnap() async throws {
        let episodeTranscript = transcript(durationMs: 300_000)
        // Deliberately off-grid times: 33_333 and 94_444.
        let stub = StubClassifier(findings: [
            0: [WindowFinding(startMs: 33_333, endMs: 94_444, kind: .ad, confidence: 0.9)]
        ])

        let result = try await DetectionPipeline(classifier: stub).run(
            .init(
                episodeID: Episode.ID(),
                transcript: episodeTranscript,
                episodeDurationMs: 300_000,
                context: context
            )
        )

        let segment = try #require(result.segments.first)
        // Every cue edge is a multiple of 10s, so both bounds must be too.
        #expect(segment.startMs % 10_000 == 0)
        #expect(segment.endMs % 10_000 == 0)
    }

    /// Ads run in blocks; skipping them individually produces stutter (§5.5).
    @Test("Adjacent segments share a chunk; distant ones do not")
    func chunking() async throws {
        let episodeTranscript = transcript(durationMs: 600_000)
        let stub = StubClassifier(findings: [
            0: [
                WindowFinding(startMs: 30_000, endMs: 60_000, kind: .ad, confidence: 0.9),
                WindowFinding(startMs: 60_000, endMs: 90_000, kind: .ad, confidence: 0.9),
                WindowFinding(startMs: 200_000, endMs: 230_000, kind: .ad, confidence: 0.9),
            ]
        ])

        let result = try await DetectionPipeline(classifier: stub).run(
            .init(
                episodeID: Episode.ID(),
                transcript: episodeTranscript,
                episodeDurationMs: 600_000,
                context: context
            )
        )

        let chunks = Set(result.segments.compactMap(\.chunkID))
        #expect(result.segments.count >= 2)
        // Back-to-back spots share a block; the distant one is its own.
        #expect(chunks.count == 2)
    }

    @Test("A classifier that throws costs its window, not the episode")
    func failingClassifierIsSurvivable() async throws {
        struct ExplodingClassifier: AdClassifier {
            let identifier = "exploding"
            var isAvailable: Bool { true }
            func classify(
                window: TranscriptWindow, context: ClassificationContext
            ) async throws -> [WindowFinding] {
                throw CancellationError()
            }
        }

        let result = try await DetectionPipeline(classifier: ExplodingClassifier()).run(
            .init(
                episodeID: Episode.ID(),
                transcript: transcript(durationMs: 600_000),
                episodeDurationMs: 600_000,
                context: context
            )
        )

        #expect(result.segments.isEmpty)
        #expect(result.modelWindowsDispatched > 0)
    }
}

@Suite("Validation gate")
struct ValidationGateTests {
    private func segment(
        startMs: Int,
        endMs: Int,
        confidence: Double = 0.9,
        provenance: Provenance = .onDeviceModel(windowIndex: 0, modelTier: "afm"),
        userState: UserState = .unreviewed
    ) -> DetectedSegment {
        DetectedSegment(
            episodeID: Episode.ID(),
            startMs: startMs,
            endMs: endMs,
            kind: .ad,
            confidence: confidence,
            provenance: provenance,
            userState: userState
        )
    }

    @Test("Confident, well-sized segments auto-skip")
    func happyPath() {
        let outcome = ValidationGate().evaluate(
            segments: [segment(startMs: 60_000, endMs: 120_000)],
            episodeDurationMs: 3_600_000
        )

        #expect(outcome.autoSkippable.count == 1)
        #expect(!outcome.flaggedForReview)
    }

    /// 5s, not 8s: "this episode is sponsored by X" is a real spot.
    @Test("A 6-second spot is allowed; a 3-second one is review-only")
    func durationBounds() {
        let gate = ValidationGate()

        let short = gate.evaluate(
            segments: [segment(startMs: 10_000, endMs: 16_000)],
            episodeDurationMs: 3_600_000
        )
        #expect(short.autoSkippable.count == 1)

        let tooShort = gate.evaluate(
            segments: [segment(startMs: 10_000, endMs: 13_000)],
            episodeDurationMs: 3_600_000
        )
        #expect(tooShort.autoSkippable.isEmpty)
        #expect(tooShort.reviewOnly.count == 1)
    }

    @Test("Low confidence is kept for review rather than skipped")
    func confidenceThreshold() {
        let outcome = ValidationGate(policy: .conservative).evaluate(
            segments: [segment(startMs: 60_000, endMs: 120_000, confidence: 0.8)],
            episodeDurationMs: 3_600_000
        )

        #expect(outcome.autoSkippable.isEmpty)
        #expect(outcome.reviewOnly.count == 1)
    }

    @Test("A segment overlapping a never-skip region is not skipped")
    func neverSkipRegions() {
        let outcome = ValidationGate().evaluate(
            segments: [segment(startMs: 60_000, endMs: 120_000)],
            episodeDurationMs: 3_600_000,
            neverSkipRegions: [90_000...150_000]
        )

        #expect(outcome.autoSkippable.isEmpty)
    }

    /// The guard exists to catch a runaway classifier: many individually
    /// plausible segments that together swallow the episode.
    @Test("Flagging more than 40% of an episode trips the runaway guard")
    func runawayGuard() {
        // Five spots, each 9% of the episode — under the single-segment
        // ceiling — but 45% together.
        let outcome = ValidationGate().evaluate(
            segments: (0..<5).map { index in
                segment(startMs: index * 100_000, endMs: index * 100_000 + 90_000)
            },
            episodeDurationMs: 1_000_000
        )

        #expect(outcome.flaggedForReview)
        #expect(outcome.autoSkippable.isEmpty)
    }

    /// The field failure this cap exists for: one "sponsor read" swallowing
    /// a third of the daily show Cam listens to every morning.
    @Test("A single segment covering a third of the episode never auto-skips")
    func singleSegmentCeiling() {
        let outcome = ValidationGate().evaluate(
            segments: [segment(startMs: 60_000, endMs: 400_000)],
            episodeDurationMs: 1_000_000
        )

        #expect(outcome.autoSkippable.isEmpty)
        #expect(outcome.reviewOnly.count == 1)
    }

    /// …not to second-guess the user. "Always skip the first 90 seconds" must
    /// survive a nervous heuristic (§5.6).
    @Test("User-created segments survive the runaway guard")
    func userSegmentsExemptFromRunaway() {
        let outcome = ValidationGate().evaluate(
            segments: [
                segment(startMs: 0, endMs: 500_000, provenance: .manual),
                // 45% of the episode from the model — over the guard — in
                // spots each under the single-segment ceiling, so they are
                // otherwise skippable. The user's own 50% is excluded.
                segment(startMs: 510_000, endMs: 600_000),
                segment(startMs: 610_000, endMs: 700_000),
                segment(startMs: 710_000, endMs: 800_000),
                segment(startMs: 810_000, endMs: 900_000),
                segment(startMs: 905_000, endMs: 995_000),
            ],
            episodeDurationMs: 1_000_000
        )

        #expect(outcome.flaggedForReview)
        // The user's own segment still skips; the machine's does not.
        #expect(outcome.autoSkippable.count == 1)
        #expect(outcome.autoSkippable.first?.provenance == .manual)
    }

    @Test("A confirmed segment skips regardless of confidence or duration")
    func confirmedSegmentsAlwaysSkip() {
        let outcome = ValidationGate().evaluate(
            segments: [
                segment(startMs: 0, endMs: 2_000, confidence: 0.1, userState: .confirmed)
            ],
            episodeDurationMs: 3_600_000
        )

        #expect(outcome.autoSkippable.count == 1)
    }

    @Test("A rejected segment is never auto-skipped")
    func rejectedSegments() {
        let outcome = ValidationGate().evaluate(
            segments: [
                segment(startMs: 60_000, endMs: 120_000, userState: .rejected)
            ],
            episodeDurationMs: 3_600_000
        )

        #expect(outcome.autoSkippable.isEmpty)
        #expect(outcome.reviewOnly.count == 1)
    }
}
