import Foundation
import Testing

@testable import CodexCastCore

@Suite("Transcript drift detection — A1")
struct TranscriptDriftTests {
    /// A feed transcript with distinctive sentences every ~30s.
    private func feed(shiftAfterMs: Int = .max, shiftMs: Int = 0) -> TimedTranscript {
        let sentences = [
            "welcome back to the program today we are digging into container networking",
            "the scheduler treats every replica as interchangeable which is precisely the problem",
            "our benchmark harness pinned the allocator regression to a single commit",
            "listeners wrote in about the persistent volume corruption issue from last week",
            "the maintainers landed a fix upstream and backported it to the stable branch",
            "before we wrap up let us revisit the roadmap for the next quarterly release",
        ]
        var cues: [TimedTranscript.Segment] = []
        for (index, text) in sentences.enumerated() {
            let trueStart = index * 300_000
            let start = trueStart >= shiftAfterMs ? trueStart - shiftMs : trueStart
            cues.append(.init(startMs: start, endMs: start + 20_000, text: text))
        }
        return TimedTranscript(source: .podcasting20, segments: cues)
    }

    @Test("A transcript that matches the audio passes")
    func aligned() {
        let transcript = feed()
        let samples = [
            TranscriptDriftDetector.Sample(
                audioStartMs: 300_000,
                text: "the scheduler treats every replica as interchangeable which is precisely the problem"
            ),
            TranscriptDriftDetector.Sample(
                audioStartMs: 900_000,
                text: "listeners wrote in about the persistent volume corruption issue from last week"
            ),
        ]
        let verdict = TranscriptDriftDetector.verdict(feed: transcript, samples: samples)
        #expect(!verdict.isDesynced)
        #expect(verdict.matchedCount == 2)
    }

    @Test("Text found minutes away from where the feed claims = desynced")
    func shifted() {
        // Feed timestamps run 90s early after the 10-minute mark — the
        // LINUX Unplugged 678 case.
        let transcript = feed(shiftAfterMs: 600_000, shiftMs: 90_000)
        let samples = [
            TranscriptDriftDetector.Sample(
                audioStartMs: 900_000,
                text: "listeners wrote in about the persistent volume corruption issue from last week"
            ),
        ]
        let verdict = TranscriptDriftDetector.verdict(feed: transcript, samples: samples)
        #expect(verdict.isDesynced)
        #expect(verdict.maxAbsOffsetMs >= 80_000)
    }

    @Test("Samples that landed inside inserted ads don't match anything")
    func insertedAds() {
        let transcript = feed()
        let samples = [
            TranscriptDriftDetector.Sample(
                audioStartMs: 400_000,
                text: "use promo code podcast for twenty percent off your first order of premium meal kits delivered fresh"
            ),
            TranscriptDriftDetector.Sample(
                audioStartMs: 1_000_000,
                text: "this episode is brought to you by the fastest growing security platform trusted by thousands of teams"
            ),
        ]
        let verdict = TranscriptDriftDetector.verdict(feed: transcript, samples: samples)
        #expect(verdict.isDesynced)
        #expect(verdict.unmatchedCount == 2)
    }
}
