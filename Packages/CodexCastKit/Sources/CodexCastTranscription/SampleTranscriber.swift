import AVFoundation
import CodexCastCore
import Foundation

extension TranscriptionEngine {
    /// Transcribes short clips at fixed points through a file — the cheap
    /// half of the A1 drift check. Three 20-second clips cost a couple of
    /// seconds; transcribing the whole hour to find out the feed transcript
    /// was fine would cost the whole hour's transcription.
    public func sampleTranscripts(
        fileAt url: URL,
        fractions: [Double] = [0.25, 0.5, 0.75],
        clipSeconds: Double = 20
    ) async throws -> [TranscriptDriftDetector.Sample] {
        var samples: [TranscriptDriftDetector.Sample] = []
        for fraction in fractions {
            guard let clip = try Self.extractClip(
                from: url, fraction: fraction, seconds: clipSeconds
            ) else { continue }
            defer { try? FileManager.default.removeItem(at: clip.url) }
            guard let transcript = try? await transcribe(fileAt: clip.url) else { continue }
            samples.append(TranscriptDriftDetector.Sample(
                audioStartMs: clip.startMs,
                text: transcript.plainText
            ))
        }
        return samples
    }

    /// Copies a slice of the audio into a temp file the analyzer can read.
    private static func extractClip(
        from url: URL, fraction: Double, seconds: Double
    ) throws -> (url: URL, startMs: Int)? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        let clipFrames = AVAudioFrameCount(format.sampleRate * seconds)
        guard totalFrames > AVAudioFramePosition(clipFrames) * 2 else { return nil }

        let startFrame = AVAudioFramePosition(Double(totalFrames) * fraction)
        file.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: clipFrames) else {
            return nil
        }
        try file.read(into: buffer, frameCount: clipFrames)
        guard buffer.frameLength > 0 else { return nil }

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-\(UUID().uuidString).caf")
        let writer = try AVAudioFile(forWriting: clipURL, settings: format.settings)
        try writer.write(from: buffer)

        let startMs = Int(Double(startFrame) / format.sampleRate * 1000)
        return (clipURL, startMs)
    }
}
