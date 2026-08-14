import Foundation

/// Detects a feed transcript that disagrees with the audio on this device
/// (addendum A1).
///
/// A transcript made from the ad-free master runs increasingly EARLY after
/// each dynamically inserted ad — measured at +90s then +183s on a real
/// episode. The check: take short samples of what the audio actually says at
/// known times, find that text in the feed transcript, and compare clocks.
/// Text found at the wrong time = drift. Text not found at all = the sample
/// probably sits inside an inserted ad. Either way the feed timestamps are
/// lies, and everything downstream trusts timestamps.
public enum TranscriptDriftDetector {
    public struct Sample: Sendable {
        /// Where in the actual audio the sample was taken.
        public var audioStartMs: Int
        /// What the audio says there, per on-device transcription.
        public var text: String

        public init(audioStartMs: Int, text: String) {
            self.audioStartMs = audioStartMs
            self.text = text
        }
    }

    public struct Verdict: Sendable {
        public var isDesynced: Bool
        /// Largest |audio time − feed time| among matched samples.
        public var maxAbsOffsetMs: Int
        /// Samples whose text does not appear in the feed transcript at all.
        public var unmatchedCount: Int
        public var matchedCount: Int
    }

    /// Compares samples of the actual audio against the feed transcript.
    ///
    /// `toleranceMs` is generous on purpose: transcription timestamps and cue
    /// boundaries both wobble by seconds; inserted ads move text by minutes.
    public static func verdict(
        feed: TimedTranscript,
        samples: [Sample],
        toleranceMs: Int = 20_000
    ) -> Verdict {
        var maxAbsOffset = 0
        var unmatched = 0
        var matched = 0

        for sample in samples {
            let sampleTokens = tokens(sample.text)
            guard sampleTokens.count >= 8 else { continue }

            // Best token-overlap window of consecutive feed cues.
            var best: (overlap: Double, startMs: Int)?
            let cues = feed.segments
            for index in cues.indices {
                var windowTokens: Set<String> = []
                var last = index
                while last < cues.count, cues[last].startMs - cues[index].startMs < 40_000 {
                    windowTokens.formUnion(tokens(cues[last].text))
                    last += 1
                }
                let overlap = Double(sampleTokens.intersection(windowTokens).count)
                    / Double(sampleTokens.count)
                if overlap > (best?.overlap ?? 0) {
                    best = (overlap, cues[index].startMs)
                }
            }

            if let best, best.overlap >= 0.6 {
                matched += 1
                maxAbsOffset = max(maxAbsOffset, abs(sample.audioStartMs - best.startMs))
            } else {
                unmatched += 1
            }
        }

        // Desynced when any matched sample sits far from where the feed says,
        // or when most samples don't exist in the feed at all (we sampled
        // inserted ads). One unmatched sample alone is not damning — it may
        // just be mis-transcribed.
        let isDesynced = maxAbsOffset > toleranceMs
            || (unmatched >= 2 && unmatched > matched)
        return Verdict(
            isDesynced: isDesynced,
            maxAbsOffsetMs: maxAbsOffset,
            unmatchedCount: unmatched,
            matchedCount: matched
        )
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }
}
