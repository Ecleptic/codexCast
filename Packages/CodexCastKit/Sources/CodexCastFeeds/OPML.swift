import Foundation

public struct OPMLEntry: Hashable, Sendable {
    public var title: String
    public var feedURL: URL

    public init(title: String, feedURL: URL) {
        self.title = title
        self.feedURL = feedURL
    }
}

/// OPML import and export — the migration path in and out of every other
/// podcast app, and non-negotiable for that reason (§8.1).
public enum OPML {
    public static func parse(_ data: Data) throws -> [OPMLEntry] {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate

        let succeeded = parser.parse()

        // Partial recovery matters here too: a truncated export should still
        // import the subscriptions it did contain.
        guard succeeded || !delegate.entries.isEmpty else {
            throw OPMLError.malformed(parser.parserError?.localizedDescription ?? "malformed OPML")
        }
        guard !delegate.entries.isEmpty else {
            throw OPMLError.noSubscriptions
        }
        return delegate.entries
    }

    public static func export(_ entries: [OPMLEntry], title: String = "Codex Cast Subscriptions") -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>\(escape(title))</title>
          </head>
          <body>

        """

        for entry in entries {
            let escapedTitle = escape(entry.title)
            let escapedURL = escape(entry.feedURL.absoluteString)
            xml += """
                <outline type="rss" text="\(escapedTitle)" title="\(escapedTitle)" xmlUrl="\(escapedURL)"/>

            """
        }

        xml += """
          </body>
        </opml>

        """
        return xml
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

public enum OPMLError: Error, Sendable, Equatable {
    case malformed(String)
    case noSubscriptions
}

final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [OPMLEntry] = []
    private var seenURLs: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        // Outlines nest into folders, and folder outlines carry no xmlUrl.
        // Ignoring them flattens the hierarchy, which is the right outcome:
        // Codex Cast has no folder concept to import into.
        guard let raw = attributes["xmlUrl"] ?? attributes["xmlurl"],
              let url = sanitizedURL(raw)
        else { return }

        // Exports from apps with folders frequently list the same feed twice.
        guard seenURLs.insert(url.absoluteString).inserted else { return }

        let title = attributes["title"]?.nilIfEmpty
            ?? attributes["text"]?.nilIfEmpty
            ?? url.host
            ?? "Untitled"

        entries.append(OPMLEntry(title: title, feedURL: url))
    }
}
