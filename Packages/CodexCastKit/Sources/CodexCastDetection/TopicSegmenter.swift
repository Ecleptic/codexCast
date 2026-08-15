import CodexCastCore
import Foundation
import NaturalLanguage

/// Splits a transcript into topically coherent chapters using the system's
/// contextual sentence embeddings — TextTiling with TreeSeg-style block
/// smoothing (arXiv 2407.12028, 2106.12978).
///
/// Why this exists for AD DETECTION: a mid-roll ad sits deep in a long
/// transcript surrounded by editorial content in the same host's voice — the
/// textbook case of context dilution for a windowed classifier, and exactly
/// where the two-pass sweep measured weakest. An inserted ad IS a topic
/// break; classifying one chapter at a time puts the whole ad, and only the
/// ad's neighborhood, in front of the verifier. The same chapters are a
/// user-facing feature (§5.8) for shows that publish none.
public enum TopicSegmenter {
    public struct Chapter: Hashable, Sendable {
        public var startMs: Int
        public var endMs: Int
        /// Indices into the transcript's cue array.
        public var cueRange: ClosedRange<Int>

        public var durationMs: Int { max(0, endMs - startMs) }
    }

    public struct Configuration: Sendable {
        /// Sentences averaged with each cue to denoise before comparing.
        public var smoothingWindow: Int = 4
        /// Boundary threshold: distance peaks above mean + k·stddev.
        public var depthSigma: Double = 0.6
        /// Ads run 5s–90s; chapters shorter than this merge into a neighbor.
        public var minChapterMs: Int = 25_000
        /// Beyond this a chapter splits at its strongest internal peak, so a
        /// long monologue can't hide an ad in its middle.
        public var maxChapterMs: Int = 420_000

        public init() {}
    }

    /// Chapters for a transcript, or nil when the embedding model is not
    /// available on this system. Blocking on the embedding pass — call off
    /// the main actor.
    public static func chapters(
        for transcript: TimedTranscript,
        configuration: Configuration = Configuration()
    ) -> [Chapter]? {
        let cues = transcript.segments
        guard cues.count > 6 else { return nil }
        guard let vectors = embedCues(cues) else { return nil }

        // Block-smooth: each position becomes the mean of itself and its W
        // predecessors (TreeSeg's denoising trick).
        let smoothed = blockSmooth(vectors, window: configuration.smoothingWindow)

        // Distance between consecutive smoothed embeddings; peaks = shifts.
        var distances: [Double] = [0]
        for index in 1..<smoothed.count {
            distances.append(1 - cosine(smoothed[index - 1], smoothed[index]))
        }
        let scores = movingAverage(distances, window: 3)

        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scores.count)
        let threshold = mean + configuration.depthSigma * variance.squareRoot()

        // Local maxima above threshold are boundaries.
        var boundaries: [Int] = []
        for index in 1..<(scores.count - 1)
        where scores[index] > threshold
            && scores[index] >= scores[index - 1]
            && scores[index] >= scores[index + 1] {
            boundaries.append(index)
        }

        return build(
            boundaries: boundaries, cues: cues, scores: scores,
            configuration: configuration
        )
    }

    // MARK: - Assembly

    static func build(
        boundaries: [Int],
        cues: [TimedTranscript.Segment],
        scores: [Double],
        configuration: Configuration
    ) -> [Chapter] {
        var edges = [0] + boundaries + [cues.count]
        edges = Array(Set(edges)).sorted()

        var chapters: [Chapter] = []
        for index in 0..<(edges.count - 1) {
            let lower = edges[index]
            let upper = edges[index + 1] - 1
            guard upper >= lower else { continue }
            chapters.append(Chapter(
                startMs: cues[lower].startMs,
                endMs: cues[upper].endMs,
                cueRange: lower...upper
            ))
        }

        // Merge runts into the nearer (shorter-join) neighbor.
        var merged: [Chapter] = []
        for chapter in chapters {
            if chapter.durationMs < configuration.minChapterMs, let last = merged.last {
                merged[merged.count - 1] = Chapter(
                    startMs: last.startMs, endMs: chapter.endMs,
                    cueRange: last.cueRange.lowerBound...chapter.cueRange.upperBound
                )
            } else {
                merged.append(chapter)
            }
        }

        // Split over-long chapters at their strongest internal peak.
        var final: [Chapter] = []
        for chapter in merged {
            var queue = [chapter]
            while let current = queue.first {
                queue.removeFirst()
                if current.durationMs <= configuration.maxChapterMs
                    || current.cueRange.count < 6 {
                    final.append(current)
                    continue
                }
                let interior = (current.cueRange.lowerBound + 2)...(current.cueRange.upperBound - 2)
                guard let split = interior.max(by: { scores[$0] < scores[$1] }) else {
                    final.append(current)
                    continue
                }
                queue.insert(Chapter(
                    startMs: cues[split].startMs, endMs: current.endMs,
                    cueRange: split...current.cueRange.upperBound
                ), at: 0)
                queue.insert(Chapter(
                    startMs: current.startMs, endMs: cues[split - 1].endMs,
                    cueRange: current.cueRange.lowerBound...(split - 1)
                ), at: 0)
            }
        }
        return final.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Embeddings

    static func embedCues(_ cues: [TimedTranscript.Segment]) -> [[Double]]? {
        guard let embedding = NLContextualEmbedding(language: .english),
              embedding.hasAvailableAssets || (try? embedding.load()) != nil
        else { return nil }
        if !embedding.hasAvailableAssets { return nil }
        try? embedding.load()

        var vectors: [[Double]] = []
        vectors.reserveCapacity(cues.count)
        for cue in cues {
            guard let result = try? embedding.embeddingResult(
                for: cue.text, language: .english
            ) else { return nil }
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var count = 0
            result.enumerateTokenVectors(in: cue.text.startIndex..<cue.text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            vectors.append(sum.map { $0 / Double(count) })
        }
        return vectors
    }

    // MARK: - Vector math

    static func blockSmooth(_ vectors: [[Double]], window: Int) -> [[Double]] {
        guard window > 1 else { return vectors }
        var result: [[Double]] = []
        result.reserveCapacity(vectors.count)
        for index in vectors.indices {
            let lower = max(0, index - window + 1)
            var sum = [Double](repeating: 0, count: vectors[index].count)
            for position in lower...index {
                for (dimension, value) in vectors[position].enumerated() {
                    sum[dimension] += value
                }
            }
            let count = Double(index - lower + 1)
            result.append(sum.map { $0 / count })
        }
        return result
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > window else { return values }
        return values.indices.map { index in
            let lower = max(0, index - window / 2)
            let upper = min(values.count - 1, index + window / 2)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
