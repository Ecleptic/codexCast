import Foundation
import Testing

@testable import CodexCastCore
@testable import CodexCastDetection

@Suite("Quote-anchored boundaries")
struct QuoteLocatorTests {
    private var transcript: TimedTranscript {
        TimedTranscript(source: .onDevice, segments: [
            .init(startMs: 0, endMs: 8_000, text: "welcome back to the show today we have a lot to get through"),
            .init(startMs: 8_000, endMs: 16_000, text: "but first this episode is brought to you by our friends at Acme Mattress"),
            .init(startMs: 16_000, endMs: 24_000, text: "go to acme mattress dot com slash pod and use code pod for twenty percent off"),
            .init(startMs: 24_000, endMs: 32_000, text: "that's acme mattress dot com slash pod thanks acme for sponsoring"),
            .init(startMs: 32_000, endMs: 40_000, text: "alright let's get into the news the big story this week"),
        ])
    }

    @Test("An exact quote lands on its cue's edges")
    func exactQuote() throws {
        let hit = try #require(TranscriptQuoteLocator.locate(
            quote: "this episode is brought to you by our friends",
            in: transcript
        ))
        #expect(hit.startMs == 8_000)
        #expect(hit.endMs == 16_000)
    }

    @Test("A slightly mis-copied quote still lands")
    func fuzzyQuote() throws {
        // Two words off out of nine.
        let hit = try #require(TranscriptQuoteLocator.locate(
            quote: "that is acme mattress dot com slash pod thank",
            in: transcript
        ))
        #expect(hit.startMs == 24_000)
    }

    @Test("Garbage quotes match nothing")
    func noMatch() {
        #expect(TranscriptQuoteLocator.locate(
            quote: "completely unrelated words about quantum farming techniques",
            in: transcript
        ) == nil)
    }

    @Test("The search radius keeps distant repeats from winning")
    func radius() {
        var cues = transcript.segments
        // The same sponsor line repeated much later.
        cues.append(.init(
            startMs: 600_000, endMs: 608_000,
            text: "but first this episode is brought to you by our friends at Acme Mattress"
        ))
        let long = TimedTranscript(source: .onDevice, segments: cues)
        let hit = TranscriptQuoteLocator.locate(
            quote: "this episode is brought to you by our friends",
            in: long,
            nearMs: 590_000,
            searchRadiusMs: 60_000
        )
        #expect(hit?.startMs == 600_000)
    }
}
