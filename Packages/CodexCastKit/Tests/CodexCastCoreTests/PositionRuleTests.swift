import Foundation
import Testing

@testable import CodexCastCore

@Suite("Position rules — §5.1/§6.3")
struct PositionRuleTests {
    private let show = Podcast.ID()

    @Test("Welford tracks mean and variance without keeping samples")
    func welford() {
        var rule = PositionRule(podcastID: show, anchor: .fromStart(offsetMs: 0))
        for duration in [60_000, 62_000, 58_000, 61_000, 59_000] {
            rule.recordHit(durationMs: duration)
        }
        #expect(abs(rule.meanDurationMs - 60_000) < 1)
        #expect(rule.sampleCount == 5)
        // Sample variance of that series is 2.5e6.
        #expect(abs(rule.varianceMs - 2_500_000) < 1_000)
    }

    @Test("A machine rule below 50% reliability with 6 outcomes disables itself")
    func autoDisable() {
        var rule = PositionRule(podcastID: show, anchor: .fromStart(offsetMs: 0))
        rule.recordHit(durationMs: 60_000)
        for _ in 0..<4 { rule.recordMiss() }
        #expect(rule.enabled)
        rule.recordMiss()
        #expect(!rule.enabled)
    }

    @Test("A user rule never disables, no matter how often it misses")
    func userRulesHold() {
        var rule = PositionRule(podcastID: show, anchor: .fromStart(offsetMs: 0), userCreated: true)
        for _ in 0..<20 { rule.recordMiss() }
        #expect(rule.enabled)
    }

    @Test("Proposals land where the anchor says, at the learned duration")
    func proposals() throws {
        var preRoll = PositionRule(podcastID: show, anchor: .fromStart(offsetMs: 0))
        preRoll.recordHit(durationMs: 90_000)
        let pre = try #require(preRoll.propose(episodeDurationMs: 3_600_000))
        #expect(pre.startMs == 0 && pre.endMs == 90_000)

        var postRoll = PositionRule(podcastID: show, anchor: .fromEnd(offsetMs: 0))
        postRoll.recordHit(durationMs: 60_000)
        let post = try #require(postRoll.propose(episodeDurationMs: 3_600_000))
        #expect(post.startMs == 3_540_000 && post.endMs == 3_600_000)

        var mid = PositionRule(podcastID: show, anchor: .proportional(fraction: 0.5))
        mid.recordHit(durationMs: 120_000)
        let midway = try #require(mid.propose(episodeDurationMs: 3_600_000))
        #expect(midway.startMs == 1_740_000 && midway.endMs == 1_860_000)

        // afterMarker without a resolved marker proposes nothing.
        let marker = PositionRule(podcastID: show, anchor: .afterMarker(text: "right back"))
        #expect(marker.propose(episodeDurationMs: 3_600_000) == nil)
        let resolved = marker.propose(episodeDurationMs: 3_600_000, markerMs: 1_000_000)
        #expect(resolved?.startMs == 1_000_000)
    }

    @Test("Anchor classification buckets nearby segments onto one rule")
    func anchorClassification() {
        let hour = 3_600_000
        #expect(PositionRule.anchor(forSegmentStartMs: 5_000, endMs: 65_000, episodeDurationMs: hour)
            == .fromStart(offsetMs: 0))
        #expect(PositionRule.anchor(forSegmentStartMs: 20_000, endMs: 80_000, episodeDurationMs: hour)
            == .fromStart(offsetMs: 0))
        #expect(PositionRule.anchor(forSegmentStartMs: hour - 70_000, endMs: hour - 10_000, episodeDurationMs: hour)
            == .fromEnd(offsetMs: 0))
        #expect(PositionRule.anchor(forSegmentStartMs: 1_800_000, endMs: 1_890_000, episodeDurationMs: hour)
            == .proportional(fraction: 0.5))
    }

    @Test("Anchors and rules survive JSON round-trips")
    func codableRoundTrip() throws {
        var rule = PositionRule(podcastID: show, anchor: .afterMarker(text: "we'll be right back"))
        rule.recordHit(durationMs: 45_000)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PositionRule.self, from: data)
        #expect(decoded == rule)
    }
}
