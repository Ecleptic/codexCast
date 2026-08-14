import Foundation

/// Scores a detector's proposed ad spans against ground truth (§13).
///
/// Matching is by overlap: a predicted span counts as a hit when its
/// intersection-over-union with a truth span is at least `iouThreshold`.
/// Per §0.2, segments are chapter markers, not surgical edits, so the default
/// threshold rewards "found the ad, roughly right" and boundary error is
/// reported separately rather than folded into the match decision.
public struct EvalResult: Sendable {
    public var truePositives: Int
    public var falsePositives: Int
    public var falseNegatives: Int
    /// |Δstart| + |Δend| per matched pair, in milliseconds.
    public var boundaryErrorsMs: [Int]

    public var precision: Double {
        let denominator = truePositives + falsePositives
        return denominator == 0 ? 0 : Double(truePositives) / Double(denominator)
    }

    public var recall: Double {
        let denominator = truePositives + falseNegatives
        return denominator == 0 ? 0 : Double(truePositives) / Double(denominator)
    }

    public var f1: Double {
        let p = precision, r = recall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }

    public var meanBoundaryErrorMs: Double {
        boundaryErrorsMs.isEmpty
            ? 0
            : Double(boundaryErrorsMs.reduce(0, +)) / Double(boundaryErrorsMs.count)
    }

    public static func + (lhs: EvalResult, rhs: EvalResult) -> EvalResult {
        EvalResult(
            truePositives: lhs.truePositives + rhs.truePositives,
            falsePositives: lhs.falsePositives + rhs.falsePositives,
            falseNegatives: lhs.falseNegatives + rhs.falseNegatives,
            boundaryErrorsMs: lhs.boundaryErrorsMs + rhs.boundaryErrorsMs
        )
    }
}

public enum EvalMetrics {
    public static func evaluate(
        predicted: [ClosedRange<Int>],
        truth: [ClosedRange<Int>],
        iouThreshold: Double = 0.5
    ) -> EvalResult {
        var matchedTruth = Set<Int>()
        var truePositives = 0
        var boundaryErrors: [Int] = []

        // Greedy best-first matching: each prediction claims the unmatched
        // truth span it overlaps best. One prediction cannot satisfy two truth
        // spans, and duplicate predictions of the same span count as false
        // positives rather than free hits.
        for span in predicted {
            var bestIndex: Int?
            var bestIoU = 0.0
            for (index, truthSpan) in truth.enumerated() where !matchedTruth.contains(index) {
                let value = iou(span, truthSpan)
                if value > bestIoU {
                    bestIoU = value
                    bestIndex = index
                }
            }
            if let index = bestIndex, bestIoU >= iouThreshold {
                matchedTruth.insert(index)
                truePositives += 1
                let truthSpan = truth[index]
                boundaryErrors.append(
                    abs(span.lowerBound - truthSpan.lowerBound) + abs(span.upperBound - truthSpan.upperBound)
                )
            }
        }

        return EvalResult(
            truePositives: truePositives,
            falsePositives: predicted.count - truePositives,
            falseNegatives: truth.count - matchedTruth.count,
            boundaryErrorsMs: boundaryErrors
        )
    }

    static func iou(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> Double {
        let intersection = max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        guard intersection > 0 else { return 0 }
        let union = (a.upperBound - a.lowerBound) + (b.upperBound - b.lowerBound) - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// Merges overlapping or near-adjacent spans (§5.5's chunking, applied to
    /// predictions before scoring so back-to-back detections of one ad break
    /// count as the single block a listener experiences).
    public static func mergeSpans(
        _ spans: [ClosedRange<Int>],
        gapToleranceMs: Int = 5_000
    ) -> [ClosedRange<Int>] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = [sorted[0]]

        for span in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if span.lowerBound <= last.upperBound + gapToleranceMs {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
