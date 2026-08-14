import CodexCastCore
import Foundation

/// XML namespaces a podcast feed may use. Matched by URI rather than by prefix,
/// because the prefix is the feed author's choice and cannot be relied upon.
enum FeedNamespace {
    static let itunes = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    static let content = "http://purl.org/rss/1.0/modules/content/"
    static let media = "http://search.yahoo.com/mrss/"

    /// Matching the Podcasting 2.0 namespace by exact URI does not work in
    /// practice. The canonical value is `https://podcastindex.org/namespace/1.0`,
    /// but `http://` appears too — and the Podcasting 2.0 show's own feed binds
    /// the prefix to a GitHub documentation URL
    /// (`https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md`).
    /// If the flagship feed for the namespace does not use the canonical URI,
    /// nothing does, so match on a distinguishing substring instead.
    ///
    /// The tokens are chosen to avoid colliding with the iTunes namespace,
    /// which also contains the word "podcast".
    static func isPodcast(_ uri: String?) -> Bool {
        guard let uri else { return false }
        let lowered = uri.lowercased()
        return lowered.contains("podcastindex") || lowered.contains("podcast-namespace")
    }

    static func isITunes(_ uri: String?) -> Bool {
        uri == itunes
    }
}

/// Parses RSS 2.0 with the iTunes and Podcasting 2.0 namespaces.
///
/// Streaming by design. The first feed this app will ever load — Tech Brew Ride
/// Home — is 12.4 MB across 2,399 items, so building a document tree is not an
/// option. `XMLParser` is fed the bytes and items are emitted as they close.
public struct FeedParser: Sendable {
    /// Most recent items to retain. Feeds are ordered newest-first by
    /// convention, so this keeps the useful end. A 2,399-item back catalogue is
    /// not worth carrying in memory to show a subscription list.
    public var maxItems: Int

    public init(maxItems: Int = 500) {
        self.maxItems = maxItems
    }

    public func parse(data: Data, feedURL: URL? = nil) throws -> ParsedFeed {
        let delegate = FeedParserDelegate(maxItems: maxItems, feedURL: feedURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate

        let succeeded = parser.parse()

        // A malformed document still yields everything parsed before the fault.
        // Losing a subscription because the last item is truncated would be a
        // worse outcome than showing a slightly short episode list (§8.2).
        if !succeeded {
            let message = parser.parserError?.localizedDescription ?? "malformed XML"
            guard !delegate.episodes.isEmpty || delegate.channelTitle != nil else {
                throw FeedParseError.unrecoverable(message)
            }
            return delegate.makeFeed(hadRecoverableError: true, errorDescription: message)
        }

        guard delegate.channelTitle != nil || !delegate.episodes.isEmpty else {
            throw FeedParseError.unrecoverable("no channel element found")
        }

        return delegate.makeFeed(hadRecoverableError: false, errorDescription: nil)
    }
}

/// The `XMLParser` delegate. A reference type by necessity — `XMLParser` is a
/// push API — and confined to a single synchronous parse, never shared.
final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private let maxItems: Int
    private let feedURL: URL?

    init(maxItems: Int, feedURL: URL?) {
        self.maxItems = maxItems
        self.feedURL = feedURL
    }

    // Channel-level state
    private(set) var channelTitle: String?
    private var channelAuthor: String?
    private var channelSummary: String?
    private var channelImageURL: URL?
    private var channelLink: URL?
    private var channelLanguage: String?
    private var channelExplicit = false
    private var channelCategories: [String] = []

    private(set) var episodes: [ParsedEpisode] = []

    // Item-level state, reset on each `<item>`.
    private var inItem = false
    private var itemGUID: String?
    private var itemTitle: String?
    private var itemSummary: String?
    private var itemContentEncoded: String?
    private var itemPubDate: String?
    private var itemDuration: String?
    private var itemImageURL: URL?
    private var itemEpisodeNumber: Int?
    private var itemSeasonNumber: Int?
    private var itemRenditions: [Rendition] = []
    private var itemTranscripts: [FeedTranscriptReference] = []
    private var itemChaptersURL: URL?

