import CodexCastCore
import Foundation

/// The rules deciding whether a detected segment may auto-skip (§5.6).
///
/// Detection proposes; this gate disposes. Everything survives into the
/// database for review — the gate only controls what plays through silently.
public struct ValidationGate: Sendable {
    public struct Policy: Sendable {
        /// 5s, not 8s: short DAI spots like "this episode is sponsored by X"
        /// are real and were being excluded at 8.
        public var minimumDurationMs: Int
        public var maximumDurationMs: Int
        public var confidenceThreshold: Double
        /// Total flagged fraction above which non-user segments stop
        /// auto-skipping and the episode is flagged for review.
        public var runawayFraction: Double

        public init(
            minimumDurationMs: Int = 5_000,
            maximumDurationMs: Int = 360_000,
            confidenceThreshold: Double = 0.75,
            runawayFraction: Double = 0.4
        ) {
            self.minimumDurationMs = minimumDurationMs
            self.maximumDurationMs = maximumDurationMs
            self.confidenceThreshold = confidenceThreshold
            self.runawayFraction = runawayFraction
        }

        public static let conservative = Policy(confidenceThreshold: 0.85)
        public static let balanced = Policy(confidenceThreshold: 0.75)
        public static let aggressive = Policy(confidenceThreshold: 0.60)
    }

    public struct Outcome: Sendable {
        public var autoSkippable: [DetectedSegment]
        /// Kept, surfaced for review, never auto-skipped.
        public var reviewOnly: [DetectedSegment]
        /// The runaway guard tripped: a runaway classifier, not user intent.
        public var flaggedForReview: Bool
    }

    public var policy: Policy

    public init(policy: Policy = .balanced) {
        self.policy = policy
    }

    public func evaluate(
        segments: [DetectedSegment],
        episodeDurationMs: Int,
        neverSkipRegions: [ClosedRange<Int>] = []
    ) -> Outcome {
        var autoSkippable: [DetectedSegment] = []
        var reviewOnly: [DetectedSegment] = []

        for segment in segments {
            if segment.userState == .rejected {
                reviewOnly.append(segment)
                continue
            }

            // User-originated segments and confirmations pass unconditionally:
            // an instruction is not a hypothesis (§5.6).
            let userOwned = segment.provenance.isUserOriginated || segment.userState == .confirmed
            if userOwned {
                autoSkippable.append(segment)
                continue
            }

            let duration = segment.durationMs
            let inBounds = duration >= policy.minimumDurationMs && duration <= policy.maximumDurationMs
            let confident = segment.confidence >= policy.confidenceThreshold
            let overlapsProtected = neverSkipRegions.contains { region in
                segment.overlaps(startMs: region.lowerBound, endMs: region.upperBound)
            }

            if inBounds && confident && !overlapsProtected {
                autoSkippable.append(segment)
            } else {
                reviewOnly.append(segment)
            }
        }

        // Runaway guard: user-originated segments are excluded from BOTH the
        // numerator and the suppression. "Always skip the first 90 seconds"
        // must never be overridden because a heuristic got nervous.
        let machineFlaggedMs = autoSkippable
            .filter { !$0.provenance.isUserOriginated && $0.userState != .confirmed }
            .reduce(0) { $0 + $1.durationMs }

        let fraction = episodeDurationMs > 0
            ? Double(machineFlaggedMs) / Double(episodeDurationMs)
            : 0

        if fraction > policy.runawayFraction {
            let (kept, suppressed) = autoSkippable.partitioned { segment in
                segment.provenance.isUserOriginated || segment.userState == .confirmed
            }
            return Outcome(
                autoSkippable: kept,
                reviewOnly: reviewOnly + suppressed,
                flaggedForReview: true
            )
        }

        return Outcome(
            autoSkippable: autoSkippable,
            reviewOnly: reviewOnly,
            flaggedForReview: false
        )
    }
}

extension Array {
    /// (matching, non-matching)
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}
