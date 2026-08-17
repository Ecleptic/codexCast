import AVFoundation
import Foundation
import SoundAnalysis

/// Finds stretches where music is playing, using the system sound
/// classifier — the A4 signal: many shows run a music bed under ad reads.
///
/// A4's rule stands: music is EVIDENCE, never a verdict. Shows also use
/// music for intros, outros, and transitions, so these regions only raise
/// suspicion (a chapter overlapping one gets verified); the verifier still
/// decides from the words.
public enum MusicBedDetector {
    public struct Region: Hashable, Sendable {
        public var startMs: Int
        public var endMs: Int

        public var durationMs: Int { max(0, endMs - startMs) }
    }

    /// Blocking — decode + classify one pass over the file. Call detached.
    public static func musicRegions(
        fileURL: URL,
        minimumConfidence: Double = 0.6,
        minimumDurationMs: Int = 8_000
    ) -> [Region] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: fileURL),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else { return [] }
        request.windowDuration = CMTime(seconds: 3, preferredTimescale: 1000)
        request.overlapFactor = 0

        let observer = Collector(minimumConfidence: minimumConfidence)
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }
        analyzer.analyze()

        // Merge adjacent musical windows (tolerating one non-musical window
        // between them — speech momentarily drowning the bed), drop shorts.
        var regions: [Region] = []
        for window in observer.musicalWindows.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = regions.last, window.startMs - last.endMs <= 4_000 {
                regions[regions.count - 1].endMs = window.endMs
            } else {
                regions.append(Region(startMs: window.startMs, endMs: window.endMs))
            }
        }
        return regions.filter { $0.durationMs >= minimumDurationMs }
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        let minimumConfidence: Double
        var musicalWindows: [Region] = []

        init(minimumConfidence: Double) {
            self.minimumConfidence = minimumConfidence
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            let music = classification.classification(forIdentifier: "music")
            guard let music, music.confidence >= minimumConfidence else { return }
            let start = Int(classification.timeRange.start.seconds * 1000)
            let duration = Int(classification.timeRange.duration.seconds * 1000)
            musicalWindows.append(Region(startMs: start, endMs: start + duration))
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {}
        func requestDidComplete(_ request: SNRequest) {}
    }
}
