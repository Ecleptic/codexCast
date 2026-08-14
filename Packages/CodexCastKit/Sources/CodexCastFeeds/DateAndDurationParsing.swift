import Foundation

/// `<pubDate>` is specified as RFC 822, but feeds emit a wide range of
/// near-misses: missing seconds, missing day-of-week, named zones, and
/// occasionally ISO 8601. A publication date is not worth failing an episode
/// over, so several formats are tried and `nil` is an acceptable answer.
public enum RFC822DateParser {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ]

    /// Formatters are expensive to build, so they are created once. Each is used
    /// only from within a single synchronous parse.
    private static let formatters: [DateFormatter] = formats.map { format in
        let formatter = DateFormatter()
        // A fixed locale is mandatory: with the user's locale, an English month
        // abbreviation fails to parse on a device set to another language.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for formatter in formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

/// `<itunes:duration>` appears as plain seconds ("3723"), as "MM:SS", and as
/// "HH:MM:SS". All three are in active use.
public enum DurationParser {
    public static func milliseconds(from string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":").map(String.init)

        switch parts.count {
        case 1:
            // Plain seconds, occasionally fractional.
            guard let seconds = Double(parts[0]), seconds >= 0 else { return nil }
            return Int(seconds * 1000)
        case 2:
            guard let minutes = Int(parts[0]), let seconds = Double(parts[1]) else { return nil }
            guard minutes >= 0, seconds >= 0 else { return nil }
            return Int((Double(minutes) * 60 + seconds) * 1000)
        case 3:
            guard let hours = Int(parts[0]),
                  let minutes = Int(parts[1]),
                  let seconds = Double(parts[2])
            else { return nil }
            guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
            return Int((Double(hours) * 3600 + Double(minutes) * 60 + seconds) * 1000)
        default:
            return nil
        }
    }
}
