import AVFoundation
import CodexCastCore
import Foundation
import Speech

/// On-device transcription via `SpeechAnalyzer` / `SpeechTranscriber` (§9.9).
///
/// The `audioTimeRange` attribute is requested explicitly and is the entire
/// point: this app is boundary arithmetic, and an untimed transcript is
/// useless to it. Results carry millisecond timings or the engine fails loudly.
///
/// The same engine already proved itself as `Spike/TranscribeTool` during
/// corpus preparation — a 2-hour episode in ~3.5 minutes on an M-series Mac.
public struct TranscriptionEngine: Sendable {
    public enum EngineError: Error, Sendable, Equatable {
        /// No locale the transcriber supports matches the request.
        case unsupportedLocale
        /// Transcription produced nothing usable — silence, music, or a
        /// language the model cannot hear. Callers translate this into the
        /// episode-level `.notTranscribable` state (§9.8) rather than retrying
        /// forever.
        case emptyResult
    }

    public init() {}

    // MARK: - Asset management

    /// Whether the speech model assets are installed for the given locale, and
    /// a download request if they are not. Model assets are downloaded, not
    /// bundled; handled badly this is the worst possible first-run experience,
    /// so the caller surfaces download progress rather than silently stalling.
    public func assetInstallationRequest(
        locale: Locale = Locale(identifier: "en_US")
    ) async throws -> AssetInstallationRequest? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.unsupportedLocale
        }
        let transcriber = makeTranscriber(locale: supported)
        return try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    }

    // MARK: - Transcription

    /// Transcribes an audio file into a `TimedTranscript`.
    ///
    /// One at a time by policy (§9.7): `SpeechAnalyzer` is memory-hungry and
    /// two concurrent long episodes will get the app jetsammed. The job queue
    /// enforces that; this type just does one file.
    ///
    /// Long files are transcribed in sections: a 4-hour episode fed whole
    /// hits the OS speech-recognizer ceiling ("maximum number of recognizers
    /// reached") and runs the analyzer far past its comfortable memory. Each
    /// section is a fresh analyzer over a streamed temp slice; timestamps
    /// are shifted back to episode time and concatenated.
    public func transcribe(
        fileAt url: URL,
        locale: Locale = Locale(identifier: "en_US")
    ) async throws -> TimedTranscript {
        let chunkSeconds = 900.0   // 15 minutes: well under any recognizer limit
        let durationSeconds: Double
        do {
            let file = try AVAudioFile(forReading: url)
            durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        } catch {
            durationSeconds = 0
        }
        guard durationSeconds > chunkSeconds * 1.5 else {
            return try await transcribeWhole(fileAt: url, locale: locale)
        }

        var allSegments: [TimedTranscript.Segment] = []
        var offset = 0.0
        while offset < durationSeconds - 1 {
            let length = min(chunkSeconds, durationSeconds - offset)
            guard let slice = try AudioSlicer.write(
                from: url, startSeconds: offset, durationSeconds: length
            ) else { break }
            defer { slice.cleanUp() }
            // One bad section must not sink four hours of work.
            if let part = try? await transcribeWhole(fileAt: slice.url, locale: locale) {
                allSegments.append(contentsOf: part.segments.map { segment in
                    var shifted = segment
                    shifted.startMs += slice.startMs
                    shifted.endMs += slice.startMs
                    return shifted
                })
            }
            offset += chunkSeconds
        }
        guard !allSegments.isEmpty else { throw EngineError.emptyResult }
        return TimedTranscript(source: .onDevice, segments: allSegments)
    }

    func transcribeWhole(
        fileAt url: URL,
        locale: Locale = Locale(identifier: "en_US")
    ) async throws -> TimedTranscript {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.unsupportedLocale
        }

        let transcriber = makeTranscriber(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        let collector = Task {
            var segments: [TimedTranscript.Segment] = []
            for try await result in transcriber.results {
                if let segment = Self.segment(from: result.text) {
                    segments.append(segment)
                }
            }
            return segments
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let segments = try await collector.value
        guard !segments.isEmpty else {
            throw EngineError.emptyResult
        }
        return TimedTranscript(source: .onDevice, segments: segments)
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Extracts text and the time range from one attributed result.
    static func segment(from text: AttributedString) -> TimedTranscript.Segment? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }

        var start: Double?
        var end: Double?
        for run in text.runs {
            if let range = run.audioTimeRange {
                start = min(start ?? range.start.seconds, range.start.seconds)
                end = max(end ?? range.end.seconds, range.end.seconds)
            }
        }
        guard let startSeconds = start, let endSeconds = end, endSeconds > startSeconds else {
            // A result without timing is worthless here — drop it rather than
            // invent a position.
            return nil
        }

        return .init(
            startMs: Int(startSeconds * 1000),
            endMs: Int(endSeconds * 1000),
            text: plain
        )
    }
}

// MARK: - Quality gate (§9.8)

/// Decides whether a transcription attempt should mark the episode
/// `.notTranscribable` instead of retrying forever. Music shows, non-English
/// audio, and corrupt files all land here.
public enum TranscriptQualityGate {
    /// Words per minute below which a "transcript" is noise. Natural speech
    /// runs 100–180; a music show yields scattered fragments far below this.
    public static let minimumWordsPerMinute = 40.0

    public static func verdict(
        _ transcript: TimedTranscript,
        mediaDurationMs: Int
    ) -> Episode.NotTranscribableReason? {
        guard mediaDurationMs > 0, !transcript.isEmpty else {
            return .repeatedFailure
        }

        let words = transcript.segments
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let minutes = Double(mediaDurationMs) / 60_000
        let density = Double(words) / max(minutes, 0.1)

        // Coverage: a 60-minute file whose transcript spans 4 minutes is a
        // music show with one spoken intro, not a transcribed episode.
        let coverage = Double(transcript.durationMs) / Double(mediaDurationMs)

        if density < minimumWordsPerMinute || coverage < 0.3 {
            return .lowWordDensity
        }
        return nil
    }
}
