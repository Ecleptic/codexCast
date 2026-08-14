import CodexCastCore
import Foundation

/// One hand-labeled episode from the evaluation corpus — the ground truth every
/// detector is graded against (§13). The format is exactly what the Phase 0
/// labeler exports and `Spike/build_corpus.py` validates.
public struct CorpusEpisode: Codable, Sendable {
    public struct LabeledSegment: Codable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var kind: String
        public var sponsor: String?

        public init(startMs: Int, endMs: Int, kind: String, sponsor: String? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.kind = kind
            self.sponsor = sponsor
        }

        public var segmentKind: SegmentKind { SegmentKind(modelValue: kind) }
    }

    public struct Transcript: Codable, Sendable {
        public struct Cue: Codable, Sendable {
            public var startMs: Int
            public var endMs: Int
            public var text: String
            public var speaker: String?
        }

        public var source: String
        public var segments: [Cue]
    }

    public var show: String
    public var episodeTitle: String
    public var durationMs: Int
    public var segments: [LabeledSegment]
    public var transcript: Transcript?

    public var timedTranscript: TimedTranscript? {
        guard let transcript, !transcript.segments.isEmpty else { return nil }
        return TimedTranscript(
            source: transcript.source == "podcasting20" ? .podcasting20 : .onDevice,
            segments: transcript.segments.map {
                .init(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: $0.speaker)
            }
        )
    }

    /// Ground-truth spans for ad detection: the kinds a detector is expected to
    /// find. Intros, outros, and self-promo are labeled in the corpus so the
    /// eval can catch detectors that confuse them with ads, but they are not
    /// targets here.
    public func adSpans() -> [ClosedRange<Int>] {
        segments
            .filter { $0.segmentKind == .ad || $0.segmentKind == .sponsorRead }
            .map { $0.startMs...$0.endMs }
    }
}

public enum Corpus {
    /// Loads every fixture under a corpus directory
    /// (`Fixtures/corpus/<show>/<episode>.json`).
    public static func load(from directory: URL) throws -> [CorpusEpisode] {
        let decoder = JSONDecoder()
        var episodes: [CorpusEpisode] = []

        let shows = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for show in shows {
            // Listing a non-directory just fails quietly; no need to pre-check.
            let files = (try? FileManager.default.contentsOfDirectory(
                at: show, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                episodes.append(try decoder.decode(CorpusEpisode.self, from: data))
            }
        }

        return episodes.sorted { ($0.show, $0.episodeTitle) < ($1.show, $1.episodeTitle) }
    }
}
