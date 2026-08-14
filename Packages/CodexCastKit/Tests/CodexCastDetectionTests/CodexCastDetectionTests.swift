import CodexCastCore
import Foundation
import Testing

@testable import CodexCastDetection

/// The corpus lives at the repo root; #filePath locates it for local runs.
/// (On-device runs will bundle fixtures as resources — Phase 2 concern.)
enum CorpusLocation {
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // strip the file name
            .deletingLastPathComponent()   // CodexCastDetectionTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CodexCastKit
            .deletingLastPathComponent()   // Packages
            .appendingPathComponent("Fixtures/corpus")
    }
}

@Suite("Eval metrics")
struct EvalMetricsTests {
    @Test("Perfect predictions score 1.0 across the board")
    func perfectScore() {
        let truth = [1_000...5_000, 60_000...90_000]

        let result = EvalMetrics.evaluate(predicted: truth, truth: truth)

        #expect(result.precision == 1.0)
        #expect(result.recall == 1.0)
        #expect(result.f1 == 1.0)
        #expect(result.meanBoundaryErrorMs == 0)
    }

    @Test("Missed ads cost recall; invented ads cost precision")
    func asymmetry() {
        let truth = [1_000...5_000, 60_000...90_000]

        let missed = EvalMetrics.evaluate(predicted: [1_000...5_000], truth: truth)
        #expect(missed.precision == 1.0)
        #expect(missed.recall == 0.5)

        let invented = EvalMetrics.evaluate(
            predicted: [1_000...5_000, 60_000...90_000, 200_000...230_000],
            truth: truth
        )
        #expect(invented.recall == 1.0)
        #expect(abs(invented.precision - 2.0 / 3.0) < 0.001)
    }

    @Test("A roughly-right prediction counts as a hit, with its error reported")
    func chapterMarkerPrecision() {
        // Off by two seconds on each edge of a 60-second ad: a fine skip.
        let result = EvalMetrics.evaluate(
            predicted: [62_000...118_000],
            truth: [60_000...120_000]
        )

        #expect(result.truePositives == 1)
        #expect(result.boundaryErrorsMs == [4_000])
    }

    @Test("Barely-overlapping spans do not count as hits")
    func lowOverlapRejected() {
        let result = EvalMetrics.evaluate(
            predicted: [110_000...180_000],
            truth: [60_000...120_000]
        )

        #expect(result.truePositives == 0)
        #expect(result.falsePositives == 1)
        #expect(result.falseNegatives == 1)
    }

    @Test("One prediction cannot claim two truth spans")
    func greedyMatchingIsOneToOne() {
        // A single giant span over two separate ads: one (poor) match at best,
        // and here IoU with either ad is too low, so it matches neither.
        let result = EvalMetrics.evaluate(
            predicted: [0...200_000],
            truth: [10_000...40_000, 150_000...180_000]
        )

        #expect(result.truePositives == 0)
        #expect(result.falseNegatives == 2)
    }

    @Test("Span merging joins near-adjacent detections into one block")
    func spanMerging() {
        let merged = EvalMetrics.mergeSpans(
            [10_000...40_000, 42_000...70_000, 200_000...220_000],
            gapToleranceMs: 5_000
        )

        #expect(merged == [10_000...70_000, 200_000...220_000])
    }
}

@Suite("Corpus loading")
struct CorpusTests {
    @Test("The real corpus loads with every episode transcribed and in bounds")
    func loadsRealCorpus() throws {
        let episodes = try Corpus.load(from: CorpusLocation.url)

        #expect(episodes.count >= 6)
        #expect(Set(episodes.map(\.show)).count >= 5)

        for episode in episodes {
            let transcript = try #require(episode.timedTranscript, "\(episode.episodeTitle) has no transcript")
            #expect(!transcript.isEmpty)
            for segment in episode.segments {
                #expect(segment.startMs < segment.endMs)
                #expect(segment.endMs <= episode.durationMs + 2_000)
            }
        }
    }

    @Test("The ad-free control episode reports no ad spans")
    func adFreeControl() throws {
        let episodes = try Corpus.load(from: CorpusLocation.url)
        let control = try #require(episodes.first { $0.show == "Podcasting 2.0" })

        #expect(control.adSpans().isEmpty)
        #expect(!control.segments.isEmpty)   // it does have selfPromo + outro
    }
}

