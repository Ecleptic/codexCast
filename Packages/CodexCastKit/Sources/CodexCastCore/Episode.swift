import Foundation

public struct Podcast: Identifiable, Hashable, Sendable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    public var id: ID
    public var feedURL: URL
    public var itunesCollectionID: Int?
    public var title: String
    public var author: String?
    public var summary: String?
    public var imageURL: URL?
    public var addedAt: Date
    /// Free text injected into Stage 2 instructions (§6.5). Capped, because
    /// under a tight context window it is not free.
    public var notes: String?

    public static let notesCharacterLimit = 300

    public init(
        id: ID = ID(),
        feedURL: URL,
        itunesCollectionID: Int? = nil,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        imageURL: URL? = nil,
        addedAt: Date = Date(),
        notes: String? = nil
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
    }
}

public struct Episode: Identifiable, Hashable, Sendable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    /// Why an episode will never be transcribed (§9.8). Music shows, non-English
    /// audio, and corrupt files must not retry forever.
    public enum NotTranscribableReason: String, Hashable, Sendable, Codable {
        case repeatedFailure
        case lowWordDensity
        case unsupportedLanguage
    }

    public var id: ID
    public var podcastID: Podcast.ID
    /// The feed's `<guid>`, which is how an episode is matched across refreshes.
    public var guid: String
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    /// Duration as declared by the feed. Frequently wrong; true duration comes
    /// from the media once downloaded.
    public var declaredDurationMs: Int?
    public var renditions: [Rendition]
    public var selectedRenditionID: Rendition.ID?
    /// Transcript URLs advertised by the feed, best format first.
    public var feedTranscripts: [FeedTranscriptReference]
    public var feedChaptersURL: URL?
    public var localPath: String?
    /// Content hash of the downloaded media. Dynamic ad insertion means a
    /// re-download may legitimately differ; when the hash changes, this
    /// episode's segments are invalidated and detection requeued (§4.1).
    public var mediaHash: String?
    public var notTranscribableReason: NotTranscribableReason?

    public init(
        id: ID = ID(),
        podcastID: Podcast.ID,
        guid: String,
        title: String,
        summary: String? = nil,
        publishedAt: Date? = nil,
        declaredDurationMs: Int? = nil,
        renditions: [Rendition] = [],
        selectedRenditionID: Rendition.ID? = nil,
        feedTranscripts: [FeedTranscriptReference] = [],
        feedChaptersURL: URL? = nil,
        localPath: String? = nil,
        mediaHash: String? = nil,
        notTranscribableReason: NotTranscribableReason? = nil
    ) {
        self.id = id
        self.podcastID = podcastID
        self.guid = guid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.declaredDurationMs = declaredDurationMs
        self.renditions = renditions
        self.selectedRenditionID = selectedRenditionID
        self.feedTranscripts = feedTranscripts
        self.feedChaptersURL = feedChaptersURL
        self.localPath = localPath
        self.mediaHash = mediaHash
        self.notTranscribableReason = notTranscribableReason
    }

    /// The rendition detection consumes. Always audio, regardless of what the
    /// user plays — renditions are the same content, so timestamps are
    /// identical across them and no video decoding is ever required (§8.3).
    /// Prefers the smallest audio file, since it is downloaded purely to be
    /// transcribed.
    public var analysisRendition: Rendition? {
        let audio = renditions.filter { $0.isAudio && $0.delivery == .file }
        guard !audio.isEmpty else { return nil }
        if let smallest = audio.filter({ $0.bitrate != nil }).min(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return smallest
        }
        return audio.first { $0.isPrimaryEnclosure } ?? audio.first
    }
}

/// A `<podcast:transcript>` advertised by the feed.
public struct FeedTranscriptReference: Hashable, Sendable, Codable {
    /// Parse order preference. A feed may advertise several formats for the
    /// same episode — LINUX Unplugged ships VTT and SRT side by side.
    public enum Format: String, Hashable, Sendable, Codable, CaseIterable {
        case vtt
        case srt
        case json

        /// Lower sorts first. VTT wins because it carries speaker voice spans
        /// that SRT drops.
        public var preferenceRank: Int {
            switch self {
            case .vtt: 0
            case .json: 1
            case .srt: 2
            }
        }

        /// Feeds declare these inconsistently: `text/vtt`, `application/srt`,
        /// and `application/x-subrip` all appear in the wild for two formats.
        public init?(mimeType: String, url: URL? = nil) {
            switch mimeType.lowercased() {
            case let type where type.contains("vtt"):
                self = .vtt
            case let type where type.contains("srt") || type.contains("subrip"):
                self = .srt
            case let type where type.contains("json"):
                self = .json
            default:
                switch url?.pathExtension.lowercased() {
                case "vtt": self = .vtt
                case "srt": self = .srt
                case "json": self = .json
                default: return nil
                }
            }
        }
    }

    public var url: URL
    public var format: Format
    public var languageCode: String?
    public var relation: String?

    public init(url: URL, format: Format, languageCode: String? = nil, relation: String? = nil) {
        self.url = url
        self.format = format
        self.languageCode = languageCode
        self.relation = relation
    }
}

extension Array where Element == FeedTranscriptReference {
    /// Best transcript to fetch, preferring format richness.
    public var preferred: FeedTranscriptReference? {
        min { $0.format.preferenceRank < $1.format.preferenceRank }
    }
}
