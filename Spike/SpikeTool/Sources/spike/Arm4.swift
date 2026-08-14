// Arm 4 — classical audio features, no LLM (§14.3).
//
// The question: can loudness structure and music-under-speech detection find
// ads at a thousandth of the compute of a language model? Signals used:
//
//  - SoundAnalysis' built-in classifier, windowed over the file, for "music"
//    confidence. Ad reads ride on music beds; conversation mostly does not.
//  - Per-window RMS loudness, for the level jumps that mark produced inserts.
//
// Caveat learned from labeling (addendum A4): music also means intros, outros,
// and transitions, so music alone must over-detect those. The eval counts that
// honestly — intros/outros labeled in the corpus are NOT ad truth, so a
// music-only detector pays for every transition it flags.

import AVFoundation
import CodexCastDetection
import Foundation
import SoundAnalysis
import SpikeShared

enum Arm4 {
    static func run() async throws {
        let episodes = try Corpus.load(from: SpikeEnvironment.corpusDir)
        var rows: [(CorpusEpisode, [ClosedRange<Int>])] = []

        print("Arm 4 — classical audio features (music-bed regions, no LLM)")
        for episode in episodes {
            guard let audio = SpikeEnvironment.audioFile(for: episode) else {
                print("  (no audio for \(episode.episodeTitle) — skipped)")
                continue
            }
            let started = Date()
            let music = try await musicRegions(in: audio)
            let spans = candidateAdSpans(
                musicRegions: music,
                durationMs: episode.durationMs
            )
            let elapsed = Int(Date().timeIntervalSince(started))
            print("  analyzed \(audio.lastPathComponent) in \(elapsed)s — \(music.count) music regions, \(spans.count) candidates")
            rows.append((episode, spans))
        }

        print()
        SpikeEnvironment.report(rows)
    }

    // MARK: - Music detection

    struct Region {
        var startMs: Int
        var endMs: Int
        var confidence: Double
    }

    /// Windows where the built-in sound classifier hears music.
    static func musicRegions(in file: URL) async throws -> [Region] {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 3, preferredTimescale: 1000)
        request.overlapFactor = 0.5

        let analyzer = try SNAudioFileAnalyzer(url: file)
        let observer = Collector()
        try analyzer.add(request, withObserver: observer)

        return await withCheckedContinuation { continuation in
            observer.onDone = { windows in
                // Merge consecutive musical windows into regions.
                var regions: [Region] = []
                for window in windows where window.music >= 0.4 {
                    if var last = regions.last, window.startMs <= last.endMs + 1_500 {
                        last.endMs = window.endMs
                        last.confidence = max(last.confidence, window.music)
                        regions[regions.count - 1] = last
                    } else {
                        regions.append(Region(
                            startMs: window.startMs, endMs: window.endMs, confidence: window.music
                        ))
                    }
                }
                continuation.resume(returning: regions)
            }
            analyzer.analyze()
        }
    }

    struct Window {
        var startMs: Int
        var endMs: Int
        var music: Double
    }

    final class Collector: NSObject, SNResultsObserving {
        var windows: [Window] = []
        var onDone: (([Window]) -> Void)?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            let music = classification.classifications
                .first { $0.identifier == "music" }?.confidence ?? 0
            windows.append(Window(
                startMs: Int(classification.timeRange.start.seconds * 1000),
                endMs: Int(classification.timeRange.end.seconds * 1000),
                music: music
            ))
        }

        func requestDidComplete(_ request: SNRequest) {
            onDone?(windows)
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            onDone?(windows)
        }
    }

    // MARK: - Candidate spans

    /// Music regions filtered to ad-plausible shapes: long enough to be a spot,
    /// short enough not to be a theme song marathon, and not glued to the very
    /// start or end of the episode (those are intros and outros — A4).
    static func candidateAdSpans(
        musicRegions: [Region],
        durationMs: Int
    ) -> [ClosedRange<Int>] {
        let edgeMarginMs = 60_000

        let plausible = musicRegions.filter { region in
            let length = region.endMs - region.startMs
            guard length >= 15_000, length <= 240_000 else { return false }
            guard region.startMs > edgeMarginMs else { return false }             // intro
            guard region.endMs < durationMs - edgeMarginMs else { return false } // outro
            return true
        }

        return EvalMetrics.mergeSpans(plausible.map { $0.startMs...$0.endMs })
    }
}
