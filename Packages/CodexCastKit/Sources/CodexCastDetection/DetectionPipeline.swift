import CodexCastCore
import Foundation

/// Runs the detection stages in order and produces `DetectedSegment`s (§5).
///
/// Stage order matters and is the design's whole economy: structural priors and
/// learned patterns are free, so they run first, and only what they leave
/// unresolved reaches the model. On a well-learned show that may be nothing at
/// all, and the episode classifies with zero inference.
public struct DetectionPipeline: Sendable {
    public struct Input: Sendable {
        public var episodeID: Episode.ID
        public var transcript: TimedTranscript
        public var episodeDurationMs: Int
        public var context: ClassificationContext
        /// Stage 1's learned scripts for this show plus global patterns.
        public var patterns: [PatternBaselineDetector.Pattern]

        public init(
            episodeID: Episode.ID,
            transcript: TimedTranscript,
            episodeDurationMs: Int,
            context: ClassificationContext,
            patterns: [PatternBaselineDetector.Pattern] = []
        ) {
            self.episodeID = episodeID
            self.transcript = transcript
            self.episodeDurationMs = episodeDurationMs
            self.context = context
            self.patterns = patterns
        }
    }

    public struct Result: Sendable {
        public var segments: [DetectedSegment]
        /// Windows dispatched to the model. Zero on a fully-learned episode,
        /// which is the number §15's Phase 3 acceptance tracks.
        public var modelWindowsDispatched: Int
        public var modelWindowsSkipped: Int
    }

    private let classifier: any AdClassifier

    public init(classifier: any AdClassifier) {
        self.classifier = classifier
    }

    public func run(_ input: Input) async throws -> Result {
        // Stage 1 — learned patterns. Free, and on a repeating show it
        // resolves most of the episode before the model is consulted.
        let patternDetector = PatternBaselineDetector(patterns: input.patterns)
        let matches = patternDetector.detect(in: input.transcript)

        var segments: [DetectedSegment] = matches.map { match in
            DetectedSegment(
                episodeID: input.episodeID,
                startMs: match.startMs,
                endMs: match.endMs,
                kind: .sponsorRead,
                confidence: min(0.95, 0.6 + match.score),
                provenance: .patternMatch(patternID: UUID(), score: match.score),
                rationale: match.sponsor.map { "Matches a learned \($0) read" }
            )
        }

        // Stage 2 — the model, over what Stage 1 left unresolved.
        let resolved = matches.map {
            TranscriptWindow.ResolvedRegion(
                startMs: $0.startMs,
                endMs: $0.endMs,
                label: $0.sponsor ?? "known sponsor"
            )
        }
        let allWindows = TranscriptWindower.windows(for: input.transcript)
        let windows = TranscriptWindower.windows(for: input.transcript, resolved: resolved)

        var findings: [WindowFinding] = []
        for window in windows {
            // One window failing must not cost the episode its other windows
            // (§5.3.7).
            guard let result = try? await classifier.classify(
                window: window, context: input.context
            ) else { continue }
            findings.append(contentsOf: result)
        }

        for finding in TranscriptWindower.deduplicate(findings) {
            // §5.3.4: model timestamps are snapped to transcript boundaries
            // before anything downstream sees them.
            guard let start = input.transcript.nearestBoundary(toMs: finding.startMs),
                  let end = input.transcript.nearestBoundary(toMs: finding.endMs),
                  end > start
            else { continue }

            // Don't re-propose what Stage 1 already owns.
            let duplicate = segments.contains { existing in
                existing.overlaps(startMs: start, endMs: end)
            }
            guard !duplicate else { continue }

            segments.append(
                DetectedSegment(
                    episodeID: input.episodeID,
                    startMs: start,
                    endMs: end,
                    kind: finding.kind,
                    confidence: finding.confidence,
                    provenance: .onDeviceModel(
                        windowIndex: 0,
                        modelTier: classifier.identifier
                    ),
                    rationale: finding.rationale
                )
            )
        }

        // Stage 3 — chunking: adjacent spots become one skip block, or the
        // listener gets skip-play-skip stutter across a four-ad break (§5.5).
        segments = Self.assignChunks(segments.sorted { $0.startMs < $1.startMs })

        return Result(
            segments: segments,
            modelWindowsDispatched: windows.count,
            modelWindowsSkipped: allWindows.count - windows.count
        )
    }

    /// Groups segments separated by less than 5 seconds under a shared chunk,
    /// keeping them individually correctable (§5.5).
    static func assignChunks(_ segments: [DetectedSegment]) -> [DetectedSegment] {
        guard !segments.isEmpty else { return [] }
        var result = segments
        var chunkID = UUID()
        result[0].chunkID = chunkID

        for index in 1..<result.count {
            if result[index].startMs - result[index - 1].endMs >= 5_000 {
                chunkID = UUID()
            }
            result[index].chunkID = chunkID
        }
        return result
    }
}
