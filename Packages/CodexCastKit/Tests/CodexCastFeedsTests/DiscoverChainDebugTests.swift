import Foundation
import Testing

@testable import CodexCastFeeds

/// Live integration check of the exact Discover → Follow chain, for
/// diagnosing the field report "hitting follow doesn't do anything".
@Suite struct DiscoverChainDebugTests {
    @Test func followChainEndToEnd() async throws {
        let charts = TopChartsClient()
        let entries = try await charts.topPodcasts(limit: 3)
        print("CHART-ENTRIES: \(entries.count)")
        #expect(!entries.isEmpty)

        guard let first = entries.first else { return }
        print("CHART-FIRST: \(first.id) \(first.name)")

        let feedURL = try await charts.feedURL(for: first)
        print("LOOKUP-FEED-URL: \(feedURL?.absoluteString ?? "NIL")")
        #expect(feedURL != nil)

        guard let feedURL else { return }
        let fetcher = FeedFetcher()
        let result = try await fetcher.fetch(feedURL)
        switch result {
        case .updated(let feed, _):
            print("FETCH-OK: \(feed.title) episodes=\(feed.episodes.count)")
            #expect(!feed.episodes.isEmpty)
        case .notModified:
            print("FETCH-NOT-MODIFIED (unexpected on first fetch)")
            Issue.record("First fetch returned notModified")
        }
    }
}
