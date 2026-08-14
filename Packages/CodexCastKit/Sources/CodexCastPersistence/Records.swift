import CodexCastCore
import Foundation
import GRDB

/// Tagged identifiers are stored as UUID strings.
///
/// The conformance lives here rather than in CodexCastCore so that Core stays
/// free of GRDB — the domain models are used by the app, the eval harness, and
/// the Phase 0 spike, none of which should drag in a database.
extension TaggedID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        rawValue.uuidString.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
        guard let string = String.fromDatabaseValue(dbValue),
              let uuid = UUID(uuidString: string)
        else { return nil }
        return Self(uuid)
    }
}

// MARK: - Podcast

public struct PodcastRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "podcasts"

    public var id: Podcast.ID
    public var feedURL: String
    public var itunesCollectionID: Int?
    public var title: String
    public var author: String?
    public var summary: String?
    public var imageURL: String?
    public var addedAt: Date
    public var notes: String?
    public var etag: String?
    public var lastModified: String?
    public var lastRefreshedAt: Date?
    public var lastErrorDescription: String?
    /// Downloads to keep for this show; nil means unlimited (A5.3).
    public var episodeLimit: Int?
    public var autoDownloadEnabled: Bool

    public init(
        id: Podcast.ID = Podcast.ID(),
        feedURL: String,
        itunesCollectionID: Int? = nil,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        imageURL: String? = nil,
        addedAt: Date = Date(),
        notes: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        lastRefreshedAt: Date? = nil,
        lastErrorDescription: String? = nil,
        episodeLimit: Int? = nil,
        autoDownloadEnabled: Bool = false
    ) {
        self.id = id
        self.feedURL = feedURL
        self.itunesCollectionID = itunesCollectionID
        self.title = title
        self.author = author
        self.summary = summary
        self.imageURL = imageURL
        self.addedAt = addedAt
        self.notes = notes
        self.etag = etag
        self.lastModified = lastModified
        self.lastRefreshedAt = lastRefreshedAt
        self.lastErrorDescription = lastErrorDescription
        self.episodeLimit = episodeLimit
        self.autoDownloadEnabled = autoDownloadEnabled
    }

    public var domainModel: Podcast {
        Podcast(
            id: id,
            feedURL: URL(string: feedURL) ?? URL(fileURLWithPath: "/invalid"),
            itunesCollectionID: itunesCollectionID,
            title: title,
            author: author,
            summary: summary,
            imageURL: imageURL.flatMap(URL.init(string:)),
            addedAt: addedAt,
            notes: notes
        )
    }
}

// MARK: - Episode

public struct EpisodeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "episodes"

    public var id: Episode.ID
    public var podcastId: Podcast.ID
    public var guid: String
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    public var durationMs: Int?
    public var imageURL: String?
    public var episodeNumber: Int?
    public var seasonNumber: Int?
    /// Renditions and transcript references are JSON: read whole, written
    /// whole, never queried by field.
    public var renditions: String?
    public var selectedRenditionID: String?
    public var feedTranscripts: String?
    public var feedChaptersURL: String?
    public var localPath: String?
    public var mediaHash: String?
    public var transcriptSource: String?
    public var processingState: String
    public var notTranscribableReason: String?
    public var playbackPositionMs: Int
    public var isPlayed: Bool

    public init(
        id: Episode.ID = Episode.ID(),
        podcastId: Podcast.ID,
        guid: String,
        title: String,
        summary: String? = nil,
        publishedAt: Date? = nil,
        durationMs: Int? = nil,
        imageURL: String? = nil,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        renditions: String? = nil,
        selectedRenditionID: String? = nil,
        feedTranscripts: String? = nil,
        feedChaptersURL: String? = nil,
        localPath: String? = nil,
        mediaHash: String? = nil,
        transcriptSource: String? = nil,
        processingState: String = "pending",
        notTranscribableReason: String? = nil,
        playbackPositionMs: Int = 0,
        isPlayed: Bool = false
    ) {
        self.id = id
        self.podcastId = podcastId
        self.guid = guid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.durationMs = durationMs
        self.imageURL = imageURL
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.renditions = renditions
        self.selectedRenditionID = selectedRenditionID
        self.feedTranscripts = feedTranscripts
        self.feedChaptersURL = feedChaptersURL
        self.localPath = localPath
        self.mediaHash = mediaHash
        self.transcriptSource = transcriptSource
        self.processingState = processingState
        self.notTranscribableReason = notTranscribableReason
        self.playbackPositionMs = playbackPositionMs
        self.isPlayed = isPlayed
    }
}

// MARK: - Ad patterns

public struct AdPatternRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "ad_patterns"

    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    public var id: ID
    public var sponsorId: String?
    /// Null scopes the pattern globally — which is how a sponsor learned on one
    /// show gets caught on a different one.
    public var podcastId: Podcast.ID?
    public var text: String
    public var normalizedText: String
    public var embedding: Data?
    public var confirmCount: Int
    public var falsePositiveCount: Int
    public var createdFrom: String?
    public var createdAt: Date
    public var lastMatchedAt: Date?

    public init(
        id: ID = ID(),
        sponsorId: String? = nil,
        podcastId: Podcast.ID? = nil,
        text: String,
        normalizedText: String? = nil,
        embedding: Data? = nil,
        confirmCount: Int = 0,
        falsePositiveCount: Int = 0,
        createdFrom: String? = nil,
        createdAt: Date = Date(),
        lastMatchedAt: Date? = nil
    ) {
        self.id = id
        self.sponsorId = sponsorId
        self.podcastId = podcastId
        self.text = text
        self.normalizedText = normalizedText ?? PatternNormalizer.normalize(text)
        self.embedding = embedding
        self.confirmCount = confirmCount
        self.falsePositiveCount = falsePositiveCount
        self.createdFrom = createdFrom
        self.createdAt = createdAt
        self.lastMatchedAt = lastMatchedAt
    }

    /// False-positive rate drives demotion: above 0.3 a pattern stops being
    /// auto-accepted, above 0.5 it is disabled entirely (§6.4).
    public var falsePositiveRate: Double {
        let total = confirmCount + falsePositiveCount
        guard total > 0 else { return 0 }
        return Double(falsePositiveCount) / Double(total)
    }
}

/// Normalizes pattern text before storage and matching, so trivial differences
/// in punctuation and spacing do not defeat an exact match.
public enum PatternNormalizer {
    public static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
