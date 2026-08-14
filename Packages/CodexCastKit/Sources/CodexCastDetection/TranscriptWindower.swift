import CodexCastCore
import Foundation

/// Slices a transcript into classifier windows per §5.3.2.
///
/// The window budget is the dominant constraint of the whole detection design:
/// the on-device model's context covers instructions, prompt, and output
/// combined, so windows target 3–5 minutes with 60–90 seconds of overlap so an
/// ad straddling a boundary is fully visible in one window.
public enum TranscriptWindower {
    public struct Configuration: Sendable {
        public var windowMs: Int
        public var overlapMs: Int
        /// Below this, merge into the neighbour instead of dispatching a stub
        /// (§5.3.2's minimum viable window).
        public var minimumViableMs: Int

        public init(
            windowMs: Int = 240_000,
            overlapMs: Int = 75_000,
            minimumViableMs: Int = 90_000
        ) {
            self.windowMs = windowMs
            self.overlapMs = overlapMs
            self.minimumViableMs = minimumViableMs
        }

        /// Rough chars-per-token for English speech; used only for sizing,
        /// never for hard truncation.
        public static let charsPerToken = 3.8

        /// §5.3.2: never hardcode a token budget. The window duration is
        /// derived from the model's context size and THIS transcript's own
        /// measured word density — a fast panel show gets shorter windows
        /// than a slow interview, and both fill the context instead of
        /// trusting a constant chosen on some other episode.
        public static func fitted(
            to transcript: TimedTranscript,
            contextTokens: Int,
            reservedTokens: Int
        ) -> Configuration {
            let durationMs = max(1, transcript.durationMs)
            // +12 chars per cue covers the "[m:ss] " stamp the prompt adds.
            let totalChars = transcript.segments.reduce(0) { $0 + $1.text.count + 12 }
            let tokensPerMs = Double(totalChars) / charsPerToken / Double(durationMs)
            let budget = Double(max(500, contextTokens - reservedTokens))
            var windowMs = tokensPerMs > 0 ? Int(budget / tokensPerMs) : 240_000
            // Rails: below 2 minutes an ad barely fits with context around
            // it; above 8 the timestamps get sloppy.
            windowMs = min(max(windowMs, 120_000), 480_000)
            return Configuration(
                windowMs: windowMs,
                overlapMs: max(45_000, windowMs / 4),
                minimumViableMs: min(90_000, windowMs / 2)
            )
        }
    }

    /// Cuts windows, marking already-resolved regions rather than excising
    /// them, and skipping a window only when *everything* in it is resolved.
    public static func windows(
        for transcript: TimedTranscript,
        resolved: [TranscriptWindow.ResolvedRegion] = [],
        configuration: Configuration = Configuration()
    ) -> [TranscriptWindow] {
        let cues = transcript.segments
        guard !cues.isEmpty else { return [] }

        var slices: [[TimedTranscript.Segment]] = []
        var windowStart = cues.first!.startMs
        let end = cues.last!.endMs

        while windowStart < end {
            let windowEnd = windowStart + configuration.windowMs
            let slice = cues.filter { $0.startMs < windowEnd && $0.endMs > windowStart }
            if !slice.isEmpty {
                slices.append(slice)
            }
            windowStart += configuration.windowMs - configuration.overlapMs
        }

        // Fold a trailing stub into its neighbour rather than dispatching it.
        if let last = slices.last,
           slices.count > 1,
           (last.last!.endMs - last.first!.startMs) < configuration.minimumViableMs {
            let stub = slices.removeLast()
            var previous = slices.removeLast()
            for cue in stub where !previous.contains(cue) {
                previous.append(cue)
            }
            slices.append(previous)
        }

        var windows: [TranscriptWindow] = []
        for slice in slices {
            let sliceStart = slice.first!.startMs
            let sliceEnd = slice.last!.endMs
            let overlapping = resolved.filter { $0.startMs < sliceEnd && sliceStart < $0.endMs }

            // Skip only when every cue is inside a resolved region (§5.3.2).
            let allResolved = slice.allSatisfy { cue in
                overlapping.contains { cue.startMs >= $0.startMs && cue.endMs <= $0.endMs }
            }
            if allResolved && !overlapping.isEmpty {
                continue
            }

            windows.append(TranscriptWindow(
                index: windows.count,
                cues: slice,
                resolvedRegions: overlapping
            ))
        }
        return windows
    }

    /// Deduplicates findings across overlapping windows: findings overlapping
    /// more than half merge, taking the union of bounds and the max confidence
    /// (§5.3.2). The overlap also yields the agreement signal §5.7 uses when
    /// model confidence turns out to be degenerate.
    public static func deduplicate(_ findings: [WindowFinding]) -> [WindowFinding] {
        let sorted = findings.sorted { $0.startMs < $1.startMs }
        var merged: [WindowFinding] = []

        for finding in sorted {
            if let last = merged.last, overlapFraction(last, finding) > 0.5 {
                var union = last
                union.startMs = min(last.startMs, finding.startMs)
                union.endMs = max(last.endMs, finding.endMs)
                union.confidence = max(last.confidence, finding.confidence)
                union.sponsor = last.sponsor ?? finding.sponsor
                union.agreementCount = last.agreementCount + finding.agreementCount
                merged[merged.count - 1] = union
            } else {
                merged.append(finding)
            }
        }
        return merged
    }

    static func overlapFraction(_ a: WindowFinding, _ b: WindowFinding) -> Double {
        let intersection = max(0, min(a.endMs, b.endMs) - max(a.startMs, b.startMs))
        let shorter = max(1, min(a.endMs - a.startMs, b.endMs - b.startMs))
        return Double(intersection) / Double(shorter)
    }
}
