import CodexCastCore
import Foundation

/// Stage 1's fuzzy tier, in its simplest usable form: learn the words of
/// confirmed ads, then find near-matching stretches of any transcript.
///
/// No model, no network, no training — just "I have heard this script before."
/// Because patterns are text rather than timestamps, dynamic ad insertion does
/// not defeat them: the same read at 4:12 today and 7:45 next week matches both
/// times (§4.1). This type is also the reference implementation the eval
/// harness uses to prove the learning layer's core bet on real corpus data.
public struct PatternBaselineDetector: Sendable {
    /// A learned ad script.
    public struct Pattern: Sendable {
        public var text: String
        public var tokens: Set<String>
        public var durationMs: Int
        public var sponsor: String?

        public init(text: String, durationMs: Int, sponsor: String? = nil) {
            self.text = text
            self.tokens = Self.tokenize(text)
            self.durationMs = durationMs
            self.sponsor = sponsor
        }

        /// Word trigrams ("shingles"). Single words match everywhere; runs of
        /// three words are distinctive enough to identify a script while
        /// tolerating host improvisation between them.
        static func tokenize(_ text: String) -> Set<String> {
            let words = normalize(text).split(separator: " ").map(String.init)
            guard words.count >= 3 else { return Set(words) }
            var shingles = Set<String>()
            for index in 0...(words.count - 3) {
                shingles.insert(words[index...(index + 2)].joined(separator: " "))
            }
            return shingles
        }

        static func normalize(_ text: String) -> String {
            text.lowercased()
                .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    public var patterns: [Pattern]
    /// Fraction of shared trigrams (Jaccard) above which a window matches.
    /// 0.35 tolerates the read-to-read variation seen in real host reads while
    /// staying far above topical-similarity noise.
    public var matchThreshold: Double

    public init(patterns: [Pattern] = [], matchThreshold: Double = 0.35) {
        self.patterns = patterns
        self.matchThreshold = matchThreshold
    }

    // MARK: - Learning

    /// Extracts patterns from labeled episodes: the transcript text inside each
    /// confirmed ad span, exactly what the Confirm correction stores (§6.4).
    public static func learn(from episodes: [CorpusEpisode]) -> [Pattern] {
        var patterns: [Pattern] = []
        for episode in episodes {
            guard let transcript = episode.timedTranscript else { continue }
            for segment in episode.segments
            where segment.segmentKind == .ad || segment.segmentKind == .sponsorRead {
                let text = transcript.segments
                    .filter { $0.startMs < segment.endMs && segment.startMs < $0.endMs }
                    .map(\.text)
                    .joined(separator: " ")
                guard !text.isEmpty else { continue }
                patterns.append(
                    Pattern(
                        text: text,
                        durationMs: segment.endMs - segment.startMs,
                        sponsor: segment.sponsor
                    )
                )
            }
        }
        return patterns
    }

    // MARK: - Detection

    public struct Match: Sendable {
        public var startMs: Int
        public var endMs: Int
        public var score: Double
        public var sponsor: String?
    }

    /// Slides a window of transcript cues sized to each pattern across the
    /// episode and reports stretches whose wording matches a learned script.
    public func detect(in transcript: TimedTranscript) -> [Match] {
        let cues = transcript.segments
        guard !cues.isEmpty, !patterns.isEmpty else { return [] }

        var matches: [Match] = []

        for pattern in patterns {
            guard !pattern.tokens.isEmpty else { continue }
            var best: Match?

            var start = 0
            while start < cues.count {
                // Grow the window until it spans roughly the pattern's length.
                var end = start
                while end + 1 < cues.count,
                      cues[end].endMs - cues[start].startMs < pattern.durationMs {
                    end += 1
                }

                let text = cues[start...end].map(\.text).joined(separator: " ")
                let windowTokens = Pattern.tokenize(text)
                if !windowTokens.isEmpty {
                    let intersection = pattern.tokens.intersection(windowTokens).count
                    let union = pattern.tokens.union(windowTokens).count
                    let score = union == 0 ? 0 : Double(intersection) / Double(union)

                    if score >= matchThreshold, score > (best?.score ?? 0) {
                        best = Match(
                            startMs: cues[start].startMs,
                            endMs: cues[end].endMs,
                            score: score,
                            sponsor: pattern.sponsor
                        )
                    }
                }

                // Half-window hops: fine enough that a true match cannot fall
                // between windows, cheap enough for a 90-minute episode.
                let hop = max(1, (end - start) / 2)
                start += hop
            }

            if let best {
                matches.append(best)
            }
        }

        return matches.sorted { $0.startMs < $1.startMs }
    }

    /// Detection spans, merged into skip blocks (§5.5).
    public func detectSpans(in transcript: TimedTranscript) -> [ClosedRange<Int>] {
        EvalMetrics.mergeSpans(detect(in: transcript).map { $0.startMs...$0.endMs })
    }
}
