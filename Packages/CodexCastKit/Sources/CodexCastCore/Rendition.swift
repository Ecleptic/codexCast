import Foundation

/// One playable version of an episode: the standard `<enclosure>` or any
/// `<podcast:alternateEnclosure>` (§8.3).
///
/// Renditions of an episode are the same content, so ad timestamps are
/// identical across them. That is why detection always runs on the audio
/// rendition no matter which one the user plays, and why no video decoding
/// ever enters the detection pipeline.
public struct Rendition: Identifiable, Hashable, Sendable, Codable {
    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    /// How the media is delivered. Streaming renditions may never exist as a
    /// local file, which is fine — detection never needs them.
    public enum Delivery: String, Hashable, Sendable, Codable {
        case file
        case hls
    }

    public var id: ID
    /// Declared MIME type, verbatim from the feed. Not trustworthy on its own —
    /// see `isLikelyHLS`.
    public var mimeType: String?
    public var sources: [URL]
    public var bitrate: Int?
    public var height: Int?
    public var codecs: String?
    public var languageCode: String?
    public var title: String?
    /// `rel` groups alternatives that are substitutes for one another.
    public var relation: String?
    /// The feed's own preferred rendition (`default="true"`).
    public var isDefault: Bool
    /// From `<podcast:integrity>` where present. Absent on every feed surveyed
    /// so far, so the content-hash check in §4.1 is the primary mechanism.
    public var integrity: Integrity?
    /// True when this came from the standard `<enclosure>` rather than an
    /// alternate. Exactly one rendition per episode should have this set.
    public var isPrimaryEnclosure: Bool

    public init(
        id: ID = ID(),
        mimeType: String? = nil,
        sources: [URL] = [],
        bitrate: Int? = nil,
        height: Int? = nil,
        codecs: String? = nil,
        languageCode: String? = nil,
        title: String? = nil,
        relation: String? = nil,
        isDefault: Bool = false,
        integrity: Integrity? = nil,
        isPrimaryEnclosure: Bool = false
    ) {
        self.id = id
        self.mimeType = mimeType
        self.sources = sources
        self.bitrate = bitrate
        self.height = height
        self.codecs = codecs
        self.languageCode = languageCode
        self.title = title
        self.relation = relation
        self.isDefault = isDefault
        self.integrity = integrity
        self.isPrimaryEnclosure = isPrimaryEnclosure
    }

    public struct Integrity: Hashable, Sendable, Codable {
        public var type: String
        public var value: String

        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    /// HLS detection must not rely on the declared MIME type. The Podcasting
    /// 2.0 show's own feed ships `type="application.x-mpegURL"` — a dot where
    /// the slash belongs — so the URI extension is the more reliable signal and
    /// either one is sufficient.
    public var isLikelyHLS: Bool {
        if let mimeType {
            let normalized = mimeType.lowercased()
            if normalized.contains("mpegurl") || normalized.contains("m3u8") {
                return true
            }
        }
        return sources.contains { $0.pathExtension.lowercased() == "m3u8" }
    }

    public var delivery: Delivery {
        isLikelyHLS ? .hls : .file
    }

    /// Video is identified by MIME type or by carrying a frame height. A
    /// rendition with `height` set is video even when the type is malformed —
    /// which is how the Podcasting 2.0 feed's mistyped HLS stream is caught.
    /// HLS alone does not imply video; the namespace permits audio-only HLS.
    public var isVideo: Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("video/") { return true }
        return height != nil
    }

    public var isAudio: Bool { !isVideo }
}
