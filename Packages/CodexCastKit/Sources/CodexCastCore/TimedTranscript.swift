import Foundation

/// A transcript with millisecond timings — the input every detection stage
/// consumes. Timings are load-bearing: the whole app is boundary arithmetic,
/// so an untimed transcript is useless here (§9.9).
public struct TimedTranscript: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// Supplied by the feed via `<podcast:transcript>`. Free, instant,
        /// often more accurate, and it skips the most expensive pipeline step.
        case podcasting20
        /// Produced locally by `SpeechAnalyzer`.
        case onDevice
    }

    public var source: Source
    public var segments: [Segment]

    public init(source: Source, segments: [Segment]) {
        self.source = source
        self.segments = segments.sorted { $0.startMs < $1.startMs }
    }

    public struct Segment: Hashable, Sendable, Codable {
        public var startMs: Int
        public var endMs: Int
        public var text: String
        /// Speaker label where the source provides one. WebVTT voice spans
        /// (`<v Chris>`) give this away for free on some feeds, and a change of
        /// speaker is one of the strongest human cues that an ad has started.
        public var speaker: String?

        public init(startMs: Int, endMs: Int, text: String, speaker: String? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.speaker = speaker
        }

        public var durationMs: Int { max(0, endMs - startMs) }
    }

    public var isEmpty: Bool { segments.isEmpty }

    public var durationMs: Int { segments.last?.endMs ?? 0 }

    public var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// The transcript-segment boundaries nearest a time, used to snap
    /// model-emitted timestamps in post-processing (§5.3.4). Returns the
    /// closest boundary in either direction.
    public func nearestBoundary(toMs target: Int) -> Int? {
        var boundaries: [Int] = []
        boundaries.reserveCapacity(segments.count * 2)
        for segment in segments {
            boundaries.append(segment.startMs)
            boundaries.append(segment.endMs)
        }
        return boundaries.min { abs($0 - target) < abs($1 - target) }
    }

    /// The spoken text overlapping a time range — what a detected segment
    /// actually said, for pattern extraction and negative exemplars (§6.6).
    public func text(fromMs: Int, toMs: Int) -> String {
        segments
            .filter { $0.endMs > fromMs && $0.startMs < toMs }
            .map(\.text)
            .joined(separator: " ")
    }
}
