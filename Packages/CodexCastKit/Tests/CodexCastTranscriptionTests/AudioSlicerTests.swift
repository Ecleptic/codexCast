import AVFoundation
import Foundation
import Testing

@testable import CodexCastTranscription

@Suite struct AudioSlicerTests {
    @Test("A slice streams out with the right length and start")
    func slicing() throws {
        let sampleRate = 22_050.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("slicer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: source) }

        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * 60)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05)) * 0.3
        }
        try file.write(from: buffer)

        let slice = try #require(try AudioSlicer.write(
            from: source, startSeconds: 20, durationSeconds: 15
        ))
        defer { slice.cleanUp() }
        #expect(slice.startMs == 20_000)

        let sliced = try AVAudioFile(forReading: slice.url)
        let seconds = Double(sliced.length) / sliced.processingFormat.sampleRate
        #expect(abs(seconds - 15) < 0.1)

        // Past-the-end slice yields nil, not garbage.
        #expect(try AudioSlicer.write(from: source, startSeconds: 59.5, durationSeconds: 15) == nil)
    }
}
