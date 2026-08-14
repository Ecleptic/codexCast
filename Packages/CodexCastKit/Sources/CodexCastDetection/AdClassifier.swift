import CodexCastCore
import Foundation

/// One window of transcript handed to a classifier (§5.3.2).
public struct TranscriptWindow: Sendable {
    public var index: Int
    public var cues: [TimedTranscript.Segment]
    /// Regions already resolved by earlier stages, kept IN the window as
    /// context per the fragmentation policy — excising them would leave
    /// unusable fragments, and an already-identified ad helps the model spot
    /// the next spot in a stacked break.
    public var resolvedRegions: [ResolvedRegion]

    public struct ResolvedRegion: Sendable {
        public var startMs: Int
        public var endMs: Int
        public var label: String

        public init(startMs: Int, endMs: Int, label: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.label = label
        }
    }

    public init(
        index: Int,
        cues: [TimedTranscript.Segment],
        resolvedRegions: [ResolvedRegion] = []
    ) {
        self.index = index
        self.cues = cues
        self.resolvedRegions = resolvedRegions
    }

    public var startMs: Int { cues.first?.startMs ?? 0 }
    public var endMs: Int { cues.last?.endMs ?? 0 }

    /// The prompt body: timestamped lines, with resolved regions annotated
    /// rather than removed.
    public func promptText() -> String {
        cues.map { cue in
            let seconds = cue.startMs / 1000
            let stamp = String(format: "[%d:%02d]", seconds / 60, seconds % 60)
            if let region = resolvedRegions.first(where: {
                cue.startMs < $0.endMs && $0.startMs < cue.endMs
            }) {
                return "\(stamp) [AD — already identified: \(region.label)] \(cue.text)"
            }
            return "\(stamp) \(cue.text)"
        }
        .joined(separator: "\n")
    }
}

/// What a classifier says about one window.
public struct WindowFinding: Sendable {
    public var startMs: Int
    public var endMs: Int
    public var kind: SegmentKind
    public var confidence: Double
    public var sponsor: String?
    public var rationale: String?
    /// How many overlapping windows independently proposed this span — set
    /// by deduplication; the §5.7 agreement signal.
    public var agreementCount: Int

    public init(
        startMs: Int,
        endMs: Int,
        kind: SegmentKind,
        confidence: Double,
        sponsor: String? = nil,
        rationale: String? = nil,
        agreementCount: Int = 1
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.confidence = confidence
        self.sponsor = sponsor
        self.rationale = rationale
        self.agreementCount = agreementCount
    }
}

/// Per-show context injected into the instructions (§5.3.5), all bounded —
/// every token here is a token unavailable for transcript.
public struct ClassificationContext: Sendable {
    public var showName: String
    /// Known sponsors for this show — evidence, not proof.
    public var knownSponsors: [String]
    /// Passages previously misclassified as ads; they are content (§6.6).
    public var negativeExemplars: [String]
    /// The user's free-text note, capped at 300 characters (§6.5).
    public var showNotes: String?

    public init(
        showName: String,
        knownSponsors: [String] = [],
        negativeExemplars: [String] = [],
        showNotes: String? = nil
    ) {
        self.showName = showName
        self.knownSponsors = Array(knownSponsors.prefix(10))
        self.negativeExemplars = Array(negativeExemplars.prefix(2))
        self.showNotes = showNotes.map { String($0.prefix(300)) }
    }
}

/// The §7.1 protocol boundary. Exists so the harness can run deterministically
/// with `StubClassifier`, not to hedge on architecture.
public protocol AdClassifier: Sendable {
    var identifier: String { get }
    var isAvailable: Bool { get async }
    func classify(
        window: TranscriptWindow,
        context: ClassificationContext
    ) async throws -> [WindowFinding]
}

/// Replays recorded findings for the eval harness (§13). Keyed by window
/// index; unknown windows return nothing.
public struct StubClassifier: AdClassifier {
    public let identifier = "stub"
    public var isAvailable: Bool { true }

    private let findings: [Int: [WindowFinding]]

    public init(findings: [Int: [WindowFinding]] = [:]) {
        self.findings = findings
    }

    public func classify(
        window: TranscriptWindow,
        context: ClassificationContext
    ) async throws -> [WindowFinding] {
        findings[window.index] ?? []
    }
}
