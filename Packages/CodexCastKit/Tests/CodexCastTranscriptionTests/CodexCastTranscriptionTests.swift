import CodexCastCore
import Foundation
import Testing

@testable import CodexCastTranscription

@Suite("Transcript quality gate")
struct QualityGateTests {
    private func transcript(words: Int, spanMs: Int) -> TimedTranscript {
        // Evenly spread cues of five words each.
        let cueCount = max(1, words / 5)
        let step = spanMs / cueCount
        let segments = (0..<cueCount).map { index in
            TimedTranscript.Segment(
                startMs: index * step,
                endMs: index * step + step,
                text: "five words of spoken audio"
            )
        }
        return TimedTranscript(source: .onDevice, segments: segments)
    }

    @Test("Normal speech density passes")
    func normalSpeechPasses() {
        // 130 wpm over a full hour: an ordinary conversation show.
        let result = TranscriptQualityGate.verdict(
            transcript(words: 7_800, spanMs: 3_600_000),
            mediaDurationMs: 3_600_000
        )

        #expect(result == nil)
    }

    /// A music show yields scattered fragments — §9.8 says mark it, stop
    /// retrying, and let playback continue without detection.
    @Test("A music show's sparse fragments are marked notTranscribable")
    func musicShowFails() {
        let result = TranscriptQualityGate.verdict(
            transcript(words: 300, spanMs: 3_600_000),
            mediaDurationMs: 3_600_000
        )

        #expect(result == .lowWordDensity)
    }

    @Test("A transcript covering a fraction of the file fails on coverage")
    func lowCoverageFails() {
        // Dense speech, but only the first 4 minutes of a 60-minute file —
        // one spoken intro on a DJ mix.
        let result = TranscriptQualityGate.verdict(
            transcript(words: 600, spanMs: 240_000),
            mediaDurationMs: 3_600_000
        )

        #expect(result == .lowWordDensity)
    }

    @Test("An empty transcript is a failure, not a pass")
    func emptyTranscriptFails() {
        let result = TranscriptQualityGate.verdict(
            TimedTranscript(source: .onDevice, segments: []),
            mediaDurationMs: 3_600_000
        )

        #expect(result == .repeatedFailure)
    }
}

@Suite("Live transcription", .enabled(if: LiveMedia.sampleEpisode != nil))
struct LiveTranscriptionTests {
    /// End-to-end through the real SpeechAnalyzer on a real downloaded episode.
    /// Runs only where Spike media exists (a developer Mac); CI skips it.
    @Test("A real episode transcribes with millisecond timings", .timeLimit(.minutes(5)))
    func transcribesRealEpisode() async throws {
        let url = try #require(LiveMedia.sampleEpisode)

        let transcript = try await TranscriptionEngine().transcribe(fileAt: url)

        #expect(transcript.source == .onDevice)
        #expect(transcript.segments.count > 20)
        #expect(transcript.segments.allSatisfy { $0.endMs > $0.startMs })
        // Podnews Daily is ~4–5 minutes of dense news reading.
        #expect(TranscriptQualityGate.verdict(transcript, mediaDurationMs: transcript.durationMs) == nil)

        let starts = transcript.segments.map(\.startMs)
        #expect(starts == starts.sorted())
    }
}

enum LiveMedia {
    /// The smallest downloaded episode, if the Spike media directory exists.
    static var sampleEpisode: URL? {
        let media = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spike/media/podnews")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: media, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "mp3" }
            .min { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                return left < right
            }
    }
}
