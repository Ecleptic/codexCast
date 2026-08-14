import CodexCastCore
import Foundation
import Testing

@testable import CodexCastDetection

@Suite("Transcript windowing")
struct WindowerTests {
    /// One cue every 10 seconds for the given duration.
    private func transcript(durationMs: Int) -> TimedTranscript {
        let step = 10_000
        let segments = stride(from: 0, to: durationMs, by: step).map { start in
            TimedTranscript.Segment(
                startMs: start,
                endMs: min(start + step, durationMs),
                text: "cue at \(start / 1000)s"
            )
        }
        return TimedTranscript(source: .onDevice, segments: segments)
    }

    @Test("Windows overlap so a boundary-straddling ad is whole in one window")
    func windowsOverlap() {
        let windows = TranscriptWindower.windows(for: transcript(durationMs: 1_800_000))

        #expect(windows.count > 1)
        for pair in zip(windows, windows.dropFirst()) {
            // Each window starts before its predecessor ends.
            #expect(pair.1.startMs < pair.0.endMs)
            let overlap = pair.0.endMs - pair.1.startMs
            #expect(overlap >= 60_000, "overlap was \(overlap)ms")
        }
    }

    @Test("A trailing stub merges into its neighbour instead of dispatching")
    func stubMerges() {
        // With a 240s window and 165s hop, a 245s transcript leaves an 85s
        // tail — below the 90s minimum viable window, so it must merge.
        let windows = TranscriptWindower.windows(for: transcript(durationMs: 245_000))

        #expect(windows.count == 1)
        #expect(windows.first?.endMs == 245_000)
    }

    @Test("A short episode is a single window")
    func shortEpisode() {
        let windows = TranscriptWindower.windows(for: transcript(durationMs: 120_000))

        #expect(windows.count == 1)
    }

    /// §5.3.2's fragmentation policy: resolved regions stay in the window as
    /// annotated context; they are never cut out.
    @Test("Resolved regions are annotated in the prompt, not excised")
    func resolvedRegionsAnnotated() {
        let windows = TranscriptWindower.windows(
            for: transcript(durationMs: 200_000),
            resolved: [.init(startMs: 30_000, endMs: 60_000, label: "Squarespace")]
        )

        let prompt = windows.first!.promptText()
        #expect(prompt.contains("[AD — already identified: Squarespace]"))
        // The annotated cue text is still present.
        #expect(prompt.contains("cue at 40s"))
    }

    @Test("A window entirely inside resolved regions is skipped")
    func fullyResolvedWindowSkipped() {
        let full = transcript(durationMs: 700_000)
        let windows = TranscriptWindower.windows(
            for: full,
            resolved: [.init(startMs: 0, endMs: 700_000, label: "everything")]
        )

        #expect(windows.isEmpty)
    }

    @Test("Cross-window duplicate findings merge by overlap, keeping max confidence")
    func deduplication() {
        let findings = [
            WindowFinding(startMs: 100_000, endMs: 160_000, kind: .ad, confidence: 0.7),
            WindowFinding(startMs: 105_000, endMs: 165_000, kind: .ad, confidence: 0.9),
            WindowFinding(startMs: 500_000, endMs: 530_000, kind: .ad, confidence: 0.6),
        ]

        let merged = TranscriptWindower.deduplicate(findings)

        #expect(merged.count == 2)
        #expect(merged.first?.startMs == 100_000)
        #expect(merged.first?.endMs == 165_000)
        #expect(merged.first?.confidence == 0.9)
    }
}

@Suite("Stub classifier")
struct StubClassifierTests {
    @Test("The stub replays recorded findings per window index")
    func replaysFindings() async throws {
        let stub = StubClassifier(findings: [
            1: [WindowFinding(startMs: 0, endMs: 30_000, kind: .ad, confidence: 0.9)]
        ])
        let context = ClassificationContext(showName: "Test Show")
        let emptyWindow = TranscriptWindow(index: 0, cues: [])
        let recordedWindow = TranscriptWindow(index: 1, cues: [])

        #expect(try await stub.classify(window: emptyWindow, context: context).isEmpty)
        #expect(try await stub.classify(window: recordedWindow, context: context).count == 1)
    }

    @Test("Context bounds are enforced at construction")
    func contextBounds() {
        let context = ClassificationContext(
            showName: "Show",
            knownSponsors: (0..<50).map { "Sponsor \($0)" },
            negativeExemplars: ["a", "b", "c", "d"],
            showNotes: String(repeating: "x", count: 1_000)
        )

        #expect(context.knownSponsors.count == 10)
        #expect(context.negativeExemplars.count == 2)
        #expect(context.showNotes?.count == 300)
    }
}