@Suite("Cross-episode pattern detection — the core bet, on real data")
struct CrossEpisodeTests {
    /// Tech Brew runs the same Vanguard read in consecutive episodes. Learning
    /// it from one episode's labels and finding it in the other — with no
    /// model, no network, nothing but stored text — is the app's entire thesis
    /// in one test.
    @Test("Vanguard, learned from one Tech Brew episode, is found in the other")
    func vanguardCrossEpisode() throws {
        let episodes = try Corpus.load(from: CorpusLocation.url)
        let techBrew = episodes.filter { $0.show == "Tech Brew Ride Home" }
        try #require(techBrew.count == 2)

        for (learnFrom, detectIn) in [(techBrew[0], techBrew[1]), (techBrew[1], techBrew[0])] {
            let patterns = PatternBaselineDetector.learn(from: [learnFrom])
            let detector = PatternBaselineDetector(patterns: patterns)
            let transcript = try #require(detectIn.timedTranscript)

            let matches = detector.detect(in: transcript)
            let vanguard = matches.first { ($0.sponsor ?? "").lowercased().contains("vanguard") }

            let found = try #require(
                vanguard,
                "Vanguard not found in \(detectIn.episodeTitle) after learning from \(learnFrom.episodeTitle)"
            )

            // The known truth span for Vanguard in each episode.
            let truth = try #require(
                detectIn.segments.first { ($0.sponsor ?? "").lowercased().contains("vanguard") }
            )
            let iou = EvalMetrics.iou(found.startMs...found.endMs, truth.startMs...truth.endMs)
            #expect(iou >= 0.5, "match at \(found.startMs)–\(found.endMs) vs truth \(truth.startMs)–\(truth.endMs)")
        }
    }

    /// The ad-free episode is the false-positive trap: patterns learned from
    /// every other show must find nothing in 94 minutes of conversation that
    /// happens to be *about* podcast advertising.
    @Test("Patterns from all shows produce no false alarms on the ad-free episode")
    func noFalsePositivesOnControl() throws {
        let episodes = try Corpus.load(from: CorpusLocation.url)
        let control = try #require(episodes.first { $0.show == "Podcasting 2.0" })
        let others = episodes.filter { $0.show != control.show }

        let detector = PatternBaselineDetector(patterns: PatternBaselineDetector.learn(from: others))
        let transcript = try #require(control.timedTranscript)

        #expect(detector.detectSpans(in: transcript).isEmpty)
    }

    /// Leave-one-out over the whole corpus: for each episode, learn from all
    /// the others and measure. This is the number that improves as the corpus
    /// grows, and the baseline every later stage must beat.
    @Test("Leave-one-out baseline over the full corpus")
    func leaveOneOutBaseline() throws {
        let episodes = try Corpus.load(from: CorpusLocation.url)
        var total = EvalResult(truePositives: 0, falsePositives: 0, falseNegatives: 0, boundaryErrorsMs: [])

        for (index, target) in episodes.enumerated() {
            var others = episodes
            others.remove(at: index)

            let detector = PatternBaselineDetector(patterns: PatternBaselineDetector.learn(from: others))
            guard let transcript = target.timedTranscript else { continue }

            let predicted = detector.detectSpans(in: transcript)
            let truth = EvalMetrics.mergeSpans(target.adSpans())
            let result = EvalMetrics.evaluate(predicted: predicted, truth: truth)
            total = total + result

            print(String(
                format: "  %-28@ P %.2f  R %.2f  F1 %.2f  (tp %d fp %d fn %d)",
                "\(target.show.prefix(16))/\(target.episodeTitle.prefix(10))" as NSString,
                result.precision, result.recall, result.f1,
                result.truePositives, result.falsePositives, result.falseNegatives
            ))
        }

        print(String(
            format: "  TOTAL  P %.2f  R %.2f  F1 %.2f  boundary %.0fms",
            total.precision, total.recall, total.f1, total.meanBoundaryErrorMs
        ))

        // Floor assertions, not targets: cross-episode repetition must be
        // caught (Tech Brew), and precision must stay high — a false positive
        // cuts real content and is the worse failure (§5.3.5).
        #expect(total.truePositives >= 2)
        #expect(total.precision >= 0.5)
    }
}
