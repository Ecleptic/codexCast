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

    public struct Genre: Sendable, Hashable, Identifiable {
        public let id: Int
        public let name: String
        public let children: [Genre]

        public init(id: Int, name: String, children: [Genre] = []) {
            self.id = id
            self.name = name
            self.children = children
        }
    }

    /// The directory's genre tree, curated to entries verified live against
    /// the chart API (2026-08-17). Apple offers no "development" genre;
    /// Technology and News → Tech News are the closest it has.
    public static let genreTree: [Genre] = [
        Genre(id: 1318, name: "Technology"),
        Genre(id: 1489, name: "News", children: [
            Genre(id: 1526, name: "Daily News"), Genre(id: 1531, name: "Tech News"),
            Genre(id: 1529, name: "Politics"), Genre(id: 1490, name: "Business News"),
        ]),
        Genre(id: 1303, name: "Comedy", children: [
            Genre(id: 1497, name: "Stand-Up"), Genre(id: 1495, name: "Interviews"),
        ]),
        Genre(id: 1321, name: "Business", children: [
            Genre(id: 1412, name: "Investing"), Genre(id: 1493, name: "Entrepreneurship"),
        ]),
        Genre(id: 1488, name: "True Crime"),
        Genre(id: 1502, name: "Leisure", children: [
            Genre(id: 1510, name: "Video Games"), Genre(id: 1507, name: "Games"),
            Genre(id: 1504, name: "Automotive"),
        ]),
        Genre(id: 1545, name: "Sports", children: [
            Genre(id: 1553, name: "Football"), Genre(id: 1547, name: "Basketball"),
            Genre(id: 1546, name: "Baseball"), Genre(id: 1557, name: "Soccer"),
            Genre(id: 1564, name: "Wrestling"),
        ]),
        Genre(id: 1324, name: "Society & Culture", children: [
            Genre(id: 1543, name: "Documentary"), Genre(id: 1544, name: "Relationships"),
        ]),
        Genre(id: 1533, name: "Science"),
        Genre(id: 1487, name: "History"),
        Genre(id: 1512, name: "Health & Fitness", children: [
            Genre(id: 1516, name: "Mental Health"), Genre(id: 1514, name: "Fitness"),
            Genre(id: 1517, name: "Nutrition"),
        ]),
        Genre(id: 1301, name: "Arts", children: [
            Genre(id: 1482, name: "Books"), Genre(id: 1306, name: "Food"),
        ]),
        Genre(id: 1304, name: "Education", children: [
            Genre(id: 1501, name: "Self-Improvement"), Genre(id: 1499, name: "How To"),
            Genre(id: 1500, name: "Language Learning"),
        ]),
        Genre(id: 1305, name: "Kids & Family", children: [
            Genre(id: 1521, name: "Parenting"),
        ]),
        Genre(id: 1310, name: "Music"),
        Genre(id: 1483, name: "Fiction"),
        Genre(id: 1309, name: "TV & Film"),
    ]

    /// Flat top-level list, kept for callers that don't browse the tree.
    public static var genres: [(id: Int, name: String)] {
        genreTree.map { ($0.id, $0.name) }
    }

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
