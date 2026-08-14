import CodexCastCore
import Foundation

/// The result of parsing a feed document.
///
/// Deliberately free of persistent identifiers: the parser has no idea which
/// `Podcast` or `Episode` rows these correspond to. Matching happens in the
/// persistence layer, by feed URL and by `<guid>`.
public struct ParsedFeed: Hashable, Sendable {
    public var title: String
    public var author: String?
    public var summary: String?
    public var imageURL: URL?
    public var link: URL?
    public var languageCode: String?
    public var isExplicit: Bool
    public var categories: [String]
    public var episodes: [ParsedEpisode]

    /// True when the document was malformed but enough was recovered to be
    /// useful. Podcast feeds are frequently broken; a parse error must not cost
    /// the user their subscription (§8.2).
    public var hadRecoverableError: Bool
    public var recoveredErrorDescription: String?

    public init(
        title: String,
        author: String? = nil,
        summary: String? = nil,
        imageURL: URL? = nil,
        link: URL? = nil,
        languageCode: String? = nil,
        isExplicit: Bool = false,
        categories: [String] = [],
        episodes: [ParsedEpisode] = [],
        hadRecoverableError: Bool = false,
        recoveredErrorDescription: String? = nil
    ) {
        self.title = title
        self.author = author
        self.summary = summary
        self.imageURL = imageURL
        self.link = link
        self.languageCode = languageCode
        self.isExplicit = isExplicit
        self.categories = categories
        self.episodes = episodes
        self.hadRecoverableError = hadRecoverableError
        self.recoveredErrorDescription = recoveredErrorDescription
    }
}

public struct ParsedEpisode: Hashable, Sendable {
    /// The feed's `<guid>`, falling back to the enclosure URL when absent —
    /// which happens often enough to matter, and without it episodes duplicate
    /// on every refresh.
    public var guid: String
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    public var declaredDurationMs: Int?
    public var imageURL: URL?
    public var episodeNumber: Int?
    public var seasonNumber: Int?
    /// The standard `<enclosure>` plus every `<podcast:alternateEnclosure>`,
    /// in feed order.
    public var renditions: [Rendition]
    public var transcripts: [FeedTranscriptReference]
    public var chaptersURL: URL?

    public init(
        guid: String,
        title: String,
        summary: String? = nil,
        publishedAt: Date? = nil,
        declaredDurationMs: Int? = nil,
        imageURL: URL? = nil,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        renditions: [Rendition] = [],
        transcripts: [FeedTranscriptReference] = [],
        chaptersURL: URL? = nil
    ) {
        self.guid = guid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.declaredDurationMs = declaredDurationMs
        self.imageURL = imageURL
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.renditions = renditions
        self.transcripts = transcripts
        self.chaptersURL = chaptersURL
    }
}

public enum FeedParseError: Error, Sendable, Equatable {
    /// The document was malformed badly enough that nothing usable came out.
    case unrecoverable(String)
    /// Parsed successfully but contained no `<item>` elements.
    case noEpisodes
}
