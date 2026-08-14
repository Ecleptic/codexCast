import Foundation

/// Turns raw stage scores into calibrated confidence from the listener's own
/// correction history (§5.7).
///
/// Raw scores across stages are not comparable, and a small model's
/// self-reported confidence is frequently near-constant. What IS comparable
/// is "when this stage said 80%, how often was the user's verdict 'yes'" —
/// tracked per stage and score decile, smoothed with a Beta(2,2) prior so
/// two data points don't produce certainty.
public struct ConfidenceCalibrator: Sendable {
    public struct Bin: Hashable, Sendable {
        public var stage: String
        public var decile: Int
        public var proposals: Int
        public var confirms: Int
        public var rejects: Int

        public init(stage: String, decile: Int, proposals: Int, confirms: Int, rejects: Int) {
            self.stage = stage
            self.decile = decile
            self.proposals = proposals
            self.confirms = confirms
            self.rejects = rejects
        }
    }

    private let lookup: [String: Bin]

    public init(bins: [Bin]) {
        var lookup: [String: Bin] = [:]
        for bin in bins {
            lookup["\(bin.stage)#\(bin.decile)"] = bin
        }
        self.lookup = lookup
    }

    public static func decile(for rawConfidence: Double) -> Int {
        min(9, max(0, Int(rawConfidence * 10)))
    }

    /// Smoothed empirical precision for this stage and decile. With no
    /// history it is 0.5 — "unproven", below every auto-skip bar, which is
    /// exactly where an untested stage belongs. Never reports above 0.98.
    public func calibrated(stage: String, rawConfidence: Double) -> Double {
        let bin = lookup["\(stage)#\(Self.decile(for: rawConfidence))"]
        let confirms = Double(bin?.confirms ?? 0)
        let rejects = Double(bin?.rejects ?? 0)
        return min(0.98, (confirms + 2) / (confirms + rejects + 4))
    }

    /// Whether calibration for a stage is meaningful yet. Below this floor
    /// the raw score passes through untouched — calibrating on air would
    /// flatten everything to 0.5 and hide real signal.
    public func hasHistory(stage: String, minimumOutcomes: Int = 5) -> Bool {
        lookup.values
            .filter { $0.stage == stage }
            .reduce(0) { $0 + $1.confirms + $1.rejects } >= minimumOutcomes
    }

    // MARK: - Degenerate-confidence fallback (§5.7)

    /// True when a stage's self-reported confidence carries no information:
    /// near-identical scores across recent segments leave nothing to
    /// calibrate against.
    public static func isDegenerate(recentRawConfidences: [Double]) -> Bool {
        guard recentRawConfidences.count >= 20 else { return false }
        let mean = recentRawConfidences.reduce(0, +) / Double(recentRawConfidences.count)
        let variance = recentRawConfidences
            .reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(recentRawConfidences.count)
        return variance.squareRoot() < 0.05
    }

    /// Agreement-derived confidence: the fraction of overlapping transcript
    /// windows that independently proposed the segment — the §5.3.2 overlap
    /// generates this for free. Bounded away from both extremes: one window
    /// agreeing with itself is not proof.
    public static func agreementConfidence(agreeing: Int, possible: Int) -> Double {
        guard possible > 0 else { return 0.5 }
        let fraction = Double(min(agreeing, possible)) / Double(possible)
        return 0.35 + fraction * 0.5
    }
}
