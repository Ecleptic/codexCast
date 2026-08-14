// Arm 1 — transcript-only classification with Apple's on-device model (§14.3).
//
// MAC PREVIEW CAVEATS
// - This Mac runs an older model generation than the iOS 27 target, so these
//   numbers are a floor, not the final answer. The device run confirms them.
// - This OS build predates the SDK's guided-generation additions, so the
//   binary asks for JSON and parses it manually. The production pipeline uses
//   @Generable guided output (§5.3.3) and never string-parses.
//
// Windowing per §5.3.2, simplified: 3-minute windows, 60-second overlap, one
// fresh session per window, boundaries snapped to transcript cues (§5.3.4).

import CodexCastCore
import CodexCastDetection
import Foundation
import FoundationModels
import SpikeShared

@main
struct SpikeLM {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let limit: Int
        let arguments = CommandLine.arguments
        let only = arguments.firstIndex(of: "--only").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        if let index = arguments.firstIndex(of: "--limit"), index + 1 < arguments.count {
            limit = Int(arguments[index + 1]) ?? .max
        } else {
            limit = .max
        }

        do {
            try await Arm1.run(limit: limit, only: only)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

enum Arm1 {
    static let instructions = """
    You identify advertising in podcast transcripts. The transcript window \
    given to you has a [mm:ss] timestamp before each line.

    Find segments that are: paid advertisements (ad), host-read sponsor \
    messages (sponsor_read), or the show promoting its own products, events, \
    or memberships (self_promo). Ads often run back-to-back in blocks of two \
    to four, each roughly 30 seconds; finding one raises the chance another \
    follows immediately.

    Do NOT flag ordinary conversation that merely mentions brands, and do not \
    flag discussion ABOUT advertising — only actual promotional reads. \
    Precision matters more than recall: a false positive cuts real content.

    Respond with ONLY a JSON array, no other text. Each element:
    {"startSeconds": <int>, "endSeconds": <int>, "kind": "ad"|"sponsor_read"|"self_promo", "confidence": <0.0-1.0>}
    Use the line timestamps for startSeconds/endSeconds. If the window \
    contains no advertising, respond with [].
    """

    struct Candidate: Decodable {
        var startSeconds: Int
        var endSeconds: Int
        var kind: String
        var confidence: Double
    }

    static func run(limit: Int, only: String? = nil) async throws {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("model unavailable: \(model.availability)")
            exit(1)
        }

        var all = try Corpus.load(from: SpikeEnvironment.corpusDir)
        if let only { all = all.filter { $0.episodeTitle.lowercased().contains(only.lowercased()) } }
        all.sort { $0.durationMs < $1.durationMs }
        let episodes = Array(all.prefix(limit))
        var rows: [(CorpusEpisode, [ClosedRange<Int>])] = []

        print("Arm 1 — transcript-only, Apple on-device model (Mac preview, JSON mode)")
        for episode in episodes {
            guard let transcript = episode.timedTranscript else { continue }
            let started = Date()
            var spans: [ClosedRange<Int>] = []
            var failures = 0
            let windows = makeWindows(of: transcript)

            for (windowIndex, window) in windows.enumerated() {
                print("    window \(windowIndex + 1)/\(windows.count)", terminator: "\r")
                do {
                    let found = try await classify(window: window)
                    spans.append(contentsOf: found.compactMap { snap($0, to: transcript) })
                } catch {
                    failures += 1   // one bad window must not sink the episode
                }
            }

            let merged = EvalMetrics.mergeSpans(spans)
            let elapsed = Int(Date().timeIntervalSince(started))
            // Diagnostic: predicted vs truth, so a zero score can be explained
            // rather than merely reported.
            let truth = EvalMetrics.mergeSpans(episode.adSpans())
            print("      predicted: " + merged.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("      truth:     " + truth.map { "\($0.lowerBound/1000)-\($0.upperBound/1000)s" }.joined(separator: ", "))
            print("  \(episode.episodeTitle.prefix(26)): \(windows.count) windows, \(failures) failed, \(merged.count) segments, \(elapsed)s")
            rows.append((episode, merged))
        }

        print()
        SpikeEnvironment.report(rows)
    }

    // MARK: - Windowing

    struct Window {
        var prompt: String
    }

    static func makeWindows(
        of transcript: TimedTranscript,
        windowMs: Int = 180_000,
        overlapMs: Int = 60_000
    ) -> [Window] {
        let cues = transcript.segments
        guard !cues.isEmpty else { return [] }
        var result: [Window] = []
        var windowStart = cues.first!.startMs
        let end = cues.last!.endMs

        while windowStart < end {
            let windowEnd = windowStart + windowMs
            let slice = cues.filter { $0.startMs < windowEnd && $0.endMs > windowStart }
            if !slice.isEmpty {
                let lines = slice.map { cue in
                    let seconds = cue.startMs / 1000
                    return String(format: "[%d:%02d] %@", seconds / 60, seconds % 60, cue.text)
                }
                result.append(Window(prompt: lines.joined(separator: "\n")))
            }
            windowStart += windowMs - overlapMs
        }
        return result
    }

    // MARK: - Classification

    static func classify(window: Window) async throws -> [Candidate] {
        // Fresh session per window (§5.3.2): reuse accumulates transcript
        // context and overflows the small on-device window.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: window.prompt)
        return parse(response.content)
    }

    /// Tolerant JSON extraction: the model may wrap the array in prose or code
    /// fences despite instructions. Guided generation removes this whole class
    /// of failure on device; here we do the honest fallback.
    static func parse(_ text: String) -> [Candidate] {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end
        else { return [] }
        let json = String(text[start...end])
        return (try? JSONDecoder().decode([Candidate].self, from: Data(json.utf8))) ?? []
    }

    /// §5.3.4: snap model timestamps to transcript boundaries; drop non-ad
    /// kinds, low confidence, and sub-gate durations (§5.6).
    static func snap(
        _ candidate: Candidate,
        to transcript: TimedTranscript
    ) -> ClosedRange<Int>? {
        let kind = SegmentKind(modelValue: candidate.kind)
        guard kind == .ad || kind == .sponsorRead else { return nil }
        guard candidate.confidence >= 0.4 else { return nil }

        guard let start = transcript.nearestBoundary(toMs: candidate.startSeconds * 1000),
              let end = transcript.nearestBoundary(toMs: candidate.endSeconds * 1000),
              end > start,
              end - start >= 5_000
        else { return nil }
        return start...end
    }
}
