import Foundation
import Testing

@testable import CodexCastCore

@Suite("Renditions")
struct RenditionTests {
    /// The Podcasting 2.0 show's own feed declares its HLS stream as
    /// `application.x-mpegURL` — a dot where the slash belongs. Detection must
    /// survive that, because it is real data from the flagship P2.0 feed.
    @Test("HLS is detected despite a malformed MIME type")
    func malformedHLSMimeType() {
        let rendition = Rendition(
            mimeType: "application.x-mpegURL",
            sources: [URL(string: "https://hls.podcastindex.org/pc20_236.m3u8")!],
            height: 720
        )

        #expect(rendition.isLikelyHLS)
        #expect(rendition.delivery == .hls)
        #expect(rendition.isVideo)
    }

    @Test("HLS is detected from the URI when no MIME type is given at all")
    func hlsFromURIAlone() {
        let rendition = Rendition(
            mimeType: nil,
            sources: [URL(string: "https://example.com/stream.m3u8")!]
        )

        #expect(rendition.isLikelyHLS)
    }

    /// The namespace permits audio-only HLS, so streaming must not imply video.
    @Test("Audio-only HLS is not treated as video")
    func audioOnlyHLSIsNotVideo() {
        let rendition = Rendition(
            mimeType: "application/x-mpegURL",
            sources: [URL(string: "https://example.com/audio.m3u8")!]
        )

        #expect(rendition.isLikelyHLS)
        #expect(!rendition.isVideo)
        #expect(rendition.isAudio)
    }

    @Test("A rendition with a frame height is video even with a junk MIME type")
    func heightImpliesVideo() {
        let rendition = Rendition(mimeType: "application/octet-stream", height: 1080)
        #expect(rendition.isVideo)
    }
}

@Suite("Analysis rendition selection")
struct AnalysisRenditionTests {
    /// Detection always runs on audio, and the audio file is downloaded purely
    /// to be transcribed — so the cheapest one wins. Modelled on Podnews Daily,
    /// which ships 12k Opus, 32k AAC, and a 128k MP3 marked default.
    @Test("Picks the smallest audio rendition, not the feed's default")
    func prefersSmallestAudio() {
        let podcastID = Podcast.ID()
        let episode = Episode(
            podcastID: podcastID,
            guid: "guid",
            title: "Episode",
            renditions: [
                Rendition(mimeType: "audio/mpeg", bitrate: 128_000, isDefault: true, isPrimaryEnclosure: true),
                Rendition(mimeType: "audio/aac", bitrate: 32_000),
                Rendition(mimeType: "audio/opus", bitrate: 12_000),
                Rendition(mimeType: "video/mp4", bitrate: 2_190_000, height: 1080),
            ]
        )

        #expect(episode.analysisRendition?.bitrate == 12_000)
    }

    /// A video podcast with no separate audio rendition has nothing to select;
    /// the caller must extract the audio track from the video instead (§8.3).
    @Test("Returns nil when only video renditions exist")
    func videoOnlyHasNoAnalysisRendition() {
        let episode = Episode(
            podcastID: Podcast.ID(),
            guid: "guid",
            title: "Episode",
            renditions: [Rendition(mimeType: "video/mp4", height: 1080)]
        )

        #expect(episode.analysisRendition == nil)
    }

    @Test("Streaming audio is not selected for analysis — there is no file to read")
    func skipsStreamingRenditions() {
        let episode = Episode(
            podcastID: Podcast.ID(),
            guid: "guid",
            title: "Episode",
            renditions: [
                Rendition(
                    mimeType: "application/x-mpegURL",
                    sources: [URL(string: "https://example.com/a.m3u8")!],
                    bitrate: 1_000
                ),
                Rendition(mimeType: "audio/mpeg", bitrate: 128_000, isPrimaryEnclosure: true),
            ]
        )

        #expect(episode.analysisRendition?.bitrate == 128_000)
    }
}

@Suite("Chapters")
struct ChapterTests {
    /// LINUX Unplugged episode 679 returns its chapters effectively reversed:
    /// `startTime: 0` titled "Outro" through `startTime: 3374` titled "Intro".
    /// Sort by time and never read meaning into the titles.
    @Test("Unordered chapter files are sorted by start time")
    func chaptersSortByStartTime() {
        let chapters = [
            Chapter(startMs: 0, title: "Outro", source: .feed),
            Chapter(startMs: 149_000, title: "Picks", source: .feed),
            Chapter(startMs: 3_374_000, title: "Intro", source: .feed),
            Chapter(startMs: 674_000, title: "Shout-Outs", source: .feed),
        ]

        let sorted = chapters.sortedByStart()

        #expect(sorted.map(\.startMs) == [0, 149_000, 674_000, 3_374_000])
        #expect(sorted.first?.title == "Outro")
    }
}

@Suite("Feed transcript selection")
struct FeedTranscriptTests {
    /// LINUX Unplugged advertises VTT and SRT for the same episode. VTT wins:
    /// it carries speaker voice spans that SRT discards.
    @Test("VTT is preferred over SRT for the same episode")
    func prefersVTT() {
        let references = [
            FeedTranscriptReference(url: URL(string: "https://example.com/a.srt")!, format: .srt),
            FeedTranscriptReference(url: URL(string: "https://example.com/a.vtt")!, format: .vtt),
        ]

        #expect(references.preferred?.format == .vtt)
    }

