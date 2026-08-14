import Foundation

/// A show as returned by the iTunes Search API.
public struct PodcastSearchResult: Identifiable, Hashable, Sendable {
    public var id: Int { collectionID }
    public var collectionID: Int
    public var title: String
    public var author: String?
    /// The show's real RSS endpoint. Everything after discovery talks to this
    /// directly — Apple is never consulted about the show again.
    public var feedURL: URL?
    public var artworkURL: URL?
    public var genres: [String]
    public var episodeCount: Int?

    public init(
        collectionID: Int,
        title: String,
        author: String? = nil,
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        genres: [String] = [],
        episodeCount: Int? = nil
    ) {
        self.collectionID = collectionID
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.genres = genres
        self.episodeCount = episodeCount
    }
}

/// Discovery against the iTunes Search API.
///
/// There is no Apple Podcasts content API. Apple Podcasts is a *directory* over
/// the same open RSS feeds every podcast app uses, and the Search API is the
/// public, free way into it (§8.1). The flow is: search the directory, take
/// `feedUrl`, subscribe to the RSS feed directly.
public struct ITunesSearchClient: Sendable {
    private let client: any HTTPClient
    private let baseURL: URL

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://itunes.apple.com")!
    ) {
        self.client = client
        self.baseURL = baseURL
    }

    public func search(term: String, limit: Int = 25) async throws -> [PodcastSearchResult] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "media", value: "podcast"),
            .init(name: "term", value: term),
            .init(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }
        return try await fetchResults(from: url)
    }

    public func lookup(collectionID: Int) async throws -> PodcastSearchResult? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("lookup"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "id", value: String(collectionID))]
        guard let url = components?.url else { return nil }
        return try await fetchResults(from: url).first
    }

    private func fetchResults(from url: URL) async throws -> [PodcastSearchResult] {
        let (data, response) = try await client.data(for: URLRequest(url: url))

        // The directory rate-limits aggressively enough that a search-as-you-type
        // field will hit it. Surface it as a distinct error so callers can back
        // off rather than showing "no results" (§8.1).
        if response.statusCode == 403 || response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HTTPError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode)
        }

        let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        return payload.results.compactMap(\.asSearchResult)
    }
}

// MARK: - Wire format

private struct SearchResponse: Decodable {
    let results: [Entry]

    struct Entry: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let trackName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
        let genres: [String]?
        let trackCount: Int?

        var asSearchResult: PodcastSearchResult? {
            guard let collectionId else { return nil }
            guard let title = collectionName ?? trackName else { return nil }
            return PodcastSearchResult(
                collectionID: collectionId,
                title: title,
                author: artistName,
                feedURL: feedUrl.flatMap(sanitizedURL),
                artworkURL: (artworkUrl600 ?? artworkUrl100).flatMap(sanitizedURL),
                genres: genres ?? [],
                episodeCount: trackCount
            )
        }
    }
}
