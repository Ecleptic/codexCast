import Foundation
import Testing

@testable import CodexCastDetection

/// Validates the music detector against the labeled Tech Brew episodes —
/// the show whose ad reads run over music beds (addendum A4).
@Suite struct MusicBedSmokeTests {
    private var mediaRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spike/media/ridehome")
    }

    @Test("Music regions cover the labeled ad in new-pixels (ad at 33-76s)")
    func newPixels() throws {
        let file = mediaRoot.appendingPathComponent("02-new-pixels.mp3")
        try #require(FileManager.default.fileExists(atPath: file.path))
        let regions = MusicBedDetector.musicRegions(fileURL: file)
        print("REGIONS:", regions.map { "\($0.startMs/1000)-\($0.endMs/1000)s" }.joined(separator: ", "))
        // The labeled ad is 33-76s, read over a music bed.
        let coversAd = regions.contains { $0.startMs < 76_000 && 33_000 < $0.endMs }
        #expect(coversAd, "no music region overlaps the known ad at 33-76s")
    }
}