    @Test(
        "Formats are recognized across the inconsistent MIME types feeds actually use",
        arguments: [
            ("text/vtt", FeedTranscriptReference.Format.vtt),
            ("application/srt", .srt),
            ("application/x-subrip", .srt),
            ("application/json", .json),
        ]
    )
    func recognizesRealWorldMimeTypes(mimeType: String, expected: FeedTranscriptReference.Format) {
        #expect(FeedTranscriptReference.Format(mimeType: mimeType) == expected)
    }

    @Test("Falls back to the file extension when the MIME type is unhelpful")
    func fallsBackToExtension() {
        let format = FeedTranscriptReference.Format(
            mimeType: "application/octet-stream",
            url: URL(string: "https://example.com/transcript.vtt")!
        )

        #expect(format == .vtt)
    }
}

@Suite("Segment kinds")
struct SegmentKindTests {
    /// Mapping must be total — an unrecognized value can never crash and can
    /// never cause the segment to be dropped (§5.3.3).
    @Test("Unknown model values map to .ad and are reported as unrecognized")
    func unknownKindFallsBack() {
        #expect(SegmentKind(modelValue: "advertisement") == .ad)
        #expect(!SegmentKind.isRecognized(modelValue: "advertisement"))
        #expect(SegmentKind.isRecognized(modelValue: "sponsor_read"))
        #expect(SegmentKind(modelValue: "sponsor read") == .sponsorRead)
    }
}

@Suite("Provenance")
struct ProvenanceTests {
    /// The runaway guard must exclude user-originated segments, or a user who
    /// said "always skip the first 90 seconds" gets overridden by a nervous
    /// heuristic (§5.6).
    @Test("Only manual provenance counts as user-originated")
    func userOriginatedProvenance() {
        #expect(Provenance.manual.isUserOriginated)
        #expect(!Provenance.onDeviceModel(windowIndex: 0, modelTier: "core").isUserOriginated)
        #expect(!Provenance.patternMatch(patternID: UUID(), score: 0.9).isUserOriginated)
    }
}

@Suite("Pipeline stage dependencies")
struct PipelineStageTests {
    @Test("Ad scan transitively requires download")
    func transitivePrerequisites() {
        #expect(PipelineStage.adScan.allPrerequisites == [.transcribe, .download])
        #expect(PipelineStage.download.allPrerequisites.isEmpty)
    }

    /// Disabling an upstream stage must grey out everything below it (§9.4).
    @Test("Disabling download disables every downstream stage")
    func dependentsOfDownload() {
        let dependents = Set(PipelineStage.download.dependents)
        #expect(dependents == [.transcribe, .chapters, .adScan])
    }
}

@Suite("Inheritable settings")
struct InheritableSettingTests {
    /// "I haven't decided" must stay distinguishable from "I chose off", or the
    /// settings screen cannot show what is actually happening (§9.2).
    @Test("Inherit and an explicit false resolve the same but report differently")
    func inheritIsDistinctFromExplicitOff() {
        let inherited = Inheritable<Bool>.inherit
        let explicitlyOff = Inheritable<Bool>.override(false)

        #expect(inherited.resolved(default: false) == false)
        #expect(explicitlyOff.resolved(default: false) == false)

        #expect(inherited.resolve(default: false).origin == .global)
        #expect(explicitlyOff.resolve(default: false).origin == .show)
    }

    @Test("An override wins over the global default")
    func overrideWins() {
        let setting = Inheritable<Bool>.override(true)
        #expect(setting.resolve(default: false).value == true)
        #expect(!setting.isInherited)
    }
}

@Suite("Timed transcript")
struct TimedTranscriptTests {
    @Test("Segments are kept in time order regardless of input order")
    func sortsSegments() {
        let transcript = TimedTranscript(
            source: .podcasting20,
            segments: [
                .init(startMs: 5_000, endMs: 6_000, text: "second"),
                .init(startMs: 1_000, endMs: 2_000, text: "first"),
            ]
        )

        #expect(transcript.segments.map(\.text) == ["first", "second"])
        #expect(transcript.durationMs == 6_000)
    }

    /// Model-emitted timestamps are snapped to transcript boundaries in
    /// post-processing rather than trusted from the prompt (§5.3.4).
    @Test("Boundary snapping picks the nearest transcript edge")
    func snapsToNearestBoundary() {
        let transcript = TimedTranscript(
            source: .onDevice,
            segments: [
                .init(startMs: 0, endMs: 1_000, text: "a"),
                .init(startMs: 1_000, endMs: 4_000, text: "b"),
            ]
        )

        #expect(transcript.nearestBoundary(toMs: 1_100) == 1_000)
        #expect(transcript.nearestBoundary(toMs: 3_800) == 4_000)
    }

    @Test("An empty transcript has no boundary to snap to")
    func emptyTranscript() {
        let transcript = TimedTranscript(source: .onDevice, segments: [])
        #expect(transcript.nearestBoundary(toMs: 500) == nil)
        #expect(transcript.isEmpty)
    }
}
