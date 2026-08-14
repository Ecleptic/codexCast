import CodexCastCore
import Foundation
import Testing

@testable import CodexCastFeeds

/// Records what was requested and replays canned responses, so these tests
/// never touch the network and never flake.
final actor StubHTTPClient: HTTPClient {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    init(response: Response) {
        self.responses = [response]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.body, http)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

@Suite("Conditional feed fetching")
struct FeedFetcherTests {
    /// An unchanged feed must cost one round trip and no body. With a 12.4 MB
    /// feed subscribed, re-downloading on every refresh is not acceptable.
    @Test("A 304 response is reported as not-modified without parsing")
    func notModified() async throws {
        let client = StubHTTPClient(response: .init(status: 304))
        let fetcher = FeedFetcher(client: client)

        let result = try await fetcher.fetch(
            URL(string: "https://example.com/feed")!,
            validators: HTTPCacheValidators(etag: "\"abc\"")
        )

        guard case .notModified = result else {
            Issue.record("expected notModified, got \(result)")
            return
        }

        let sent = try #require(await client.recordedRequests().first)
        #expect(sent.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test("A 200 response parses and returns fresh validators to store")
    func parsesAndReturnsValidators() async throws {
        let body = try Fixture.data("nextlander")
        let client = StubHTTPClient(
            response: .init(
                status: 200,
                body: body,
                headers: ["ETag": "\"v2\"", "Last-Modified": "Wed, 13 Aug 2026 10:00:00 GMT"]
            )
        )
        let fetcher = FeedFetcher(client: client)

        let result = try await fetcher.fetch(URL(string: "https://example.com/feed")!)

        guard case .updated(let feed, let validators) = result else {
            Issue.record("expected updated, got \(result)")
            return
        }
        #expect(feed.title == "The Nextlander Podcast")
        #expect(validators.etag == "\"v2\"")
        #expect(validators.lastModified == "Wed, 13 Aug 2026 10:00:00 GMT")
    }

    @Test("Rate limiting surfaces as its own error, carrying Retry-After")
    func rateLimited() async throws {
        let client = StubHTTPClient(
            response: .init(status: 429, headers: ["Retry-After": "30"])
        )
        let fetcher = FeedFetcher(client: client)

        await #expect(throws: HTTPError.rateLimited(retryAfter: 30)) {
            try await fetcher.fetch(URL(string: "https://example.com/feed")!)
        }
    }

    @Test("Server errors surface the status code rather than an empty feed")
    func serverError() async throws {
        let client = StubHTTPClient(response: .init(status: 500))
        let fetcher = FeedFetcher(client: client)

        await #expect(throws: HTTPError.status(500)) {
            try await fetcher.fetch(URL(string: "https://example.com/feed")!)
        }
    }

    /// The whole point of the fast path: a feed-supplied transcript means
    /// on-device transcription never runs for this episode.
    @Test("A feed-supplied transcript is fetched and parsed into timed segments")
    func fetchesTranscript() async throws {
        let body = try Fixture.data("lup", extension: "vtt")
        let client = StubHTTPClient(response: .init(status: 200, body: body))
        let fetcher = FeedFetcher(client: client)

        let transcript = try await fetcher.fetchTranscript(
            FeedTranscriptReference(url: URL(string: "https://example.com/a.vtt")!, format: .vtt)
        )

        #expect(!transcript.isEmpty)
        #expect(transcript.source == .podcasting20)
        #expect(transcript.segments.first?.speaker == "Chris")
    }

    @Test("Chapters are fetched and sorted")
    func fetchesChapters() async throws {
        let body = try Fixture.data("lup_chapters", extension: "json")
        let client = StubHTTPClient(response: .init(status: 200, body: body))
        let fetcher = FeedFetcher(client: client)

        let chapters = try await fetcher.fetchChapters(URL(string: "https://example.com/c.json")!)

        #expect(chapters.count == 7)
        #expect(chapters.map(\.startMs) == chapters.map(\.startMs).sorted())
    }
}

@Suite("iTunes Search discovery")
struct ITunesSearchTests {
    private static let payload = """
    {"resultCount":2,"results":[
      {"collectionId":1,"collectionName":"Tech Brew Ride Home","artistName":"Ride Home Media",
       "feedUrl":"https://feeds.megaphone.fm/ridehome","artworkUrl600":"https://example.com/a.jpg",
       "genres":["Technology","News"],"trackCount":2399},
      {"collectionId":2,"collectionName":"No Feed Show","artistName":"Someone",
       "artworkUrl100":"https://example.com/b.jpg"}
    ]}
    """

    /// The feed URL is the only field that really matters — after discovery the
    /// app subscribes to RSS directly and never asks Apple about the show again.
    @Test("Search results carry the RSS feed URL")
    func searchReturnsFeedURL() async throws {
        let client = StubHTTPClient(response: .init(status: 200, body: Data(Self.payload.utf8)))
        let search = ITunesSearchClient(client: client)

        let results = try await search.search(term: "ride home")

        #expect(results.count == 2)
        #expect(results.first?.feedURL?.absoluteString == "https://feeds.megaphone.fm/ridehome")
        #expect(results.first?.episodeCount == 2399)
        #expect(results.first?.genres == ["Technology", "News"])
    }

