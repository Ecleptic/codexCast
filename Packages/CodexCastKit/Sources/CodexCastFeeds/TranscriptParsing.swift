import CodexCastCore
import Foundation

/// Parses feed-supplied transcripts into the same `TimedTranscript` the
/// on-device transcriber produces.
///
/// This is the cheapest win in the whole pipeline: when a feed ships a
/// transcript, the most expensive stage is skipped entirely and the timings are
/// usually better than anything produced locally (§8.2).
public enum TranscriptParser {
    public static func parse(
        _ text: String,
        format: FeedTranscriptReference.Format
    ) throws -> TimedTranscript {
        switch format {
        case .vtt: try parseVTT(text)
        case .srt: try parseSRT(text)
        case .json: try parseJSON(text)
        }
    }

    // MARK: - WebVTT

    /// WebVTT, including voice spans (`<v Chris>`). The speaker name is worth
    /// keeping: a change of voice is one of the strongest human cues that an ad
    /// has begun, and where a feed provides it, that signal costs nothing.
    public static func parseVTT(_ text: String) throws -> TimedTranscript {
        var segments: [TimedTranscript.Segment] = []
        var currentStart: Int?
        var currentEnd: Int?
        var currentLines: [String] = []

        func flush() {
            defer {
                currentStart = nil
                currentEnd = nil
                currentLines = []
            }
            guard let start = currentStart, let end = currentEnd else { return }
            let joined = currentLines.joined(separator: " ")
            let (speaker, body) = extractVoiceSpan(from: joined)
            let cleaned = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            segments.append(
                .init(startMs: start, endMs: end, text: cleaned, speaker: speaker)
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                flush()
                continue
            }
            if line == "WEBVTT" || line.hasPrefix("WEBVTT") { continue }
            // Metadata blocks carry no cues.
            if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                continue
            }

            if let (start, end) = parseTimingLine(line) {
                // A cue identifier may have preceded this line; discard it.
                currentLines = []
                currentStart = start
                currentEnd = end
                continue
            }

            // A bare line before any timing is a cue identifier, not content.
            if currentStart == nil { continue }
            currentLines.append(line)
        }
        flush()

        guard !segments.isEmpty else {
            throw TranscriptParseError.noCues
        }
        return TimedTranscript(source: .podcasting20, segments: segments)
    }

    // MARK: - SubRip

    public static func parseSRT(_ text: String) throws -> TimedTranscript {
        // SRT differs from VTT mainly in using a comma as the decimal separator
        // and requiring a numeric index line, both of which the VTT path already
        // tolerates once the separator is normalized.
        let normalized = text.replacingOccurrences(
            of: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#,
            with: "$1.$2",
            options: .regularExpression
        )
        return try parseVTT(normalized)
    }

    // MARK: - JSON

    /// The Podcasting 2.0 JSON transcript format.
    public static func parseJSON(_ text: String) throws -> TimedTranscript {
        struct Document: Decodable {
            struct Segment: Decodable {
                let startTime: Double
                let endTime: Double
                let body: String
                let speaker: String?
            }
            let segments: [Segment]
        }

        guard let data = text.data(using: .utf8) else {
            throw TranscriptParseError.malformed("not valid UTF-8")
        }

        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            let segments = document.segments.compactMap { segment -> TimedTranscript.Segment? in
                let body = segment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return .init(
                    startMs: Int(segment.startTime * 1000),
                    endMs: Int(segment.endTime * 1000),
                    text: body,
                    speaker: segment.speaker
                )
            }
            guard !segments.isEmpty else { throw TranscriptParseError.noCues }
            return TimedTranscript(source: .podcasting20, segments: segments)
        } catch let error as TranscriptParseError {
            throw error
        } catch {
            throw TranscriptParseError.malformed(error.localizedDescription)
        }
    }

    // MARK: - Shared helpers

    /// Matches `00:01:02.345 --> 00:01:05.678`, with the hours field optional
    /// (WebVTT permits `MM:SS.mmm`) and any trailing cue settings ignored.
    static func parseTimingLine(_ line: String) -> (start: Int, end: Int)? {
        guard line.contains("-->") else { return nil }
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2 else { return nil }

        guard let start = parseTimestamp(sides[0]) else { return nil }
        // Cue settings such as `align:start position:50%` follow the end time.
        let endToken = sides[1]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let endToken, let end = parseTimestamp(endToken) else { return nil }

        return (start, end)
    }

    static func parseTimestamp(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Double
        let minutes: Double
        let seconds: Double

        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
                return nil
            }
            (hours, minutes, seconds) = (h, m, s)
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            (hours, minutes, seconds) = (0, m, s)
        }

        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return Int((hours * 3600 + minutes * 60 + seconds) * 1000)
    }

    /// Pulls the speaker out of a WebVTT voice span, returning the remaining text.
    static func extractVoiceSpan(from line: String) -> (speaker: String?, text: String) {
        guard line.hasPrefix("<v ") || line.hasPrefix("<v.") else { return (nil, line) }
        guard let closeIndex = line.firstIndex(of: ">") else { return (nil, line) }

        let tagBody = line[line.index(line.startIndex, offsetBy: 2)..<closeIndex]
        // `<v.loud Chris>` carries CSS classes before the name.
        let speaker = tagBody
            .split(separator: " ")
            .dropFirst(tagBody.hasPrefix(".") ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let remainder = String(line[line.index(after: closeIndex)...])
        return (speaker.nilIfEmpty, remainder)
    }

    /// Removes the inline markup WebVTT permits (`<b>`, `<i>`, `<c.class>`,
    /// timestamp tags) without pulling in a full HTML parser.
    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

public enum TranscriptParseError: Error, Sendable, Equatable {
    case noCues
    case malformed(String)
}
