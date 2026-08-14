import CodexCastCore
import Foundation
import Testing

@testable import CodexCastFeeds

/// Fixtures are real feed documents, trimmed to their first couple of items.
/// Hand-written XML would have been tidier and would have tested nothing —
/// every interesting case in this file came from a feed that ships today.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "xml")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }
}

@Suite("Feed parsing — real feeds")
struct RealFeedParsingTests {
    @Test("Tech Brew Ride Home: a plain RSS feed with no Podcasting 2.0 tags")
    func ridehome() throws {
        let feed = try FeedParser().parse(data: Fixture.data("ridehome"))

        #expect(feed.title == "Tech Brew Ride Home")
        #expect(!feed.hadRecoverableError)
        #expect(feed.episodes.count == 2)

        let episode = try #require(feed.episodes.first)
        #expect(!episode.guid.isEmpty)
        #expect(episode.publishedAt != nil)
        #expect(episode.renditions.contains { $0.isPrimaryEnclosure })
        #expect(episode.transcripts.isEmpty)
        #expect(episode.chaptersURL == nil)
    }

    @Test("The Nextlander Podcast: declares the podcast namespace but uses no tags from it")
    func nextlander() throws {
        let feed = try FeedParser().parse(data: Fixture.data("nextlander"))

        #expect(feed.title == "The Nextlander Podcast")
        #expect(feed.episodes.count == 2)
        #expect(feed.episodes.allSatisfy { $0.transcripts.isEmpty })
        #expect(feed.episodes.allSatisfy { !$0.renditions.isEmpty })
    }

    @Test("LINUX Unplugged: transcripts, chapters, and a 1080p video rendition together")
    func linuxUnplugged() throws {
        let feed = try FeedParser().parse(data: Fixture.data("linuxunplugged"))

        #expect(feed.title == "LINUX Unplugged")
        let episode = try #require(feed.episodes.first)

        // Both VTT and SRT are advertised for the same episode.
        #expect(episode.transcripts.count == 2)
        #expect(Set(episode.transcripts.map(\.format)) == [.vtt, .srt])
        #expect(episode.transcripts.preferred?.format == .vtt)

        #expect(episode.chaptersURL != nil)

        let video = try #require(episode.renditions.first { $0.isVideo })
        #expect(video.height == 1080)
        #expect(video.codecs?.contains("avc1") == true)
        #expect(video.delivery == .file)

        // Detection still has an audio file to work from, so no video decoding
        // is required anywhere in the pipeline.
        #expect(episode.renditions.contains { $0.isAudio })
    }

    /// The flagship Podcasting 2.0 feed declares its HLS stream as
    /// `application.x-mpegURL` — a dot where the slash belongs. Detecting HLS
    /// by MIME type alone would miss it.
    @Test("Podcasting 2.0: HLS video survives a malformed MIME type")
    func podcasting20MalformedMIME() throws {
        let feed = try FeedParser().parse(data: Fixture.data("pc20"))

        let episode = try #require(
            feed.episodes.first { episode in
                episode.renditions.contains { $0.relation == "alternate" }
            }
        )
        let alternate = try #require(episode.renditions.first { !$0.isPrimaryEnclosure })

        #expect(alternate.mimeType == "application.x-mpegURL")
        #expect(alternate.isLikelyHLS)
        #expect(alternate.delivery == .hls)
        #expect(alternate.height == 720)
        #expect(alternate.sources.first?.absoluteString.hasSuffix(".m3u8") == true)
        #expect(alternate.languageCode == "en")
    }

    /// Podnews ships three audio renditions per episode — 12k Opus, 32k AAC,
    /// and a 128k MP3 marked `default="true"`.
    @Test("Podnews Daily: multi-bitrate audio alternates and the default marker")
    func podnewsAlternates() throws {
        let feed = try FeedParser().parse(data: Fixture.data("podnews"))
        let episode = try #require(feed.episodes.first)

        let alternates = episode.renditions.filter { !$0.isPrimaryEnclosure }
        #expect(alternates.count >= 3)
        #expect(alternates.allSatisfy { $0.isAudio })
        #expect(alternates.contains { $0.isDefault })

        // Analysis wants the cheapest audio, since the file is downloaded only
        // to be transcribed.
        let core = Episode(
            podcastID: Podcast.ID(),
            guid: episode.guid,
            title: episode.title,
            renditions: episode.renditions
        )
        let selected = try #require(core.analysisRendition)
        let minBitrate = episode.renditions.compactMap(\.bitrate).min()
        #expect(selected.bitrate == minBitrate)
    }
}

@Suite("Feed parsing — malformed input")
struct MalformedFeedTests {
    /// A truncated document must not cost the user their subscription. Whatever
    /// parsed before the fault is kept (§8.2).
    @Test("A truncated feed returns the items parsed before the fault")
    func truncatedFeedRecovers() throws {
        let full = try Fixture.data("linuxunplugged")
        let truncated = full.prefix(full.count / 2)

        let feed = try FeedParser().parse(data: Data(truncated))

        #expect(feed.hadRecoverableError)
        #expect(feed.recoveredErrorDescription != nil)
        #expect(feed.title == "LINUX Unplugged")
    }

