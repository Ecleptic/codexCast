import Foundation

/// Energy-based voice activity detection over short frames.
///
/// Deliberately classical, not neural. §5.4 wants boundary snapping kept cheap,
/// and §10.2 wants silence trimming during playback — both need the same thing,
/// so there is one implementation with two callers rather than two that drift.
public struct SilenceDetector: Sendable {
    /// Frame length in milliseconds. 20ms is short enough to place a boundary
    /// accurately and long enough that RMS is stable.
    public var frameMs: Int
    /// Frames quieter than this, relative to the passage's own loudness, count
    /// as silence. Relative rather than absolute because podcast mastering
    /// levels vary enormously between shows and between speakers.
    public var relativeThreshold: Double
    /// Absolute floor, so a passage of near-total silence does not have its own
    /// noise floor treated as speech.
    public var absoluteFloor: Double

    public init(
        frameMs: Int = 20,
        // 0.05, down from 0.08: a softly spoken one-syllable sentence
        // ("Yeah.") between two pauses was falling under the old threshold,
        // merging pause+word+pause into ONE gap — which trimming then
        // hopped over entirely, swallowing the word (field report).
        relativeThreshold: Double = 0.05,
        absoluteFloor: Double = 0.002
    ) {
        self.frameMs = frameMs
        self.relativeThreshold = relativeThreshold
        self.absoluteFloor = absoluteFloor
    }

    public struct Gap: Hashable, Sendable, Codable {
        public var startMs: Int
        public var endMs: Int

        public init(startMs: Int, endMs: Int) {
            self.startMs = startMs
            self.endMs = endMs
        }

        public var durationMs: Int { max(0, endMs - startMs) }
        public var midpointMs: Int { startMs + durationMs / 2 }
    }

    /// Root-mean-square amplitude per frame.
    public func frameEnergies(samples: [Float], sampleRate: Double) -> [Double] {
        guard sampleRate > 0 else { return [] }
        let frameLength = max(1, Int(sampleRate * Double(frameMs) / 1000))
        guard samples.count >= frameLength else { return [] }

        var energies: [Double] = []
        energies.reserveCapacity(samples.count / frameLength)

        var index = 0
        while index + frameLength <= samples.count {
            var sum = 0.0
            for offset in index..<(index + frameLength) {
                let value = Double(samples[offset])
                sum += value * value
            }
            energies.append((sum / Double(frameLength)).squareRoot())
            index += frameLength
        }
        return energies
    }

    /// Silence gaps of at least `minimumDurationMs`.
    ///
    /// Stage 3 snaps segment boundaries to the nearest gap of 180ms or more;
    /// silence trimming uses a similar signal to shorten pauses during playback.
    public func gaps(
        samples: [Float],
        sampleRate: Double,
        minimumDurationMs: Int = 180,
        startOffsetMs: Int = 0
    ) -> [Gap] {
        gaps(
            energies: frameEnergies(samples: samples, sampleRate: sampleRate),
            minimumDurationMs: minimumDurationMs,
            startOffsetMs: startOffsetMs
        )
    }

    /// Same thresholding, starting from precomputed frame energies — the entry
    /// point for whole-file analysis, where samples are streamed in chunks and
    /// only the energies are kept.
    public func gaps(
        energies: [Double],
        minimumDurationMs: Int = 180,
        startOffsetMs: Int = 0
    ) -> [Gap] {
        guard !energies.isEmpty else { return [] }

        // A percentile rather than the mean: a passage that is mostly speech
        // should not have its threshold dragged up by a few loud frames.
        let sorted = energies.sorted()
        let reference = sorted[Int(Double(sorted.count) * 0.9)]
        let threshold = max(reference * relativeThreshold, absoluteFloor)

        var gaps: [Gap] = []
        var runStart: Int?

        for (index, energy) in energies.enumerated() {
            if energy <= threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                appendGap(from: start, to: index, into: &gaps, minimumDurationMs: minimumDurationMs, startOffsetMs: startOffsetMs)
                runStart = nil
            }
        }
        if let start = runStart {
            appendGap(from: start, to: energies.count, into: &gaps, minimumDurationMs: minimumDurationMs, startOffsetMs: startOffsetMs)
        }

        return gaps
    }

    private func appendGap(
        from startFrame: Int,
        to endFrame: Int,
        into gaps: inout [Gap],
        minimumDurationMs: Int,
        startOffsetMs: Int
    ) {
        let startMs = startOffsetMs + startFrame * frameMs
        let endMs = startOffsetMs + endFrame * frameMs
        guard endMs - startMs >= minimumDurationMs else { return }
        gaps.append(Gap(startMs: startMs, endMs: endMs))
    }

    /// Snaps a proposed boundary to the nearest silence gap within `toleranceMs`.
    ///
    /// Returns nil when there is no gap to snap to, in which case §5.4 says to
    /// keep the transcript boundary and widen the content side slightly —
    /// better to include a fragment of ad than to clip speech.
    public func snap(
        boundaryMs: Int,
        toGaps gaps: [Gap],
        toleranceMs: Int = 2_000
    ) -> Int? {
        let candidates = gaps
            .map(\.midpointMs)
            .filter { abs($0 - boundaryMs) <= toleranceMs }
        return candidates.min { abs($0 - boundaryMs) < abs($1 - boundaryMs) }
    }
}
