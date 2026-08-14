// Transcribes audio files to WebVTT using Apple's on-device speech models —
// the same SpeechAnalyzer/SpeechTranscriber stack the iOS app will use, so
// this is also a first exercise of that pipeline.
//
// Usage: transcribe <audio-file> [more audio files…]
// Output: <audio-file>.vtt next to each input.

import AVFoundation
import Foundation
import Speech

@main
struct Transcribe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data("usage: transcribe <audio-file>…\n".utf8))
            exit(2)
        }

        do {
            try await run(files: arguments.map { URL(fileURLWithPath: $0) })
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(files: [URL]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en_US")
        ) else {
            throw ToolError.noSupportedLocale
        }

        // The audioTimeRange attribute is the entire point: the labeler and the
        // detection pipeline both need millisecond timings, not just text.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Model assets download on first use.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("downloading speech model assets…")
            try await request.downloadAndInstall()
            print("assets installed")
        }

        for file in files {
            let started = Date()
            print("transcribing \(file.lastPathComponent)…")
            let cues = try await transcribe(file: file, transcriber: transcriber)
            let output = file.appendingPathExtension("vtt")
            try writeVTT(cues, to: output)
            let elapsed = Int(Date().timeIntervalSince(started))
            print("  \(cues.count) cues → \(output.lastPathComponent) (\(elapsed)s)")
        }
    }

    struct Cue {
        var startSeconds: Double
        var endSeconds: Double
        var text: String
    }

    static func transcribe(file: URL, transcriber: SpeechTranscriber) async throws -> [Cue] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: file)

        // Collect results concurrently while the analyzer walks the file.
        let collector = Task {
            var cues: [Cue] = []
            for try await result in transcriber.results {
                let text = result.text
                let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }

                // Take the time range from the attributed runs.
                var start: Double?
                var end: Double?
                for run in text.runs {
                    if let range = run.audioTimeRange {
                        let runStart = range.start.seconds
                        let runEnd = range.end.seconds
                        start = min(start ?? runStart, runStart)
                        end = max(end ?? runEnd, runEnd)
                    }
                }
                guard let startSeconds = start, let endSeconds = end, endSeconds > startSeconds else {
                    continue
                }
                cues.append(Cue(startSeconds: startSeconds, endSeconds: endSeconds, text: plain))
            }
            return cues
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collector.value.sorted { $0.startSeconds < $1.startSeconds }
    }

    static func writeVTT(_ cues: [Cue], to url: URL) throws {
        var vtt = "WEBVTT\n\n"
        for cue in cues {
            vtt += "\(timestamp(cue.startSeconds)) --> \(timestamp(cue.endSeconds))\n\(cue.text)\n\n"
        }
        try vtt.write(to: url, atomically: true, encoding: .utf8)
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    enum ToolError: Error {
        case noSupportedLocale
    }
}
