import AVFoundation
import Foundation

/// Streams a slice of an audio file into a temp file, buffer by buffer —
/// never the whole slice in memory (a 30-minute chunk of a 4-hour episode
/// would be over a gigabyte as one PCM buffer).
enum AudioSlicer {
    struct Slice {
        var url: URL
        var startMs: Int

        func cleanUp() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func write(
        from sourceURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) throws -> Slice? {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = source.length

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < totalFrames else { return nil }
        var remaining = min(
            AVAudioFramePosition(durationSeconds * sampleRate),
            totalFrames - startFrame
        )
        guard remaining > AVAudioFramePosition(sampleRate) else { return nil }

        let sliceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-\(UUID().uuidString).caf")
        let writer = try AVAudioFile(forWriting: sliceURL, settings: format.settings)

        source.framePosition = startFrame
        let chunkFrames = AVAudioFrameCount(sampleRate * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try source.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return Slice(url: sliceURL, startMs: Int(startSeconds * 1000))
    }
}