    @Test("A show with no feed URL is still listed, just not subscribable")
    func resultWithoutFeedURL() async throws {
        let client = StubHTTPClient(response: .init(status: 200, body: Data(Self.payload.utf8)))
        let search = ITunesSearchClient(client: client)

        let results = try await search.search(term: "anything")

        #expect(results.last?.feedURL == nil)
        #expect(results.last?.artworkURL != nil)
    }

    @Test("An empty search term does not hit the network at all")
    func emptyTermSkipsRequest() async throws {
        let client = StubHTTPClient(response: .init(status: 200, body: Data(Self.payload.utf8)))
        let search = ITunesSearchClient(client: client)

        let results = try await search.search(term: "   ")

        #expect(results.isEmpty)
        #expect(await client.recordedRequests().isEmpty)
    }

    /// Search-as-you-type will hit the directory's limits, and showing
    /// "no results" would be a lie.
    @Test("Directory throttling is distinguishable from an empty result set")
    func throttlingIsDistinct() async throws {
        let client = StubHTTPClient(response: .init(status: 403))
        let search = ITunesSearchClient(client: client)

        await #expect(throws: HTTPError.rateLimited(retryAfter: nil)) {
            try await search.search(term: "anything")
        }
    }

    @Test("Lookup returns a single show")
    func lookup() async throws {
        let client = StubHTTPClient(response: .init(status: 200, body: Data(Self.payload.utf8)))
        let search = ITunesSearchClient(client: client)

        let result = try await search.lookup(collectionID: 1)

        #expect(result?.title == "Tech Brew Ride Home")
    }
}

@Suite("OPML")
struct OPMLTests {
    @Test("A typical export from another app imports")
    func parsesTypicalExport() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0"><head><title>Subscriptions</title></head><body>
          <outline text="Tech Brew Ride Home" type="rss" xmlUrl="https://feeds.megaphone.fm/ridehome"/>
          <outline text="Nextlander" type="rss" xmlUrl="https://audioboom.com/channels/5116059.rss"/>
        </body></opml>
        """

        let entries = try OPML.parse(Data(opml.utf8))

        #expect(entries.count == 2)
        #expect(entries.first?.title == "Tech Brew Ride Home")
    }

    /// Apps with folders nest outlines, and the folder rows carry no xmlUrl.
    /// Flattening is correct: there is no folder concept to import into.
    @Test("Nested folder structures are flattened to their feeds")
    func flattensFolders() throws {
        let opml = """
        <?xml version="1.0"?>
        <opml version="2.0"><body>
          <outline text="Tech">
            <outline text="Show A" type="rss" xmlUrl="https://example.com/a.rss"/>
            <outline text="Show B" type="rss" xmlUrl="https://example.com/b.rss"/>
          </outline>
        </body></opml>
        """

        let entries = try OPML.parse(Data(opml.utf8))

        #expect(entries.map(\.title) == ["Show A", "Show B"])
    }

    /// A feed filed under two folders appears twice in the export.
    @Test("Duplicate feed URLs are collapsed")
    func deduplicates() throws {
        let opml = """
        <?xml version="1.0"?>
        <opml version="2.0"><body>
          <outline text="Show A" xmlUrl="https://example.com/a.rss"/>
          <outline text="Show A again" xmlUrl="https://example.com/a.rss"/>
        </body></opml>
        """

        let entries = try OPML.parse(Data(opml.utf8))

        #expect(entries.count == 1)
    }

    @Test("An OPML file with no subscriptions is an error, not a silent no-op")
    func emptyOPMLThrows() {
        let opml = """
        <?xml version="1.0"?><opml version="2.0"><body></body></opml>
        """

        #expect(throws: OPMLError.noSubscriptions) {
            try OPML.parse(Data(opml.utf8))
        }
    }

    @Test("Export round-trips back through import")
    func roundTrips() throws {
        let entries = [
            OPMLEntry(title: "Show & Tell", feedURL: URL(string: "https://example.com/a.rss?x=1&y=2")!),
            OPMLEntry(title: "Quote \"Show\"", feedURL: URL(string: "https://example.com/b.rss")!),
        ]

        let exported = OPML.export(entries)
        let reimported = try OPML.parse(Data(exported.utf8))

        #expect(reimported == entries)
    }

    /// Ampersands in titles and query strings are the classic way an export
    /// becomes invalid XML.
    @Test("Special characters are escaped on export")
    func escapesSpecialCharacters() {
        let exported = OPML.export([
            OPMLEntry(title: "A & B", feedURL: URL(string: "https://example.com/a?x=1&y=2")!)
        ])

        #expect(exported.contains("A &amp; B"))
        #expect(exported.contains("x=1&amp;y=2"))
        #expect(!exported.contains("A & B"))
    }
}
