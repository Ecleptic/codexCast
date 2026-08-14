import Foundation

extension String {
    /// Show-notes HTML to readable plain text: block tags become newlines,
    /// entities — named AND numeric (&#xA;, &#8217;) — are decoded, and the
    /// result keeps its paragraph structure instead of collapsing into a wall.
    var htmlToPlainText: String {
        var text = self

        // Block-level structure first, while the tags still exist.
        text = text.replacingOccurrences(
            of: "<(?:br|BR)\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "</(?:p|div|li|ul|ol|h[1-6]|blockquote|tr)>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])

        // Then strip the remaining tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Numeric entities, decimal and hex — the &#xA; codes littering real
        // feeds are newlines that the naive pass displayed as text.
        while let match = text.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let entity = String(text[match])
            let body = entity.dropFirst(2).dropLast()
            let scalar: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalar = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(body)
            }
            let replacement = scalar.flatMap(Unicode.Scalar.init).map(String.init) ?? " "
            text = text.replacingCharacters(in: match, with: replacement)
        }

        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }

        // Collapse runaway blank lines, keep paragraph breaks.
        text = text.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "[ \t]+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
