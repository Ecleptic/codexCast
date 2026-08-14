import Foundation

public enum SegmentKind: String, Hashable, Sendable, Codable, CaseIterable {
    case ad
    case sponsorRead
    case selfPromo
    case intro
    case outro

    /// Maps the model's free-form `kind` string onto the enum (§5.3.3).
    /// Deliberately total: an unrecognized value must never crash and must
    /// never cause the segment to be dropped.
    public init(modelValue: String) {
        switch modelValue.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "ad": self = .ad
        case "sponsor_read", "sponsorread": self = .sponsorRead
        case "self_promo", "selfpromo": self = .selfPromo
        case "intro": self = .intro
        case "outro": self = .outro
        default: self = .ad
        }
    }

    /// True when `modelValue` was not recognized, so the caller can apply the
    /// confidence penalty §5.3.3 requires rather than silently trusting it.
    public static func isRecognized(modelValue: String) -> Bool {
        let normalized = modelValue.lowercased().replacingOccurrences(of: " ", with: "_")
        return ["ad", "sponsor_read", "sponsorread", "self_promo", "selfpromo", "intro", "outro"]
            .contains(normalized)
    }
}

public enum UserState: String, Hashable, Sendable, Codable {
    case unreviewed
    case confirmed
    case rejected
    case adjusted
}

/// Which stage produced a segment, and on what evidence.
///
/// This is the pipeline's critical invariant: when the user corrects a segment,
/// the system must know where it came from so the correction routes to the
/// right repair. A false positive from a learned pattern demotes that pattern;
/// a false positive from the model creates a negative exemplar. Different
/// repairs — never conflate them.
public enum Provenance: Hashable, Sendable, Codable {
    case positionPrior(ruleID: UUID)
    case patternMatch(patternID: UUID, score: Double)
    case onDeviceModel(windowIndex: Int, modelTier: String)
    case acoustic(signal: String)
    case externalModel(providerID: String)
    case manual

    /// Segments the user created or endorsed. The runaway guard (§5.6) must
    /// exclude these: a user who said "always skip the first 90 seconds" must
    /// never have that instruction overridden because a heuristic got nervous.
    public var isUserOriginated: Bool {
        if case .manual = self { return true }
        return false
    }

    /// Stage label used to key calibration bins (§5.7).
    public var stageIdentifier: String {
        switch self {
        case .positionPrior: "positionPrior"
        case .patternMatch: "patternMatch"
        case .onDeviceModel: "onDeviceModel"
        case .acoustic: "acoustic"
        case .externalModel: "externalModel"
        case .manual: "manual"
        }
    }
}

public struct DetectedSegment: Identifiable, Hashable, Sendable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    public var id: ID
    public var episodeID: Episode.ID
    public var startMs: Int
    public var endMs: Int
    public var kind: SegmentKind
    /// Calibrated, never raw and never 1.0 (§5.7).
    public var confidence: Double
    /// The score the stage originally reported, before calibration —
    /// calibration bins are keyed by ITS decile, so corrections must be
    /// counted against it, not against the adjusted value.
    public var rawConfidence: Double?
    public var provenance: Provenance
    public var rationale: String?
    public var sponsorID: UUID?
    public var userState: UserState
    /// Adjacent segments merged into one skip block share this (§5.5). The UI
    /// presents the block; the database keeps the components, so rejecting one
    /// spot does not discard the learning from the other three.
    public var chunkID: UUID?
    public var createdAt: Date
    public var reviewedAt: Date?

    public init(
        id: ID = ID(),
        episodeID: Episode.ID,
        startMs: Int,
        endMs: Int,
        kind: SegmentKind,
        confidence: Double,
        rawConfidence: Double? = nil,
        provenance: Provenance,
        rationale: String? = nil,
        sponsorID: UUID? = nil,
        userState: UserState = .unreviewed,
        chunkID: UUID? = nil,
        createdAt: Date = Date(),
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.episodeID = episodeID
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.confidence = confidence
        self.rawConfidence = rawConfidence
        self.provenance = provenance
        self.rationale = rationale
        self.sponsorID = sponsorID
        self.userState = userState
        self.chunkID = chunkID
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func overlaps(startMs otherStart: Int, endMs otherEnd: Int) -> Bool {
        startMs < otherEnd && otherStart < endMs
    }
}
