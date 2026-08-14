import Foundation

/// "The beginning of this show is always an ad" — a per-show structural prior
/// (§5.1, §6.3). Stage 0 proposes segments from these before any model runs.
///
/// A rule carries a duration *distribution* (Welford mean/M2, never samples)
/// and a reliability record. Machine rules are hypotheses: they earn trust
/// through hits and auto-disable when they miss. User rules are instructions:
/// they never disable and Stage 2 never overrides them.
public struct PositionRule: Hashable, Sendable, Identifiable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    /// Where in an episode the rule anchors.
    public enum Anchor: Hashable, Sendable, Codable {
        /// Pre-roll: a region starting `offsetMs` from the episode start.
        case fromStart(offsetMs: Int)
        /// Post-roll: a region ending `offsetMs` before the episode end.
        case fromEnd(offsetMs: Int)
        /// After a spoken marker — "we'll be right back".
        case afterMarker(text: String)
        /// Mid-roll at a stable relative point through the episode.
        case proportional(fraction: Double)

        public var label: String {
            switch self {
            case .fromStart(0): "At the start"
            case .fromStart(let ms): "\(ms / 1000)s after the start"
            case .fromEnd(0): "At the end"
            case .fromEnd(let ms): "\(ms / 1000)s before the end"
            case .afterMarker(let text): "After “\(String(text.prefix(30)))”"
            case .proportional(let fraction): "About \(Int(fraction * 100))% through"
            }
        }
    }

    public var id: ID
    public var podcastID: Podcast.ID
    public var anchor: Anchor
    public var meanDurationMs: Double
    /// Welford's M2 — sum of squared deviations from the running mean.
    public var m2: Double
    public var sampleCount: Int
    public var hitCount: Int
    public var missCount: Int
    public var enabled: Bool
    public var userCreated: Bool
    public var createdAt: Date

    public init(
        id: ID = ID(),
        podcastID: Podcast.ID,
        anchor: Anchor,
        meanDurationMs: Double = 0,
        m2: Double = 0,
        sampleCount: Int = 0,
        hitCount: Int = 0,
        missCount: Int = 0,
        enabled: Bool = true,
        userCreated: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.podcastID = podcastID
        self.anchor = anchor
        self.meanDurationMs = meanDurationMs
        self.m2 = m2
        self.sampleCount = sampleCount
        self.hitCount = hitCount
        self.missCount = missCount
        self.enabled = enabled
        self.userCreated = userCreated
        self.createdAt = createdAt
    }

    // MARK: - Learning (§6.3)

    /// Folds one observed duration into the distribution (Welford's online
    /// algorithm) and counts the hit.
    public mutating func recordHit(durationMs: Int) {
        sampleCount += 1
        let value = Double(durationMs)
        let delta = value - meanDurationMs
        meanDurationMs += delta / Double(sampleCount)
        m2 += delta * (value - meanDurationMs)
        hitCount += 1
    }

    /// Counts a miss — a rejected or contradicted proposal — and applies the
    /// auto-disable policy. User rules never disable.
    public mutating func recordMiss() {
        missCount += 1
        if !userCreated, hitCount + missCount >= 6, reliability < 0.5 {
            enabled = false
        }
    }

    public var varianceMs: Double {
        sampleCount > 1 ? m2 / Double(sampleCount - 1) : 0
    }

    /// Laplace-smoothed hit rate, so one early miss doesn't kill a rule and
    /// one early hit doesn't canonize it.
    public var reliability: Double {
        Double(hitCount + 1) / Double(hitCount + missCount + 2)
    }

    // MARK: - Stage 0 proposal (§5.1)

    public struct Proposal: Hashable, Sendable {
        public var ruleID: ID
        public var startMs: Int
        public var endMs: Int
        public var confidence: Double
        public var userCreated: Bool
    }

    /// The region this rule proposes for an episode, or nil when it doesn't
    /// apply. `markerMs` is where `.afterMarker`'s text was found in the
    /// transcript, resolved by the caller — this type stays text-search-free.
    public func propose(episodeDurationMs: Int, markerMs: Int? = nil) -> Proposal? {
        guard enabled, episodeDurationMs > 0 else { return nil }
        // A rule with no observed durations yet proposes a conservative 45s.
        let duration = sampleCount > 0 ? Int(meanDurationMs) : 45_000
        guard duration >= 5_000 else { return nil }

        let start: Int
        switch anchor {
        case .fromStart(let offsetMs):
            start = offsetMs
        case .fromEnd(let offsetMs):
            start = episodeDurationMs - offsetMs - duration
        case .afterMarker:
            guard let markerMs else { return nil }
            start = markerMs
        case .proportional(let fraction):
            start = Int(Double(episodeDurationMs) * fraction) - duration / 2
        }
        let clampedStart = max(0, min(start, episodeDurationMs - duration))
        return Proposal(
            ruleID: id,
            startMs: clampedStart,
            endMs: min(clampedStart + duration, episodeDurationMs),
            confidence: userCreated ? 0.95 : reliability,
            userCreated: userCreated
        )
    }

    // MARK: - Anchor classification (§6.3)

    /// Which anchor a confirmed segment fits, for finding or creating the rule
    /// it should teach. Pre/post-roll take precedence over proportional.
    public static func anchor(
        forSegmentStartMs startMs: Int,
        endMs: Int,
        episodeDurationMs: Int
    ) -> Anchor {
        if startMs <= 120_000 {
            // Bucket to 30s so "0:05" and "0:20" starts land on one rule.
            return .fromStart(offsetMs: (startMs / 30_000) * 30_000)
        }
        if episodeDurationMs > 0, episodeDurationMs - endMs <= 120_000 {
            let offset = ((episodeDurationMs - endMs) / 30_000) * 30_000
            return .fromEnd(offsetMs: offset)
        }
        let fraction = episodeDurationMs > 0
            ? Double(startMs) / Double(episodeDurationMs)
            : 0.5
        // Buckets of 10% keep nearby mid-rolls on the same rule.
        return .proportional(fraction: (fraction * 10).rounded() / 10)
    }

    /// Whether a segment agrees with this rule's anchor — the hit test used
    /// when updating statistics from a confirmation.
    public func matches(segmentStartMs: Int, endMs: Int, episodeDurationMs: Int) -> Bool {
        Self.anchor(
            forSegmentStartMs: segmentStartMs, endMs: endMs,
            episodeDurationMs: episodeDurationMs
        ) == anchor
    }
}
