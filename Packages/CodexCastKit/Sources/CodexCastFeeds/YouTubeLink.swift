import Foundation

/// Turns a YouTube link into a podcast feed, via a self-hosted Podsync
/// server. Share a channel from YouTube; get a subscribable show.
///
/// Podsync exposes channels at `/channel/<UC…>` and playlists at
/// `/rss/<PL…>` — the two shapes already in use in the author's library.
public enum YouTubeLink {
    public enum Target: Hashable, Sendable {
        /// A canonical channel ID (UC…), ready to use.
        case channel(String)
        /// An @handle or legacy /c//user name, which must be resolved to a
        /// channel ID by loading the page.
        case name(String)
        case playlist(String)
    }

    public enum LinkError: Error, Sendable, Equatable {
        case notYouTube
        case unsupportedLink
        case channelNotFound
    }

    /// What a shared YouTube URL points at, without touching the network.
    public static func target(for url: URL) -> Target? {
        guard let host = url.host?.lowercased() else { return nil }
        let isYouTube = host.hasSuffix("youtube.com") || host == "youtu.be"
            || host.hasSuffix("youtube-nocookie.com")
        guard isYouTube else { return nil }

        // A playlist parameter wins wherever it appears: sharing a playlist
        // is sharing the playlist, not the video that was open.
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let list = items.first(where: { $0.name == "list" })?.value,
           !list.isEmpty {
            return .playlist(list)
        }

        let parts = url.path.split(separator: "/").map(String.init)

        // youtube.com/@handle
        if let first = parts.first, first.hasPrefix("@") {
            return .name(first)
        }
        guard let first = parts.first else { return nil }
        switch first {
        case "channel":
            guard parts.count > 1 else { return nil }
            return .channel(parts[1])
        case "c", "user":
            guard parts.count > 1 else { return nil }
            return .name(parts[1])
        case "playlist":
            return nil   // handled by the `list` query above
        default:
            return nil
        }
    }

    /// Resolves to a canonical channel ID, loading the page only when the
    /// link carries a name rather than an ID.
    ///
    /// No API key: YouTube's own HTML carries the ID. The page is over a
    /// megabyte, so the whole body is searched — reading only the first
    /// chunk silently misses it.
    public static func channelID(
        for target: Target,
        client: any HTTPClient = URLSessionHTTPClient()
    ) async throws -> Target {
        switch target {
        case .channel, .playlist:
            return target
        case .name(let name):
            let path = name.hasPrefix("@") ? name : "c/\(name)"
            guard let url = URL(string: "https://www.youtube.com/\(path)") else {
                throw LinkError.unsupportedLink
            }
            var request = URLRequest(url: url)
            // A desktop browser UA: YouTube serves a stripped page otherwise.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode),
                  let html = String(data: data, encoding: .utf8)
            else { throw LinkError.channelNotFound }
            guard let id = extractChannelID(from: html) else {
                throw LinkError.channelNotFound
            }
            return .channel(id)
        }
    }

    static func extractChannelID(from html: String) -> String? {
        let patterns = [
            #"channel/(UC[A-Za-z0-9_-]{22})"#,
            #""(?:channelId|externalId)":"(UC[A-Za-z0-9_-]{22})""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let captured = Range(match.range(at: 1), in: html) {
                return String(html[captured])
            }
        }
        return nil
    }

    /// The Podsync feed URL for an already-resolved target.
    public static func podsyncFeedURL(for target: Target, server: URL) -> URL? {
        switch target {
        case .channel(let id):
            return server.appendingPathComponent("channel").appendingPathComponent(id)
        case .playlist(let id):
            return server.appendingPathComponent("rss").appendingPathComponent(id)
        case .name:
            return nil   // must be resolved first
        }
    }

    /// One call: shared YouTube URL in, Podsync feed URL out.
    public static func feedURL(
        forSharedURL url: URL,
        server: URL,
        client: any HTTPClient = URLSessionHTTPClient()
    ) async throws -> URL {
        guard let target = target(for: url) else { throw LinkError.notYouTube }
        let resolved = try await channelID(for: target, client: client)
        guard let feed = podsyncFeedURL(for: resolved, server: server) else {
            throw LinkError.unsupportedLink
        }
        return feed
    }
}
