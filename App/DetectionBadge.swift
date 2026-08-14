import CodexCastCore
import Foundation

/// A2: badge labels for the promotional-content kinds found on a show.
/// Intro/outro are structure, not promotion — no badge. Wording stays
/// generic; the UI never names a specific platform.
enum DetectionBadge {
    static func badges(for kinds: Set<SegmentKind>) -> [String] {
        var labels: [String] = []
        if kinds.contains(.ad) { labels.append("Ads") }
        if kinds.contains(.sponsorRead) { labels.append("Sponsor reads") }
        if kinds.contains(.selfPromo) { labels.append("Self-promo") }
        return labels
    }
}
