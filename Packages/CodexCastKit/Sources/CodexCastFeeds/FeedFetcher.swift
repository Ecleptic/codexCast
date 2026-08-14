import CodexCastCore
import Foundation

/// Fetches and parses feeds, using conditional GETs so an unchanged feed costs
/// no body transfer. With a 12.4 MB feed in the subscription list, this is the
/// difference between a cheap refresh and an expensive one.
public struct FeedFetcher: Sendable {
    public enum Result: Sendable {
        case notModified
        case updated(ParsedFeed, validators: HTTPCacheValidators)
    }

    private let client: any HTTPClient
    private let parser: FeedParser
    private let userAgent: String

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        parser: FeedParser = FeedParser(),
        userAgent: String = "CodexCast/1.0"
    ) {
        self.client = client
        self.parser = parser
        self.userAgent = userAgent
    }

    public func fetch(
        _ url: URL,
        validators: HTTPCacheValidators? = nil
    ) async throws -> Result {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.applyConditionalHeaders(validators)

        let (data, response) = try await client.data(for: request)

        switch response.statusCode {
        case 304:
            return .notModified
        case 200..<300:
            let feed = try parser.parse(data: data, feedURL: url)
            return .updated(feed, validators: response.cacheValidators)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HTTPError.rateLimited(retryAfter: retryAfter)
        default:
            throw HTTPError.status(response.statusCode)
        }
    }

    /// Fetches a feed-supplied transcript. This is the §8.2 fast path: when it
    /// succeeds, on-device transcription is skipped entirely.
    public func fetchTranscript(
        _ reference: FeedTranscriptReference
    ) async throws -> TimedTranscript {
        var request = URLRequest(url: reference.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptParseError.malformed("not valid UTF-8")
        }
        return try TranscriptParser.parse(text, format: reference.format)
    }

    public func fetchChapters(_ url: URL) async throws -> [Chapter] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode)
        }
        return try ChapterParser.parse(data)
    }
}
