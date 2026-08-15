import CodexCastCore
import Foundation

/// Finds where quoted words occur in a transcript.
///
/// Small on-device models are bad clocks: asked for timestamps they miss by
/// 20–44 seconds. But they are good copyists — asked to quote the first and
/// last words of an ad verbatim from the prompt, they usually can. This turns
/// boundary placement from arithmetic the model can't do into a string
/// search we can: locate the quote, take the containing cue's edge.
public enum TranscriptQuoteLocator {
    /// The span of transcript cues best matching the quoted words, or nil
    /// when nothing scores above the floor. `nearMs`/`searchRadiusMs` bound
    /// the search so a phrase repeated elsewhere in the episode can't win.
    public static func locate(
        quote: String,
        in transcript: TimedTranscript,
        nearMs: Int? = nil,
        searchRadiusMs: Int = 150_000
    ) -> (startMs: Int, endMs: Int)? {
        let quoteTokens = tokenize(quote)
        guard quoteTokens.count >= 3 else { return nil }

        // Flatten cues into one token stream, remembering each token's cue.
        var tokens: [String] = []
        var cueIndex: [Int] = []
        for (index, cue) in transcript.segments.enumerated() {
            if let nearMs, abs(cue.startMs - nearMs) > searchRadiusMs { continue }
            for token in tokenize(cue.text) {
                tokens.append(token)
                cueIndex.append(index)
            }
        }
        guard tokens.count >= quoteTokens.count else { return nil }

        var best: (score: Double, start: Int)?
        for start in 0...(tokens.count - quoteTokens.count) {
            var hits = 0
            for offset in 0..<quoteTokens.count where tokens[start + offset] == quoteTokens[offset] {
                hits += 1
            }
            let score = Double(hits) / Double(quoteTokens.count)
            if score > (best?.score ?? 0) {
                best = (score, start)
            }
        }
        // 0.6: transcription and the model's copy both wobble a word or two;
        // an unrelated passage does not accidentally match 60% in order.
        guard let best, best.score >= 0.6 else { return nil }

        let firstCue = transcript.segments[cueIndex[best.start]]
        let lastCue = transcript.segments[cueIndex[best.start + quoteTokens.count - 1]]
        return (firstCue.startMs, lastCue.endMs)
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
