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

// MARK: - Two-pass output schemas
//
// Measured on the corpus (Mac preview, 2026-08-15): two-pass with
// quote-anchored boundaries took strict F1 0.07→0.42 and boundary error
// 49s→11s over the single-pass baseline. The sweep casts a wide net; the
// verifier demands evidence; boundaries come from quotes, not arithmetic.

@Generable
struct ChapterTitleOutput {
    @Guide(description: "Three to six words naming the chapter's topic. No quotes or punctuation.")
    var title: String
}

@Generable
struct SweepOutput {
    @Guide(description: "Every stretch that might plausibly be advertising or promotion. Wide net; a later step rejects false alarms. Empty if none.")
    var candidates: [SweepCandidate]
}

@Generable
struct SweepCandidate {
    @Guide(description: "Approximate start in whole seconds, from the line timestamps.")
    var startSeconds: Int

    @Guide(description: "Approximate end in whole seconds.")
    var endSeconds: Int

    @Guide(description: "The few words that made this look promotional.")
    var hint: String
}

/// Property order is the reasoning order: evidence (sponsor, quotes) is
/// generated BEFORE the verdict and confidence, so the decision conditions
/// on the evidence instead of the other way around.
@Generable
struct VerifyOutput {
    @Guide(description: "The advertiser or product being promoted, or empty if none is named.")
    var sponsor: String

    @Guide(description: "The EXACT first 8-12 words of the promotional read, copied verbatim from the excerpt. Empty if there is no real promotional read.")
    var firstWords: String

    @Guide(description: "The EXACT last 8-12 words of the promotional read, copied verbatim from the excerpt. Empty if there is no real promotional read.")
    var lastWords: String

    @Guide(.anyOf(["ad", "sponsor_read", "self_promo", "none"]))
    var kind: String

    @Guide(description: "True only if the excerpt contains a real promotional read addressing the listener.")
    var isAd: Bool

    @Guide(description: "Confidence from 0.0 to 1.0. Below 0.5 if no specific advertiser AND no offer, URL, or promo code is named.")
    var confidence: Double
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

    /// The on-device model's context length in tokens, covering instructions,
    /// prompt, and output combined. The OS exposes no query for this today;
    /// this constant is the platform's documented figure and lives HERE — the
    /// one place to change when introspection becomes possible — while window
    /// sizing itself stays dynamic (§5.3.2).
    public static let contextWindowTokens = 4_096

    /// Tokens the window budget must leave alone: the instructions for this
    /// context (measured, not guessed — show notes and exemplars vary) plus
    /// room for the model's structured output.
    public func reservedTokens(for context: ClassificationContext) -> Int {
        let instructionChars = instructions(for: context).count
        let outputReserve = 900
        return Int(Double(instructionChars) / 3.8) + outputReserve
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

    // MARK: - Two-pass detection

    /// Pass 1: recall-tuned sweep of one window. Approximate spans only —
    /// the verifier owns precision and the quote anchors own boundaries.
    public func sweep(window: TranscriptWindow) async throws -> [(startMs: Int, endMs: Int)] {
        let session = LanguageModelSession(instructions: sweepInstructions)
        let response = try await session.respond(
            to: window.promptText(),
            generating: SweepOutput.self
        )
        return response.content.candidates.compactMap { candidate in
            guard candidate.endSeconds > candidate.startSeconds else { return nil }
            return (candidate.startSeconds * 1000, candidate.endSeconds * 1000)
        }
    }

    public struct Verification: Sendable {
        public var isAd: Bool
        public var kind: SegmentKind
        public var sponsor: String?
        public var firstWords: String?
        public var lastWords: String?
        public var confidence: Double
    }

    /// Pass 2: precision-tuned judgment of one candidate, given the excerpt
    /// text with timestamps. The verdict must cite evidence — sponsor and
    /// verbatim first/last words — generated before the yes/no.
    public func verify(
        excerpt: String,
        context: ClassificationContext
    ) async throws -> Verification {
        let session = LanguageModelSession(instructions: verifyInstructions(for: context))
        let response = try await session.respond(to: excerpt, generating: VerifyOutput.self)
        let output = response.content
        return Verification(
            isAd: output.isAd && output.kind != "none",
            kind: SegmentKind(modelValue: output.kind == "none" ? "ad" : output.kind),
            sponsor: output.sponsor.isEmpty ? nil : output.sponsor,
            firstWords: output.firstWords.isEmpty ? nil : output.firstWords,
            lastWords: output.lastWords.isEmpty ? nil : output.lastWords,
            confidence: min(max(output.confidence, 0), 1)
        )
    }

    // MARK: - Chapter titling (§5.8)

    /// A short topic title for one generated chapter. Same windowing
    /// discipline as classification: one session, bounded excerpt.
    public func chapterTitle(excerpt: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You title podcast chapters. Given an excerpt from one chapter of a \
        podcast transcript, respond with a title of three to six words \
        naming its topic. No quotes, no punctuation, no "Chapter".
        """)
        let response = try await session.respond(
            to: String(excerpt.prefix(1_200)),
            generating: ChapterTitleOutput.self
        )
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter" : String(title.prefix(60))
    }

    let sweepInstructions = """
    You scan podcast transcripts for stretches that might be advertising. \
    Each line has a [mm:ss] timestamp.

    Flag ANY stretch that could plausibly be: a paid advertisement, a \
    host-read sponsor message, or the show promoting its own products or \
    memberships. This is a first pass — casting a wide net is fine; a later \
    step rejects false alarms. Do not agonize over exact boundaries. Ads \
    commonly run back-to-back in blocks of two to four; finding one raises \
    the chance another follows immediately.
    """

    func verifyInstructions(for context: ClassificationContext) -> String {
        var text = """
        You judge whether a flagged stretch of a podcast transcript is \
        actually advertising. Each line has a [mm:ss] timestamp.

        A real promotional read addresses the listener directly with a call \
        to action — "you should try", "go to", "use code", "sign up" — and \
        names a specific advertiser or offer. News or reviews describing a \
        product in the third person, with no action asked of the listener, \
        are CONTENT, however commercial they sound. Discussion ABOUT \
        advertising is content.

        When a real promotional read is present, copy its exact first 8-12 \
        words and last 8-12 words verbatim from the excerpt — these place \
        the skip boundaries, so they must be character-accurate.

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
            text += "\n\nExample of a passage that looks like an ad but is CONTENT — do not flag passages like this: \"\(exemplar)\""
        }
        return text
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

        The decisive test is WHO is being addressed. A sponsor read speaks \
        to the listener in the second person with a call to action: "you \
        should try", "go to", "use code", "sign up today". News or reviews \
        describe a product in the third person — specs, pricing, launch \
        dates, quotes — with no action asked of the listener. A tech show \
        reporting on a product launch reads a lot like an ad; if nobody asks \
        the listener to do anything, it is content.

        Precision matters more than recall. A false positive cuts real \
        content and is far more annoying than a missed ad. When uncertain, \
        report the segment with low confidence rather than omitting it. \
        Calibrate concretely: if the segment names no specific advertiser \
        AND contains no offer, URL, or promo code, your confidence must be \
        below 0.5.

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
            text += "\n\nExample of a passage that looks like an ad but is CONTENT — do not flag passages like this: \"\(exemplar)\""
        }
        return text
    }
}
