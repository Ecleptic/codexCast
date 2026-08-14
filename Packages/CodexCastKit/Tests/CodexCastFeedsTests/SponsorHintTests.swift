import Foundation
import Testing

@testable import CodexCastFeeds

@Suite("Sponsor hints from show notes")
struct SponsorHintTests {
    /// ATP's real format, verbatim from the feed. Sponsor names *and* a promo
    /// code, available before any audio is touched.
    @Test("ATP's sponsor block yields names, offers, and the promo code")
    func atpFormat() {
        let description = """
        <p>Post-show: John's macOS update woes</p>
        <p>Sponsored by:</p>
        <ul>
        <li><a href="https://factormeals.com/atp50off">Factor</a>: Healthy Eating, \
        Made Easy. Use code <strong>atp50off</strong>.</li>
        <li><a href="https://claude.ai">Claude</a>: Ready to tackle bigger problems? \
        Get started with Claude today.</li>
        <li><a href="https://quince.com">Quince</a>: Elevated essentials and staples that last.</li>
        </ul>
        <p><a href="https://atp.fm/join">Become a member</a> for ATP Overtime, ad-free episodes.</p>
        """

        let hints = SponsorHintExtractor.extract(from: description)

        #expect(hints.map(\.name) == ["Factor", "Claude", "Quince"])
        #expect(hints.first?.offer?.contains("Healthy Eating") == true)
        // The promo code belongs to Factor, and is the strongest anchor of all:
        // "atp50off" in a transcript is not a coincidence.
        #expect(hints.first?.promoCodes == ["atp50off"])
        // "Become a member" is boilerplate, not a sponsor.
        #expect(!hints.contains { $0.name.lowercased().contains("member") })
    }

    @Test("A prose 'brought to you by' names its sponsors")
    func proseFormat() {
        let description = """
        <p>This episode is brought to you by Squarespace and Backblaze.</p>
        <p>Show notes follow.</p>
        """

        let hints = SponsorHintExtractor.extract(from: description)

        #expect(Set(hints.map(\.name)) == ["Squarespace", "Backblaze"])
    }

    @Test("The Changelog's 'Sponsors:' list parses")
    func changelogFormat() {
        let description = """
        <p><strong>Sponsors:</strong></p>
        <p><a href="https://fly.io">Fly.io</a> – The home of Changelog.com. \
        Deploy your apps close to your users.</p>
        <p><a href="https://sentry.io">Sentry</a> – Code breaks, fix it faster. \
        Use code <strong>changelog</strong> for 2 months free.</p>
        """

        let hints = SponsorHintExtractor.extract(from: description)

        #expect(hints.map(\.name) == ["Fly.io", "Sentry"])
        #expect(hints.last?.promoCodes == ["changelog"])
    }

    /// The trap the whole design worries about: a show *discussing*
    /// advertising must not be mined as though it had sponsors.
    @Test("A description merely discussing ads yields nothing")
    func noFalsePositivesOnDiscussion() {
        let description = """
        <p>This week we talk about how podcast advertising works, why dynamic \
        ad insertion is controversial, and whether listeners actually mind \
        being sponsored content.</p>
        """

        #expect(SponsorHintExtractor.extract(from: description).isEmpty)
    }

    @Test("A description with no sponsor section yields nothing")
    func noSponsorSection() {
        #expect(SponsorHintExtractor.extract(from: "<p>Just some show notes.</p>").isEmpty)
        #expect(SponsorHintExtractor.extract(from: "").isEmpty)
    }

    @Test("Boilerplate and links are rejected as sponsor names")
    func rejectsBoilerplate() {
        #expect(!SponsorHintExtractor.isPlausibleSponsorName("Become a member"))
        #expect(!SponsorHintExtractor.isPlausibleSponsorName("https://example.com"))
        #expect(!SponsorHintExtractor.isPlausibleSponsorName(""))
        #expect(!SponsorHintExtractor.isPlausibleSponsorName(
            "a very long sentence that is clearly prose and not a brand name at all"
        ))
        #expect(SponsorHintExtractor.isPlausibleSponsorName("Squarespace"))
        #expect(SponsorHintExtractor.isPlausibleSponsorName("Fly.io"))
    }

    @Test("HTML entities and tags are handled without losing list structure")
    func htmlHandling() {
        let normalized = SponsorHintExtractor.normalize(
            "<p>A &amp; B</p><li>Item one</li><li>Item two</li>"
        )

        #expect(normalized.contains("A & B"))
        // List items must stay on separate lines or every sponsor merges into one.
        #expect(normalized.contains("Item one\n"))
    }
}

@Suite("Sponsor hints — shapes found in Cam's real subscriptions")
struct RealSponsorShapeTests {
    /// CodePen Radio: the brand sits alone in a heading after "Sponsor:".
    @Test("A single sponsor named in a heading is extracted")
    func codePenShape() {
        let description = """
        <h2>Sponsor: <a href="https://notion.com/codepen">Notion</a></h2>
        <p>With the recent launch of Custom Agents, <a href="https://notion.com/codepen">Notion</a> \
        became the collaborative AI workspace where teams and agents work side by side.</p>
        """

        let hints = SponsorHintExtractor.extract(from: description)

        #expect(hints.map(\.name) == ["Notion"])
    }

    /// Waveform: "Name: URL", one per line.
    @Test("Sponsors listed as name-and-URL pairs are extracted")
    func waveformShape() {
        let description = """
        This episode is brought to you by:<br><br>
        Framer: https://www.framer.com/waveform<br><br>
        Quince: https://www.quince.com/waveform<br><br>
        Glaze: https://www.glaze.app/waveform<br><br>
        Follow us on socials:<br>
        Marques: https://www.threads.net/@mkbhd
        """

        let hints = SponsorHintExtractor.extract(from: description)

        #expect(hints.map(\.name).prefix(3) == ["Framer", "Quince", "Glaze"])
    }
}
