import Foundation

/// Phrases that essentially never occur outside promotional reads.
///
/// The model-independent mid-roll insurance: a sweep pass can doze off deep
/// into a transcript, but "use promo code" cannot appear in editorial
/// content by accident. A chapter containing one of these earns
/// verification no matter what the sweep thought. Measured effect on the
/// corpus: recall 0.36 → 0.82.
public enum LexicalAdMarkers {
    public static let phrases: [String] = [
        "promo code", "use code", "coupon code", "offer code",
        "brought to you by", "sponsored by", "thanks to our sponsor",
        "this episode is supported by", "support for this show",
        "dot com slash", "percent off", "free trial", "free shipping",
        "terms apply", "when you sign up", "sign up today", "first month free",
    ]

    public static func hit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return phrases.contains { lowered.contains($0) }
    }
}
