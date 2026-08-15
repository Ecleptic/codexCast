// Chapters-first experiment: topic-segment the transcript with on-device
// embeddings, then run the (already-validated) verifier on each chapter.
//
// Hypothesis: mid-rolls escape windowed sweeps because they drown in
// same-voice editorial context; a chapter isolates the ad's neighborhood.
// Compare against two-pass (strict F1 0.42) with special attention to
// mid-roll recall, which two-pass mostly missed.

import CodexCastCore
import CodexCastDetection
import Foundation
import FoundationModels
import SpikeShared

enum ChaptersFirst {
    static func run(limit: Int, only: String? = nil) async throws {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("model unavailable: \(model.availability)")
            exit(1)
        }

        var all = try Corpus.load(from: SpikeEnvironment.corpusDir)
        if let only { all = all.filter { $0.episodeTitle.lowercased().contains(only.lowercased()) } }
        all.sort { $0.durationMs < $1.durationMs }
        let episodes = Array(all.prefix(limit))
        var rows: [(CorpusEpisode, [ClosedRange<Int>])] = []

        print("Chapters-first — topic segmentation + verify (Mac preview, JSON mode)")
        for episode in episodes {
            guard let transcript = episode.timedTranscript else { continue }
            let started = Date()

            guard let chapters = TopicSegmenter.chapters(for: transcript) else {
                print("  \(episode.episodeTitle.prefix(26)): embedding assets unavailable, skipping")
                continue
            }

            var spans: [ClosedRange<Int>] = []
            var kept = 0
            for (index, chapter) in chapters.enumerated() {
                print("    chapter \(index + 1)/\(chapters.count)", terminator: "\r")
                let candidate = chapter.startMs...chapter.endMs
                guard let verdict = try? await TwoPass.verify(candidate, transcript: transcript, primed: false),
                      verdict.isAd,
                      (verdict.confidence ?? 0) >= 0.4
                else { continue }
                kept += 1
                spans.append(TwoPass.anchoredSpan(
                    for: verdict, candidate: candidate, transcript: transcript
                ))
            }

            let merged = EvalMetrics.mergeSpans(spans)
            let elapsed = Int(Date().timeIntervalSince(started))
            let truth = EvalMetrics.mergeSpans(episode.adSpans())
            print("      chapters:  \(chapters.count), sized " + chapters.prefix(8).map { "\($0.durationMs / 1000)s" }.joined(separator: ","))
            print("      predicted: " + merged.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("      truth:     " + truth.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("  \(episode.episodeTitle.prefix(26)): \(chapters.count) chapters, \(kept) verified, \(elapsed)s")
            rows.append((episode, merged))
        }

        print()
        SpikeEnvironment.report(rows)
    }
}
