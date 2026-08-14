import Foundation

/// A chapter marker, either authored by the feed or generated on device (§5.8).
///
/// Detected ad segments render alongside chapters in the same timeline because
/// conceptually they are the same object — a named region of the episode,
/// authored in one case and inferred in the other.
public struct Chapter: Identifiable, Hashable, Sendable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    public enum Source: String, Hashable, Sendable, Codable {
        case feed
        case generated
    }

    public var id: ID
    public var startMs: Int
    public var title: String
    public var source: Source
    public var imageURL: URL?
    public var url: URL?

    public init(
        id: ID = ID(),
        startMs: Int,
        title: String,
        source: Source,
        imageURL: URL? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.title = title
        self.source = source
        self.imageURL = imageURL
        self.url = url
    }
}

extension Array where Element == Chapter {
    /// Chapter files are not reliably ordered. LINUX Unplugged ships episodes
    /// whose chapter list arrives effectively reversed — `startTime: 0` titled
    /// "Outro" and the last entry titled "Intro". Always sort by time, and
    /// never infer position from a chapter's title.
    public func sortedByStart() -> [Chapter] {
        sorted { $0.startMs < $1.startMs }
    }
}
