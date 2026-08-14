import Foundation
import Testing

@testable import CodexCastFeeds

/// Exercises the OPML parser against a real export from another podcast app.
///
/// The file is a personal drop containing private feed URLs with embedded
/// credentials, so it is gitignored and never committed. These tests enable
/// themselves only when it is present.
enum PersonalOPML {
    static var url: URL? {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // strip the file name
            .deletingLastPathComponent()   // CodexCastFeedsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CodexCastKit
            .deletingLastPathComponent()   // Packages
            .appendingPathComponent("Spike/tempUserDrop/Overcast Podcast Subscriptions.opml")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

@Suite("Real-world OPML", .enabled(if: PersonalOPML.url != nil))
struct RealOPMLTests {
    private func load() throws -> [OPMLEntry] {
        let url = try #require(PersonalOPML.url)
        return try OPML.parse(try Data(contentsOf: url))
    }

    @Test("A real Overcast export parses in full")
    func parsesRealExport() throws {
        let entries = try load()

        // Overcast nests every subscription under a single "feeds" folder
        // outline, which carries no xmlUrl — flattening must not lose them.
        #expect(entries.count > 50)
        #expect(entries.allSatisfy { !$0.title.isEmpty })
        #expect(entries.allSatisfy { $0.feedURL.scheme?.hasPrefix("http") == true })
    }

    /// XML entities in titles are where naive parsers produce "Dan Carlin&apos;s".
    @Test("Escaped entities in titles are decoded, not left raw")
    func decodesEntities() throws {
        let entries = try load()

        #expect(!entries.contains { $0.title.contains("&apos;") })
        #expect(!entries.contains { $0.title.contains("&amp;") })
        // The export genuinely contains both apostrophes and ampersands.
        #expect(entries.contains { $0.title.contains("'") })
        #expect(entries.contains { $0.title.contains("&") })
    }

    /// Private feeds carry credentials in the URL. Losing them silently turns
    /// a paid subscription into a 401 with no explanation.
    @Test("Feed URLs carrying credentials survive parsing intact")
    func preservesCredentials() throws {
        let entries = try load()

        let credentialed = entries.filter {
            $0.feedURL.user != nil || ($0.feedURL.query?.contains("auth") ?? false)
        }
        #expect(!credentialed.isEmpty, "expected at least one private feed in this export")

        for entry in credentialed {
            if entry.feedURL.user != nil {
                #expect(entry.feedURL.password != nil, "password dropped from \(entry.title)")
            }
        }
    }

    @Test("A real export round-trips through export and import unchanged")
    func roundTrips() throws {
        let entries = try load()

        let exported = OPML.export(entries)
        let reimported = try OPML.parse(Data(exported.utf8))

        #expect(reimported == entries)
    }

    /// Overcast exports list some shows twice (e.g. archive feeds under one
    /// name). Deduplication is by URL, so genuinely distinct feeds sharing a
    /// title must all survive.
    @Test("Distinct feeds sharing a title are all kept")
    func keepsDistinctFeedsWithSharedTitles() throws {
        let entries = try load()

        let urls = Set(entries.map(\.feedURL.absoluteString))
        #expect(urls.count == entries.count, "deduplication collapsed distinct feeds")
    }
}
