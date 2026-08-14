import Foundation

/// Top-charts browsing via Apple's public RSS generator (§8.1). Returns chart
/// entries whose feed URLs are resolved through the lookup endpoint on demand —
/// the chart feed itself does not carry `feedUrl`.
public struct TopChartsClient: Sendable {
    public struct ChartEntry: Identifiable, Hashable, Sendable {
        public var id: Int
        public var name: String
        public var artistName: String?
        public var artworkURL: URL?
    }

    private let client: any HTTPClient
    private let search: ITunesSearchClient

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
        self.search = ITunesSearchClient(client: client)
    }

    public func topPodcasts(limit: Int = 25, storefront: String = "us") async throws -> [ChartEntry] {
        let url = URL(string:
            "https://rss.marketingtools.apple.com/api/v2/\(storefront)/podcasts/top/\(limit)/podcasts.json"
        )!
        let (data, response) = try await client.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode)
        }

        struct Payload: Decodable {
            struct Feed: Decodable {
                struct Result: Decodable {
                    let id: String
                    let name: String
                    let artistName: String?
                    let artworkUrl100: String?
                }
                let results: [Result]
            }
            let feed: Feed
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.feed.results.compactMap { result in
            guard let id = Int(result.id) else { return nil }
            return ChartEntry(
                id: id,
                name: result.name,
                artistName: result.artistName,
                artworkURL: result.artworkUrl100.flatMap(URL.init(string:))
            )
        }
    }

    /// Chart → subscribable feed URL, one lookup. Cached upstream by the
    /// directory; called only when the user taps a chart row.
    public func feedURL(for entry: ChartEntry) async throws -> URL? {
        try await search.lookup(collectionID: entry.id)?.feedURL
    }
}
