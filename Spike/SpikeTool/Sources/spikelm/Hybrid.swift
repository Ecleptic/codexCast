// Hybrid: sweep for suspicion + lexical markers for mid-roll insurance +
// chapters for shape.
//
// What the pure-chapters run taught us: the two-pass verifier's precision
// actually lives in the SWEEP's selectivity — asked neutrally about every
// chapter, the (Mac preview) verifier approves nearly everything. So
// chapters become the unit of verification, but only chapters that earned
// suspicion get verified:
//   a) chapters overlapping a sweep hit, or
//   b) chapters containing hard lexical ad markers — promo codes, offer
//      URLs, "brought to you by" — which cost nothing and don't depend on
//      the model staying awake mid-transcript.

import CodexCastCore
import CodexCastDetection
import Foundation
import FoundationModels
import SpikeShared

enum Hybrid {
    /// Phrases that essentially never occur outside promotional reads.
    static let adMarkers: [String] = [
        "promo code", "use code", "coupon code", "offer code",
        "brought to you by", "sponsored by", "thanks to our sponsor",
        "this episode is supported by", "support for this show",
        "dot com slash", "percent off", "free trial", "free shipping",
        "terms apply", "when you sign up", "sign up today", "first month free",
    ]

    static func markerHit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return adMarkers.contains { lowered.contains($0) }
    }

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

        print("Hybrid — sweep + lexical markers + chapter-shaped verify (Mac preview)")
        for episode in episodes {
            guard let transcript = episode.timedTranscript else { continue }
            let started = Date()

            guard let chapters = TopicSegmenter.chapters(for: transcript) else {
                print("  \(episode.episodeTitle.prefix(26)): embedding assets unavailable, skipping")
                continue
            }

            // Suspicion source 1: the sweep.
            let windows = Arm1.makeWindows(of: transcript)
            var sweepSpans: [ClosedRange<Int>] = []
            var sweepFailures = 0
            for (index, window) in windows.enumerated() {
                print("    sweep \(index + 1)/\(windows.count)", terminator: "\r")
                do {
                    let session = LanguageModelSession(instructions: TwoPass.sweepInstructions)
                    let response = try await session.respond(to: window.prompt)
                    for sweep in TwoPass.parseArray(TwoPass.Sweep.self, from: response.content) {
                        sweepSpans.append((sweep.startSeconds * 1000)...(max(sweep.startSeconds + 1, sweep.endSeconds) * 1000))
                    }
                } catch { sweepFailures += 1 }
            }

            // Suspicion source 2: lexical markers, per chapter.
            var suspicious: Set<TopicSegmenter.Chapter> = []
            for chapter in chapters {
                let text = transcript.text(fromMs: chapter.startMs, toMs: chapter.endMs)
                if markerHit(text) {
                    suspicious.insert(chapter)
                    continue
                }
                if sweepSpans.contains(where: { $0.lowerBound < chapter.endMs && chapter.startMs < $0.upperBound }) {
                    suspicious.insert(chapter)
                }
            }

            // Chapter-shaped verification of suspicious chapters only.
            var spans: [ClosedRange<Int>] = []
            var kept = 0
            for chapter in suspicious.sorted(by: { $0.startMs < $1.startMs }) {
                let candidate = chapter.startMs...chapter.endMs
                guard let verdict = try? await TwoPass.verify(candidate, transcript: transcript),
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
            print("      chapters: \(chapters.count), suspicious: \(suspicious.count), sweep failures: \(sweepFailures)")
            print("      predicted: " + merged.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("      truth:     " + truth.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("  \(episode.episodeTitle.prefix(26)): \(kept) verified, \(elapsed)s")
            rows.append((episode, merged))
        }

        print()
        SpikeEnvironment.report(rows)
    }
}
