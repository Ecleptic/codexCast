import Foundation
import Testing

@testable import CodexCastFeeds

@Suite("YouTube → Podsync")
struct YouTubeLinkTests {
    private let server = URL(string: "https://podsync.example.com")!

    @Test("Every shape of YouTube link a share sheet produces")
    func parsing() {
        func target(_ string: String) -> YouTubeLink.Target? {
            YouTubeLink.target(for: URL(string: string)!)
        }
        #expect(target("https://www.youtube.com/@jason-schreier") == .name("@jason-schreier"))
        #expect(target("https://youtube.com/@RetroGameCorps?si=abc") == .name("@RetroGameCorps"))
        #expect(target("https://www.youtube.com/channel/UCQoOmu6mKZkXTnwZcpD8Ciw")
            == .channel("UCQoOmu6mKZkXTnwZcpD8Ciw"))
        #expect(target("https://www.youtube.com/c/LinusTechTips") == .name("LinusTechTips"))
        #expect(target("https://www.youtube.com/user/marquesbrownlee") == .name("marquesbrownlee"))
        #expect(target("https://www.youtube.com/playlist?list=PLiZwoK8DQiwx")
            == .playlist("PLiZwoK8DQiwx"))
        // Sharing a video that's part of a playlist means the playlist.
        #expect(target("https://www.youtube.com/watch?v=abc&list=PLxyz") == .playlist("PLxyz"))
        #expect(target("https://example.com/@someone") == nil)
    }

    @Test("Feed URLs match the shapes Podsync serves")
    func feedURLs() {
        #expect(
            YouTubeLink.podsyncFeedURL(for: .channel("UCabc"), server: server)?.absoluteString
                == "https://podsync.example.com/channel/UCabc"
        )
        #expect(
            YouTubeLink.podsyncFeedURL(for: .playlist("PLabc"), server: server)?.absoluteString
                == "https://podsync.example.com/rss/PLabc"
        )
        #expect(YouTubeLink.podsyncFeedURL(for: .name("@x"), server: server) == nil)
    }

    @Test("The channel ID is found even late in a huge page")
    func extraction() {
        // The real failure: the ID sits past the first megabyte.
        let filler = String(repeating: "x", count: 1_200_000)
        let html = filler + #"{"channelId":"UCQoOmu6mKZkXTnwZcpD8Ciw"}"#
        #expect(YouTubeLink.extractChannelID(from: html) == "UCQoOmu6mKZkXTnwZcpD8Ciw")
        #expect(YouTubeLink.extractChannelID(from: "no ids here") == nil)
    }
}
