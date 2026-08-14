import CodexCastCore
import Foundation
import Testing

@testable import CodexCastFeeds

extension Fixture {
    static func text(_ name: String, extension ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
        else {
            throw FixtureError.missing("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("Transcript parsing — real files")
struct TranscriptParsingTests {
    /// LINUX Unplugged's VTT carries speaker voice spans. Keeping the speaker is
    /// worth the small effort: a change of voice is one of the strongest human
    /// cues that an ad has started, and here it arrives free.
    @Test("WebVTT parses with millisecond timings and speaker names")
    func parsesRealVTT() throws {
        let transcript = try TranscriptParser.parseVTT(Fixture.text("lup", extension: "vtt"))

        #expect(!transcript.isEmpty)
        #expect(transcript.source == .podcasting20)

        let first = try #require(transcript.segments.first)
        #expect(first.startMs == 31_752)
        #expect(first.endMs == 35_961)
        #expect(first.speaker == "Chris")
        #expect(first.text.contains("Linux Tuesday"))
        // The voice tag itself must not leak into the text.
        #expect(!first.text.contains("<v"))
    }

    @Test("Segments come out in ascending time order with sane durations")
    func vttOrdering() throws {
        let transcript = try TranscriptParser.parseVTT(Fixture.text("lup", extension: "vtt"))

        let starts = transcript.segments.map(\.startMs)
        #expect(starts == starts.sorted())
        #expect(transcript.segments.allSatisfy { $0.endMs >= $0.startMs })
    }

    /// SRT is the same content with comma decimals and no voice spans, so the
    /// two formats must agree on timings for the same episode.
    @Test("SRT and VTT of the same episode agree on timings")
    func srtMatchesVTT() throws {
        let vtt = try TranscriptParser.parseVTT(Fixture.text("lup", extension: "vtt"))
        let srt = try TranscriptParser.parseSRT(Fixture.text("lup", extension: "srt"))

        #expect(srt.segments.count == vtt.segments.count)
        #expect(srt.segments.first?.startMs == vtt.segments.first?.startMs)
        #expect(srt.segments.first?.endMs == vtt.segments.first?.endMs)
        // SRT carries no speaker information — which is why VTT is preferred.
        #expect(srt.segments.first?.speaker == nil)
    }

    /// Podnews ships VTT with no voice spans at all, so speaker must be absent
    /// rather than guessed at.
    @Test("VTT without voice spans parses cleanly with no speaker")
    func vttWithoutSpeakers() throws {
        let transcript = try TranscriptParser.parseVTT(Fixture.text("podnews", extension: "vtt"))

        #expect(!transcript.isEmpty)
        #expect(transcript.segments.allSatisfy { $0.speaker == nil })
        #expect(transcript.segments.allSatisfy { !$0.text.isEmpty })
    }
}

@Suite("Transcript parsing — synthetic edge cases")
struct TranscriptEdgeCaseTests {
    @Test("Cue identifiers and NOTE blocks are not treated as content")
    func ignoresNonCueLines() throws {
        let vtt = """
        WEBVTT

        NOTE This is a comment that must not appear in the transcript.

        cue-identifier-1
        00:00:01.000 --> 00:00:02.000
        Real content.
        """

        let transcript = try TranscriptParser.parseVTT(vtt)

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments.first?.text == "Real content.")
    }

    /// WebVTT permits `MM:SS.mmm` with the hour field omitted.
    @Test("Timestamps without an hours field parse")
    func shortTimestamps() throws {
        let vtt = """
        WEBVTT

        01:30.500 --> 01:32.000
        Short form.
        """

        let transcript = try TranscriptParser.parseVTT(vtt)

        #expect(transcript.segments.first?.startMs == 90_500)
        #expect(transcript.segments.first?.endMs == 92_000)
    }

    @Test("Cue settings after the end time are ignored")
    func ignoresCueSettings() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 align:start position:50%
        Positioned text.
        """

        let transcript = try TranscriptParser.parseVTT(vtt)

        #expect(transcript.segments.first?.endMs == 2_000)
        #expect(transcript.segments.first?.text == "Positioned text.")
    }

    @Test("Inline markup is stripped from cue text")
    func stripsInlineMarkup() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        <b>Bold</b> and <i>italic</i> text.
        """

        let transcript = try TranscriptParser.parseVTT(vtt)

        #expect(transcript.segments.first?.text == "Bold and italic text.")
    }

    @Test("A voice span carrying CSS classes still yields the speaker name")
    func voiceSpanWithClasses() throws {
        let (speaker, text) = TranscriptParser.extractVoiceSpan(from: "<v.loud Chris>Hello there")

        #expect(speaker == "Chris")
        #expect(text == "Hello there")
    }

    @Test("A file with no cues is an error, not an empty transcript")
    func noCuesThrows() {
        #expect(throws: TranscriptParseError.self) {
            try TranscriptParser.parseVTT("WEBVTT\n\nNOTE nothing here\n")
        }
    }

    @Test("Podcasting 2.0 JSON transcripts parse with speakers")
    func parsesJSONTranscript() throws {
        let json = """
        {"version":"1.0.0","segments":[
          {"speaker":"Alice","startTime":1.5,"endTime":3.25,"body":"First line."},
          {"speaker":"Bob","startTime":3.25,"endTime":5.0,"body":"Second line."}
        ]}
        """

        let transcript = try TranscriptParser.parseJSON(json)

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.first?.startMs == 1_500)
        #expect(transcript.segments.first?.endMs == 3_250)
        #expect(transcript.segments.last?.speaker == "Bob")
    }
}

@Suite("Chapter parsing")
struct ChapterParsingTests {
    /// LINUX Unplugged episode 679 ships its chapters effectively reversed:
    /// `startTime: 0` is titled "Outro" and the final entry is titled "Intro".
    /// The parser sorts by time so no caller has to remember to, and no code
    /// anywhere reads meaning into the titles.
    @Test("A real, unsorted chapter file comes back in time order")
    func parsesUnsortedRealChapters() throws {
        let data = try Fixture.data("lup_chapters", extension: "json")

        let chapters = try ChapterParser.parse(data)

        #expect(chapters.count == 7)
        let starts = chapters.map(\.startMs)
        #expect(starts == starts.sorted())
        #expect(chapters.first?.startMs == 0)
        #expect(chapters.last?.startMs == 3_374_000)
        #expect(chapters.allSatisfy { $0.source == .feed })
    }

    @Test("Chapters marked toc:false are excluded from navigation")
    func excludesNonTOCChapters() throws {
        let json = """
        {"chapters":[
          {"startTime":0,"title":"Intro"},
          {"startTime":60,"title":"Hidden","toc":false},
          {"startTime":120,"title":"Topic"}
        ]}
        """

        let chapters = try ChapterParser.parse(Data(json.utf8))

        #expect(chapters.map(\.title) == ["Intro", "Topic"])
    }

    @Test("Untitled chapters are dropped rather than shown blank")
    func dropsUntitledChapters() throws {
        let json = """
        {"chapters":[{"startTime":0,"title":"Intro"},{"startTime":60},{"startTime":90,"title":"  "}]}
        """

        let chapters = try ChapterParser.parse(Data(json.utf8))

        #expect(chapters.count == 1)
    }

    @Test("Malformed chapter JSON throws rather than returning nothing silently")
    func malformedChaptersThrow() {
        #expect(throws: ChapterParseError.self) {
            try ChapterParser.parse(Data("not json".utf8))
        }
    }
}

extension Fixture {
    static func data(_ name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
        else {
            throw FixtureError.missing("\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}
