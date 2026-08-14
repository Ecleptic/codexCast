// Shared plumbing for the Phase 0 arms: corpus location, audio lookup, and the
// scoring report, so every arm prints the same table from the same metrics.

import CodexCastDetection
import Foundation

public enum SpikeEnvironment {
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SpikeShared
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // SpikeTool
        .deletingLastPathComponent()  // Spike
        .deletingLastPathComponent()  // repo root
    public static var corpusDir: URL { root.appendingPathComponent("Fixtures/corpus") }
    public static var mediaDir: URL { root.appendingPathComponent("Spike/media") }

    /// Corpus show slug → media folder.
    static let mediaFolders = [
        "tech-brew-ride-home": "ridehome",
        "the-nextlander-podcast": "nextlander",
        "linux-unplugged": "linuxunplugged",
        "podcasting-2-0": "pc20",
        "coder-radio": "coderradio",
        "the-changelog": "changelog",
        "podnews-daily": "podnews",
        "podnews-weekly-review": "podnewsweekly",
    ]

    /// The audio file for a corpus episode, matched by slug.
    public static func audioFile(for episode: CorpusEpisode) -> URL? {
        guard let folder = mediaFolders[slugify(episode.show)] else { return nil }
        let episodeSlug = slugify(episode.episodeTitle)

        let directory = mediaDir.appendingPathComponent(folder)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.first { file in
            guard file.pathExtension == "mp3" else { return false }
            let stem = file.deletingPathExtension().lastPathComponent
            return stem.replacingOccurrences(
                of: #"^\d+-"#, with: "", options: .regularExpression
            ) == episodeSlug
        }
    }

    public static func slugify(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func report(
        _ rows: [(episode: CorpusEpisode, predicted: [ClosedRange<Int>])]
    ) {
        var total = EvalResult()

        for (episode, predicted) in rows {
            let truth = EvalMetrics.mergeSpans(episode.adSpans())
            let result = EvalMetrics.evaluate(predicted: predicted, truth: truth)
            total = total + result
            let name = "\(episode.show.prefix(18))/\(episode.episodeTitle.prefix(12))"
            print(String(
                format: "  %-33@ P %.2f  R %.2f  F1 %.2f  (tp %d fp %d fn %d)",
                name as NSString,
                result.precision, result.recall, result.f1,
                result.truePositives, result.falsePositives, result.falseNegatives
            ))
        }

        print(String(
            format: "  TOTAL  P %.2f  R %.2f  F1 %.2f  boundary %.0f ms",
            total.precision, total.recall, total.f1, total.meanBoundaryErrorMs
        ))
    }
}