    /// `<podcast:alternateEnclosure>` wraps one or more `<podcast:source>`
    /// children, so the enclosure under construction is held here until it
    /// closes.
    private var pendingAlternate: Rendition?
    private var pendingAlternateSources: [URL] = []

    private var textBuffer = ""
    /// Set while inside `<image>` so a nested `<url>` is not mistaken for the
    /// channel link.
    private var imageDepth = 0

    func makeFeed(hadRecoverableError: Bool, errorDescription: String?) -> ParsedFeed {
        ParsedFeed(
            title: channelTitle ?? feedURL?.host ?? "Untitled Podcast",
            author: channelAuthor,
            summary: channelSummary,
            imageURL: channelImageURL,
            link: channelLink,
            languageCode: channelLanguage,
            isExplicit: channelExplicit,
            categories: channelCategories,
            episodes: episodes,
            hadRecoverableError: hadRecoverableError,
            recoveredErrorDescription: errorDescription
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        textBuffer = ""

        if FeedNamespace.isPodcast(namespaceURI) {
            startPodcastElement(elementName, attributes: attributes)
            return
        }

        if FeedNamespace.isITunes(namespaceURI) {
            startITunesElement(elementName, attributes: attributes)
            return
        }

        switch elementName {
        case "item":
            beginItem()
        case "image":
            imageDepth += 1
        case "enclosure":
            guard inItem else { break }
            if let url = attributes["url"].flatMap(sanitizedURL) {
                itemRenditions.append(
                    Rendition(
                        mimeType: attributes["type"],
                        sources: [url],
                        isPrimaryEnclosure: true
                    )
                )
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""

        if FeedNamespace.isPodcast(namespaceURI) {
            endPodcastElement(elementName)
            return
        }

        if FeedNamespace.isITunes(namespaceURI) {
            endITunesElement(elementName, text: text)
            return
        }

        if namespaceURI == FeedNamespace.content, elementName == "encoded", inItem {
            itemContentEncoded = text
            return
        }

        switch elementName {
        case "item":
            endItem()
        case "image":
            imageDepth = max(0, imageDepth - 1)
        case "title":
            if inItem {
                itemTitle = text
            } else if channelTitle == nil, imageDepth == 0 {
                channelTitle = text
            }
        case "description":
            if inItem {
                if itemSummary == nil { itemSummary = text }
            } else if channelSummary == nil {
                channelSummary = text
            }
        case "guid":
            if inItem { itemGUID = text }
        case "pubDate":
            if inItem { itemPubDate = text }
        case "link":
            if !inItem, imageDepth == 0, channelLink == nil {
                channelLink = sanitizedURL(text)
            }
        case "url":
            // Only meaningful inside <image>; elsewhere it belongs to a
            // namespace we handle separately.
            if imageDepth > 0, !inItem, channelImageURL == nil {
                channelImageURL = sanitizedURL(text)
            }
        case "language":
            if !inItem, channelLanguage == nil { channelLanguage = text }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        textBuffer += string
    }

    // MARK: - Podcasting 2.0

    private func startPodcastElement(_ name: String, attributes: [String: String]) {
        switch name {
        case "transcript":
            guard inItem, let url = attributes["url"].flatMap(sanitizedURL) else { break }
            guard let format = FeedTranscriptReference.Format(
                mimeType: attributes["type"] ?? "",
                url: url
            ) else { break }
            itemTranscripts.append(
                FeedTranscriptReference(
                    url: url,
                    format: format,
                    languageCode: attributes["language"],
                    relation: attributes["rel"]
                )
            )

        case "chapters":
            guard inItem, let url = attributes["url"].flatMap(sanitizedURL) else { break }
            itemChaptersURL = url

        case "alternateEnclosure":
            guard inItem else { break }
            pendingAlternateSources = []
            pendingAlternate = Rendition(
                mimeType: attributes["type"],
                bitrate: attributes["bitrate"].flatMap { Int(Double($0) ?? 0) },
                height: attributes["height"].flatMap { Int($0) },
                codecs: attributes["codecs"],
                languageCode: attributes["lang"],
                title: attributes["title"],
                relation: attributes["rel"],
                isDefault: attributes["default"] == "true"
            )

        case "source":
            guard pendingAlternate != nil, let uri = attributes["uri"].flatMap(sanitizedURL) else { break }
            pendingAlternateSources.append(uri)

        case "integrity":
            guard pendingAlternate != nil,
                  let type = attributes["type"],
                  let value = attributes["value"]
            else { break }
            pendingAlternate?.integrity = .init(type: type, value: value)

        default:
            break
        }
    }

    private func endPodcastElement(_ name: String) {
        guard name == "alternateEnclosure", var alternate = pendingAlternate else { return }
        alternate.sources = pendingAlternateSources
        // An alternate with no source is unplayable; drop it rather than carry
        // an empty rendition into selection.
        if !alternate.sources.isEmpty {
            itemRenditions.append(alternate)
        }
        pendingAlternate = nil
        pendingAlternateSources = []
    }

    // MARK: - iTunes namespace

    private func startITunesElement(_ name: String, attributes: [String: String]) {
        guard name == "image", let url = attributes["href"].flatMap(sanitizedURL) else { return }
        if inItem {
            itemImageURL = url
        } else if channelImageURL == nil {
            channelImageURL = url
        }
    }

    private func endITunesElement(_ name: String, text: String) {
        switch name {
        case "author":
            if !inItem, channelAuthor == nil { channelAuthor = text }
        case "summary":
            if inItem {
                if itemSummary == nil { itemSummary = text }
            } else if channelSummary == nil {
                channelSummary = text
            }
        case "duration":
            if inItem { itemDuration = text }
        case "episode":
            if inItem { itemEpisodeNumber = Int(text) }
        case "season":
            if inItem { itemSeasonNumber = Int(text) }
        case "explicit":
            if !inItem { channelExplicit = (text == "yes" || text == "true") }
        default:
            break
        }
    }

    // MARK: - Item lifecycle

    private func beginItem() {
        inItem = true
        itemGUID = nil
        itemTitle = nil
        itemSummary = nil
        itemContentEncoded = nil
        itemPubDate = nil
        itemDuration = nil
        itemImageURL = nil
        itemEpisodeNumber = nil
        itemSeasonNumber = nil
        itemRenditions = []
        itemTranscripts = []
        itemChaptersURL = nil
        pendingAlternate = nil
        pendingAlternateSources = []
    }

    private func endItem() {
        defer { inItem = false }

        guard episodes.count < maxItems else { return }

        // No enclosure and no alternate means nothing to play. Skip rather than
        // create an episode row that can never be listened to.
        guard !itemRenditions.isEmpty else { return }

        // A missing <guid> is common. Falling back to the enclosure URL keeps
        // episodes stable across refreshes; without it they duplicate every time.
        let guid = itemGUID?.nilIfEmpty
            ?? itemRenditions.first?.sources.first?.absoluteString
            ?? UUID().uuidString

        episodes.append(
            ParsedEpisode(
                guid: guid,
                title: itemTitle?.nilIfEmpty ?? "Untitled Episode",
                summary: itemSummary?.nilIfEmpty ?? itemContentEncoded?.nilIfEmpty,
                publishedAt: itemPubDate.flatMap(RFC822DateParser.date(from:)),
                declaredDurationMs: itemDuration.flatMap(DurationParser.milliseconds(from:)),
                imageURL: itemImageURL,
                episodeNumber: itemEpisodeNumber,
                seasonNumber: itemSeasonNumber,
                renditions: itemRenditions,
                transcripts: itemTranscripts,
                chaptersURL: itemChaptersURL
            )
        )
    }
}

// MARK: - Helpers

/// Feeds contain URLs with stray whitespace and unescaped characters often
/// enough that `URL(string:)` alone loses real episodes.
func sanitizedURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed) { return url }
    guard let encoded = trimmed.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)
    ) else { return nil }
    return URL(string: encoded)
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
