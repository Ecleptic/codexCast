// Two-pass detection experiment: candidate sweep → focused verify with
// quote-anchored boundaries.
//
// Hypotheses under test, against Arm 1's baseline (located F1 0.67,
// boundary error ~44s, plus 5 confident FPs on tech news in the field):
//  1. A recall-tuned sweep followed by a precision-tuned verifier beats one
//     pass asked to do both (the SponsorBlock-ML decomposition).
//  2. Asking the verifier to QUOTE the ad's first/last words, then locating
//     those quotes in the transcript, beats asking a small model for
//     timestamps (it copies well and counts badly).
//
// Same Mac caveats as Arm 1: older model generation, JSON mode.

import CodexCastCore
import CodexCastDetection
import Foundation
import FoundationModels
import SpikeShared

enum TwoPass {
    // MARK: Pass 1 — recall-tuned candidate sweep

    static let sweepInstructions = """
    You scan podcast transcripts for stretches that might be advertising. \
    Each line has a [mm:ss] timestamp.

    Flag ANY stretch that could plausibly be: a paid advertisement, a \
    host-read sponsor message, or the show promoting its own products or \
    memberships. This is a first pass — casting a wide net is fine; a later \
    step rejects false alarms. Do not agonize over exact boundaries.

    Respond with ONLY a JSON array. Each element:
    {"startSeconds": <int>, "endSeconds": <int>, "hint": "<the few words that made you flag it>"}
    If nothing could be advertising, respond [].
    """

    struct Sweep: Decodable {
        var startSeconds: Int
        var endSeconds: Int
        var hint: String?
    }

    // MARK: Pass 2 — precision-tuned verify with quote anchors

    static let verifyInstructions = """
    You judge whether a flagged stretch of a podcast transcript is actually \
    advertising. Each line has a [mm:ss] timestamp.

    A real promotional read addresses the listener directly with a call to \
    action — "you should try", "go to", "use code", "sign up" — and names a \
    specific advertiser or offer. News or reviews describing a product in \
    the third person, with no action asked of the listener, are CONTENT, \
    however commercial they sound. Discussion ABOUT advertising is content.

    If the excerpt contains a real promotional read, respond with ONLY:
    {"isAd": true, "kind": "ad"|"sponsor_read"|"self_promo", "sponsor": "<advertiser name>", "firstWords": "<copy the EXACT first 8-12 words of the read, verbatim from the excerpt>", "lastWords": "<copy the EXACT last 8-12 words of the read, verbatim>", "confidence": <0.0-1.0>}
    Copy firstWords and lastWords character-for-character from the excerpt \
    text. If there is no real promotional read, respond with ONLY:
    {"isAd": false}
    """

    struct Verdict: Decodable {
        var isAd: Bool
        var kind: String?
        var sponsor: String?
        var firstWords: String?
        var lastWords: String?
        var confidence: Double?
    }

    // MARK: - Run

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

