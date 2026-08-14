import Foundation

/// Sponsors a show declares in its own episode description (addendum A6).
///
/// Many shows list their sponsors in the show notes — ATP publishes
/// "Sponsored by: Factor … Use code atp50off." before a single second of audio
/// is processed. That is a free, high-precision answer to "who am I looking
/// for in this episode", available on the *first* episode of a new
/// subscription rather than after enough corrections to learn it.
///
/// Promo codes are the strongest token of all: "atp50off" appearing anywhere
/// in a transcript is not a coincidence.
public struct SponsorHint: Hashable, Sendable, Codable {
    public var name: String
    /// The blurb following the name, where present.
    public var offer: String?
    /// Promo codes and discount URLs, which make excellent exact-match anchors.
    public var promoCodes: [String]

    public init(name: String, offer: String? = nil, promoCodes: [String] = []) {
        self.name = name
        self.offer = offer
        self.promoCodes = promoCodes
    }
}

public enum SponsorHintExtractor {
    /// Phrases that introduce a sponsor list. Conservative on purpose: a show
    /// *discussing* advertising must not be mined for sponsors.
    private static let headers = [
        #"sponsored by:?"#,
        #"brought to you by:?"#,
        #"our sponsors?:"#,
        #"this (?:week|episode)'?s sponsors?:?"#,
        #"sponsors?:"#,
    ]

    private static let headerRegex = try! NSRegularExpression(
        pattern: "(?:" + headers.joined(separator: "|") + ")",
        options: [.caseInsensitive]
    )

    /// Promo code phrasing, which is remarkably consistent across shows.
    private static let promoRegex = try! NSRegularExpression(
        pattern: #"(?:use|with|promo|coupon)\s+code\s+([A-Za-z0-9][A-Za-z0-9_-]{2,24})"#,
        options: [.caseInsensitive]
    )

    /// Extracts sponsor hints from an episode description or show notes.
    ///
    /// Handles both shapes seen in the wild: a list following a "Sponsored by:"
    /// header (ATP, Changelog), and prose containing "brought to you by X".
    public static func extract(from description: String) -> [SponsorHint] {
        let text = normalize(description)
        guard let header = firstMatch(headerRegex, in: text) else { return [] }

        // Everything after the header, bounded — sponsor blocks are short, and
        // reading further starts capturing unrelated show notes.
        let start = text.index(text.startIndex, offsetBy: header.upperBound)
        let block = String(text[start...].prefix(1_200))

        var hints = parseList(block)
        if hints.isEmpty {
            hints = parseProse(block)
        }

        // Promo codes may appear anywhere in the block; attach by proximity,
        // falling back to the first sponsor.
        let codes = allMatches(promoRegex, in: block, captureGroup: 1)
        if !codes.isEmpty, !hints.isEmpty {
            for code in codes {
                guard let range = block.range(of: code) else { continue }
                let position = block.distance(from: block.startIndex, to: range.lowerBound)
                let owner = hints.enumerated()
                    .filter { $0.element.sourceOffset <= position }
                    .max { $0.element.sourceOffset < $1.element.sourceOffset }?.offset ?? 0
                hints[owner].hint.promoCodes.append(code)
            }
        }

        return hints.map(\.hint).filter { isPlausibleSponsorName($0.name) }
    }

    // MARK: - Shapes

    private struct Located {
        var hint: SponsorHint
        var sourceOffset: Int
    }

    /// "Factor: Healthy Eating, Made Easy." — one sponsor per line, name first.
    private static func parseList(_ block: String) -> [Located] {
        var results: [Located] = []
        var offset = 0

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { offset += line.count + 1 }
            guard !trimmed.isEmpty else { continue }

            // A sponsor line names the brand before a colon or dash.
            guard let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "–" || $0 == "—" })
            else { continue }

            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let offer = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            guard isPlausibleSponsorName(name) else { continue }
            results.append(
                Located(
                    hint: SponsorHint(name: name, offer: offer.isEmpty ? nil : offer),
                    sourceOffset: offset
                )
            )
        }
        return results
    }

    /// "brought to you by Squarespace and Backblaze" — prose form.
    private static func parseProse(_ block: String) -> [Located] {
        // The first sentence after the header carries the names.
        let sentence = block
            .prefix(while: { $0 != "." && $0 != "\n" })
            .trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty else { return [] }

        let names = sentence
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isPlausibleSponsorName($0) }

        return names.enumerated().map {
            Located(hint: SponsorHint(name: $0.element), sourceOffset: $0.offset)
        }
    }

    // MARK: - Filtering

    /// Rejects sentence fragments, boilerplate, and anything that reads as
    /// prose rather than a brand.
    static func isPlausibleSponsorName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(trimmed.count) else { return false }
        guard trimmed.split(separator: " ").count <= 4 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }

        let lowered = trimmed.lowercased()
        let boilerplate = [
            "become a member", "members only", "member", "support",
            "http", "www", "subscribe", "listen", "follow", "join",
            "sponsor", "sponsors", "sponsored by", "brought to you by",
            "this episode", "our sponsors", "and more", "the show",
        ]
        return !boilerplate.contains { lowered == $0 || lowered.hasPrefix($0) }
    }

    // MARK: - Text handling

    /// Show notes are HTML; the structure that matters is line breaks around
    /// list items, so tags become newlines rather than disappearing.
    static func normalize(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "<(?:br|/p|/li|/div|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&#8217;", "'"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Range<Int>? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return match.range.location..<(match.range.location + match.range.length)
    }

    private static func allMatches(
        _ regex: NSRegularExpression,
        in text: String,
        captureGroup: Int
    ) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[captured])
        }
    }
}
