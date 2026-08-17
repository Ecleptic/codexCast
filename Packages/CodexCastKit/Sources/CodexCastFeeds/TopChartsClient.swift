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

    // MARK: - Genre charts

    /// The directory's podcast genres, curated to the useful set.
    public static let genres: [(id: Int, name: String)] = [
        (1318, "Technology"), (1489, "News"), (1303, "Comedy"),
        (1321, "Business"), (1488, "True Crime"), (1324, "Society & Culture"),
        (1533, "Science"), (1487, "History"), (1512, "Health & Fitness"),
        (1545, "Sports"), (1301, "Arts"), (1304, "Education"),
        (1310, "Music"), (1483, "Fiction"), (1309, "TV & Film"),
    ]

    /// Per-genre top podcasts via the legacy RSS generator — the modern
    /// marketing-tools endpoint has no genre axis, and the legacy one still
    /// serves (verified live before this shipped).
    public func topPodcasts(
        genre: Int, limit: Int = 25, storefront: String = "us"
    ) async throws -> [ChartEntry] {
        let url = URL(string:
            "https://itunes.apple.com/\(storefront)/rss/toppodcasts/limit=\(limit)/genre=\(genre)/json"
        )!
        let (data, response) = try await client.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode)
        }

        struct Payload: Decodable {
            struct Feed: Decodable {
                struct Entry: Decodable {
                    struct Labeled: Decodable { let label: String }
                    struct Image: Decodable { let label: String }
                    struct ID: Decodable {
                        struct Attributes: Decodable {
                            let imId: String
                            enum CodingKeys: String, CodingKey { case imId = "im:id" }
                        }
                        let attributes: Attributes
                    }
                    let imName: Labeled
                    let imArtist: Labeled?
                    let imImage: [Image]?
                    let id: ID

                    enum CodingKeys: String, CodingKey {
                        case imName = "im:name"
                        case imArtist = "im:artist"
                        case imImage = "im:image"
                        case id
                    }
                }
                let entry: [Entry]?
            }
            let feed: Feed
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.feed.entry ?? []).compactMap { entry in
            guard let id = Int(entry.id.attributes.imId) else { return nil }
            return ChartEntry(
                id: id,
                name: entry.imName.label,
                artistName: entry.imArtist?.label,
                artworkURL: entry.imImage?.last.flatMap { URL(string: $0.label) }
            )
        }
    }
}