        print("Two-pass — sweep + quote-anchored verify (Mac preview, JSON mode)")
        for episode in episodes {
            guard let transcript = episode.timedTranscript else { continue }
            let started = Date()
            let windows = Arm1.makeWindows(of: transcript)

            // Pass 1: sweep.
            var candidates: [ClosedRange<Int>] = []
            var sweepFailures = 0
            for (index, window) in windows.enumerated() {
                print("    sweep \(index + 1)/\(windows.count)", terminator: "\r")
                do {
                    let session = LanguageModelSession(instructions: sweepInstructions)
                    let response = try await session.respond(to: window.prompt)
                    for sweep in parseArray(Sweep.self, from: response.content) {
                        let span = (sweep.startSeconds * 1000)...(max(sweep.startSeconds + 1, sweep.endSeconds) * 1000)
                        candidates.append(span)
                    }
                } catch {
                    sweepFailures += 1
                }
            }
            let mergedCandidates = EvalMetrics.mergeSpans(candidates)

            // Pass 2: verify each candidate with focused context.
            var spans: [ClosedRange<Int>] = []
            var kept = 0
            for candidate in mergedCandidates {
                guard let verdict = try? await verify(candidate, transcript: transcript),
                      verdict.isAd,
                      (verdict.confidence ?? 0) >= 0.4
                else { continue }
                kept += 1
                spans.append(anchoredSpan(for: verdict, candidate: candidate, transcript: transcript))
            }

            let merged = EvalMetrics.mergeSpans(spans)
            let elapsed = Int(Date().timeIntervalSince(started))
            let truth = EvalMetrics.mergeSpans(episode.adSpans())
            print("      candidates: " + mergedCandidates.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("      predicted:  " + merged.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("      truth:      " + truth.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("  \(episode.episodeTitle.prefix(26)): \(windows.count) windows, \(sweepFailures) sweep failures, \(mergedCandidates.count) candidates, \(kept) verified, \(elapsed)s")
            rows.append((episode, merged))
        }

        print()
        SpikeEnvironment.report(rows)
    }

    static func verify(
        _ candidate: ClosedRange<Int>, transcript: TimedTranscript, primed: Bool = true
    ) async throws -> Verdict? {
        let contextStart = candidate.lowerBound - 60_000
        let contextEnd = candidate.upperBound + 60_000
        let lines = transcript.segments
            .filter { $0.endMs > contextStart && $0.startMs < contextEnd }
            .map { cue in
                let seconds = cue.startMs / 1000
                return String(format: "[%d:%02d] %@", seconds / 60, seconds % 60, cue.text)
            }
        guard !lines.isEmpty else { return nil }
        let flaggedFrom = candidate.lowerBound / 1000
        let flaggedTo = candidate.upperBound / 1000
        // Priming matters: "a first pass flagged this" is appropriate for a
        // genuinely suspicious candidate, but asked of EVERY chapter it is a
        // leading question — the first chapters run said yes to 7 of 9.
        let header = primed
            ? """
            A first pass flagged [\(flaggedFrom / 60):\(String(format: "%02d", flaggedFrom % 60))] to \
            [\(flaggedTo / 60):\(String(format: "%02d", flaggedTo % 60))] as possible advertising.
            """
            : """
            Below is one chapter of the episode ([\(flaggedFrom / 60):\(String(format: "%02d", flaggedFrom % 60))] to \
            [\(flaggedTo / 60):\(String(format: "%02d", flaggedTo % 60))]), with a little surrounding \
            context. Most chapters are ordinary content.
            """
        let prompt = """
        \(header)

        \(lines.joined(separator: "\n"))
        """
        let session = LanguageModelSession(instructions: verifyInstructions)
        let response = try await session.respond(to: prompt)
        return parseObject(Verdict.self, from: response.content)
    }

    /// Boundaries from the verifier's quotes where they locate; the sweep's
    /// snapped span where they don't.
    static func anchoredSpan(
        for verdict: Verdict, candidate: ClosedRange<Int>, transcript: TimedTranscript
    ) -> ClosedRange<Int> {
        let startAnchor = verdict.firstWords.flatMap {
            TranscriptQuoteLocator.locate(quote: $0, in: transcript, nearMs: candidate.lowerBound)
        }
        let endAnchor = verdict.lastWords.flatMap {
            TranscriptQuoteLocator.locate(quote: $0, in: transcript, nearMs: candidate.upperBound)
        }
        let fallbackStart = transcript.nearestBoundary(toMs: candidate.lowerBound) ?? candidate.lowerBound
        let fallbackEnd = transcript.nearestBoundary(toMs: candidate.upperBound) ?? candidate.upperBound
        let start = startAnchor?.startMs ?? fallbackStart
        let end = endAnchor?.endMs ?? fallbackEnd
        return start < end ? start...end : fallbackStart...max(fallbackEnd, fallbackStart + 1)
    }

    // MARK: - Tolerant JSON

    static func parseArray<T: Decodable>(_ type: T.Type, from text: String) -> [T] {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(String(text[start...end]).utf8))) ?? []
    }

    static func parseObject<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(String(text[start...end]).utf8))
    }
}
