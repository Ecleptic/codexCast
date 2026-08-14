import CodexCastCore
import CodexCastDetection
import Foundation
import FoundationModels

// This module is separate from CodexCastDetection on purpose: it links
// FoundationModels, whose newest symbols are missing from this development
// Mac's OS. Keeping it out of the Mac test binaries lets the entire suite run
// on the Mac while the app target links both modules on iOS 27.

/// Guided-generation output schema (§5.3.3). Property order matters: guided
/// generation fills in declaration order and later properties condition on
/// earlier ones — `rationale` stays last so it follows the decision rather
/// than steering it.
@Generable
struct WindowClassificationOutput {
    @Guide(description: "Every advertising or promotional segment found in this window. Empty if none.")
    var segments: [AdSegmentCandidate]
}

@Generable
struct AdSegmentCandidate {
    @Guide(description: "Start time in whole seconds from the start of the episode, from the line timestamps.")
    var startSeconds: Int

    @Guide(description: "End time in whole seconds from the start of the episode.")
    var endSeconds: Int

    @Guide(.anyOf(["ad", "sponsor_read", "self_promo", "intro", "outro"]))
    var kind: String

    @Guide(description: "Confidence from 0.0 to 1.0.")
    var confidence: Double

    @Guide(description: "Brand or advertiser name if identifiable, otherwise empty.")
    var sponsor: String

    @Guide(description: "One sentence, at most 20 words, explaining the classification.")
    var rationale: String
}

/// Stage 2: the on-device Apple Foundation model (§5.3, §7.1).
///
/// Default classifier, and the only one enabled at ship. Instructions are the
/// versioned artifact at Resources/Prompts/classify_v1.md — keep in sync.
public struct OnDeviceClassifier: AdClassifier {
    public let identifier = "afm"

    public init() {}

    public var isAvailable: Bool {
        get async {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
    }

    /// Which tier is running, recorded into provenance so the harness can
    /// report per-tier quality (§7.2).
    public var modelTier: String {
        // Query, never hardcode device lists. Tier introspection lands with
        // the device milestone; until then the tier is reported as default.
        "default"
    }

    public func classify(
        window: TranscriptWindow,
        context: ClassificationContext
    ) async throws -> [WindowFinding] {
        // One session per window (§5.3.2): reuse accumulates transcript
        // context and exhausts the small window.
        let session = LanguageModelSession(instructions: instructions(for: context))
        let response = try await session.respond(
            to: window.promptText(),
            generating: WindowClassificationOutput.self
        )

        return response.content.segments.map { candidate in
            let recognized = SegmentKind.isRecognized(modelValue: candidate.kind)
            return WindowFinding(
                startMs: candidate.startSeconds * 1000,
                endMs: candidate.endSeconds * 1000,
                kind: SegmentKind(modelValue: candidate.kind),
                // Unrecognized kinds map to .ad at reduced confidence (§5.3.3).
                confidence: recognized ? candidate.confidence : candidate.confidence * 0.8,
                sponsor: candidate.sponsor.isEmpty ? nil : candidate.sponsor,
                rationale: candidate.rationale.isEmpty ? nil : candidate.rationale
            )
        }
    }

    /// Warms the model before a batch so per-window load cost is paid once
    /// (§5.3.6).
    public func prewarm(context: ClassificationContext) {
        let session = LanguageModelSession(instructions: instructions(for: context))
        session.prewarm()
    }

    // MARK: - Instructions (classify_v1)

    func instructions(for context: ClassificationContext) -> String {
        var text = """
        You identify advertising in podcast transcripts. Each line of the \
        transcript window is preceded by a [mm:ss] timestamp.

        Find segments that are: paid advertisements (ad), host-read sponsor \
        messages (sponsor_read), or the show promoting its own products, \
        events, or memberships (self_promo). Ads commonly run back-to-back in \
        blocks of two to four, each roughly 30 seconds; finding one raises the \
        chance that another follows immediately.

        Do NOT flag ordinary conversation that merely mentions brands or \
        products, and do not flag discussion ABOUT advertising — only actual \
        promotional reads. The hard case is a host who genuinely likes a \
        product: organic enthusiasm is content; reading sponsor copy (an \
        offer, a URL, a promo code, "thanks to X for sponsoring") is a \
        sponsor_read.

        Precision matters more than recall. A false positive cuts real \
        content and is far more annoying than a missed ad. When uncertain, \
        report the segment with low confidence rather than omitting it.

        Report start and end times in whole seconds from the start of the \
        episode, using the line timestamps.

        This episode is from the show "\(context.showName)".
        """

        if !context.knownSponsors.isEmpty {
            text += "\n\nThese advertisers have appeared on this show before; presence is evidence, not proof: "
            text += context.knownSponsors.joined(separator: ", ") + "."
        }
        if let notes = context.showNotes {
            text += "\n\nShow notes from the listener: \(notes)"
        }
        for exemplar in context.negativeExemplars {
            text += "\n\nThis passage from this show was previously misclassified as an ad; it is content: \"\(exemplar)\""
        }
        return text
    }
}