    @Test("Junk that is not XML at all throws rather than inventing a feed")
    func nonXMLThrows() {
        let data = Data("this is not a feed".utf8)

        #expect(throws: FeedParseError.self) {
            try FeedParser().parse(data: data)
        }
    }

    @Test("An item with no playable enclosure is skipped, not surfaced as unplayable")
    func itemWithoutEnclosureSkipped() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Test</title>
          <item><title>No media here</title><guid>a</guid></item>
          <item><title>Playable</title><guid>b</guid>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
          </item>
        </channel></rss>
        """

        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.episodes.count == 1)
        #expect(feed.episodes.first?.title == "Playable")
    }

    /// Without a stable fallback, episodes lacking a guid duplicate on every
    /// single refresh.
    @Test("A missing guid falls back to the enclosure URL")
    func missingGUIDFallsBack() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Test</title>
          <item><title>Ep</title>
            <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" length="1"/>
          </item>
        </channel></rss>
        """

        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.episodes.first?.guid == "https://example.com/ep1.mp3")
    }

    /// The namespace prefix is the feed author's choice, so matching on the
    /// literal string "podcast:" would be wrong.
    @Test("Podcasting 2.0 tags are found under a non-standard namespace prefix")
    func nonStandardNamespacePrefix() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:pc="https://podcastindex.org/namespace/1.0"><channel>
          <title>Test</title>
          <item><title>Ep</title><guid>a</guid>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
            <pc:transcript url="https://example.com/a.vtt" type="text/vtt"/>
          </item>
        </channel></rss>
        """

        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.episodes.first?.transcripts.first?.format == .vtt)
    }
}

@Suite("Large feed handling")
struct LargeFeedTests {
    /// Tech Brew Ride Home is 12.4 MB across 2,399 items and is the first feed
    /// this app will load. Retaining the whole back catalogue is pointless, so
    /// the parser caps what it keeps.
    @Test("Item retention is capped without failing the parse")
    func retentionCap() throws {
        let xml = try makeFeed(itemCount: 300)

        let feed = try FeedParser(maxItems: 50).parse(data: xml)

        #expect(feed.episodes.count == 50)
        #expect(!feed.hadRecoverableError)
    }

    @Test("A feed far larger than the cap still parses in reasonable time")
    func largeFeedParses() throws {
        let xml = try makeFeed(itemCount: 2_400)

        let start = Date()
        let feed = try FeedParser(maxItems: 500).parse(data: xml)
        let elapsed = Date().timeIntervalSince(start)

        #expect(feed.episodes.count == 500)
        #expect(elapsed < 10)
    }

    private func makeFeed(itemCount: Int) throws -> Data {
        var xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Big Feed</title>
        """
        for index in 0..<itemCount {
            xml += """
            <item><title>Episode \(index)</title><guid>guid-\(index)</guid>
            <pubDate>Wed, 13 Aug 2026 10:00:00 -0400</pubDate>
            <enclosure url="https://example.com/\(index).mp3" type="audio/mpeg" length="1"/>
            </item>
            """
        }
        xml += "</channel></rss>"
        return Data(xml.utf8)
    }
}

@Suite("Dates and durations")
struct DateAndDurationTests {
    @Test(
        "Real-world pubDate formats parse",
        arguments: [
            "Wed, 13 Aug 2026 10:00:00 -0400",
            "Wed, 13 Aug 2026 10:00:00 GMT",
            "Wed, 13 Aug 2026 10:00 -0400",
            "13 Aug 2026 10:00:00 GMT",
            "2026-08-13T10:00:00Z",
        ]
    )
    func parsesDates(input: String) {
        #expect(RFC822DateParser.date(from: input) != nil)
    }

    @Test("Garbage dates yield nil rather than a wrong date")
    func rejectsGarbageDates() {
        #expect(RFC822DateParser.date(from: "sometime last tuesday") == nil)
        #expect(RFC822DateParser.date(from: "") == nil)
    }

    @Test(
        "itunes:duration parses as seconds, MM:SS, and HH:MM:SS",
        arguments: [
            ("3723", 3_723_000),
            ("62:03", 3_723_000),
            ("1:02:03", 3_723_000),
            ("0", 0),
        ]
    )
    func parsesDurations(input: String, expected: Int) {
        #expect(DurationParser.milliseconds(from: input) == expected)
    }

    @Test("Nonsense durations yield nil")
    func rejectsGarbageDurations() {
        #expect(DurationParser.milliseconds(from: "abc") == nil)
        #expect(DurationParser.milliseconds(from: "1:2:3:4") == nil)
        #expect(DurationParser.milliseconds(from: "-5") == nil)
    }
}
