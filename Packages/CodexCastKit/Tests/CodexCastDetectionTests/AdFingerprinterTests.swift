import AVFoundation
import Foundation
import Testing

@testable import CodexCastDetection

@Suite("Ad fingerprinting")
struct AdFingerprinterTests {
    /// Deterministic "rich" audio: summed detuned oscillators with slow
    /// wander — enough spectral structure for landmark hashing, unlike a
    /// pure tone.
    private func writeAudio(
        seconds: Double, seed: Int, insert: (samples: [Float], atSecond: Double)? = nil
    ) throws -> URL {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-\(seed)-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: frames)
        var state = UInt64(seed * 2_654_435_761 + 1)
        var phases = [Double](repeating: 0, count: 6)
        var freqs = (0..<6).map { 180.0 * Double($0 + 1) + Double(seed % 97) }
        for index in 0..<frames {
            if index % 4_410 == 0 {
                for band in 0..<6 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    freqs[band] += Double(Int(state >> 33) % 41) - 20
                    freqs[band] = min(max(freqs[band], 100), 6_000)
                }
            }
            var value = 0.0
            for band in 0..<6 {
                phases[band] += 2 * .pi * freqs[band] / sampleRate
                value += sin(phases[band]) / 6
            }
            samples[index] = Float(value * 0.5)
        }
        if let insert {
            let at = Int(insert.atSecond * sampleRate)
            for (offset, sample) in insert.samples.enumerated() where at + offset < frames {
                samples[at + offset] = sample
            }
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: frames)
        }
        try file.write(from: buffer)
        return url
    }

    private func samples(of url: URL, fromSecond: Double, seconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(fromSecond * rate)
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)
        ))
    }

    @Test("A confirmed ad's audio is found again at a different position")
    func repeatDetection() async throws {
        // Episode A: the "ad" is seconds 10-25 (seed-7 audio inside seed-1).
        let adSource = try writeAudio(seconds: 15, seed: 7)
        let ad = try samples(of: adSource, fromSecond: 0, seconds: 15)
        let episodeA = try writeAudio(seconds: 45, seed: 1, insert: (ad, 10))
        // Episode B: the SAME ad inserted at second 22 of different content.
        let episodeB = try writeAudio(seconds: 60, seed: 2, insert: (ad, 22))
        defer {
            try? FileManager.default.removeItem(at: adSource)
            try? FileManager.default.removeItem(at: episodeA)
            try? FileManager.default.removeItem(at: episodeB)
        }

        // Capture from A (what confirmSegment does).
        let data = try #require(try AdFingerprinter.signature(
            fileURL: episodeA, startMs: 10_000, endMs: 25_000
        ))

        // Match against B (what scanForAds does).
        let matches = await AdFingerprinter.matches(
            fileURL: episodeB,
            references: [.init(id: "ad-1", signature: data, durationMs: 15_000)],
            sliceSeconds: 8, hopSeconds: 4
        )
        let hit = try #require(matches.first, "the repeated ad audio was not found")
        #expect(hit.referenceID == "ad-1")
        // Inserted at 22s; allow slice-level slop.
        #expect(abs(hit.startMs - 22_000) < 6_000, "found at \(hit.startMs)ms, expected ~22000ms")
    }

    @Test("Unrelated audio does not match")
    func noFalseMatch() async throws {
        let adSource = try writeAudio(seconds: 15, seed: 7)
        let ad = try samples(of: adSource, fromSecond: 0, seconds: 15)
        let episodeA = try writeAudio(seconds: 45, seed: 1, insert: (ad, 10))
        let unrelated = try writeAudio(seconds: 60, seed: 3)
        defer {
            try? FileManager.default.removeItem(at: adSource)
            try? FileManager.default.removeItem(at: episodeA)
            try? FileManager.default.removeItem(at: unrelated)
        }
        let data = try #require(try AdFingerprinter.signature(
            fileURL: episodeA, startMs: 10_000, endMs: 25_000
        ))
        let matches = await AdFingerprinter.matches(
            fileURL: unrelated,
            references: [.init(id: "ad-1", signature: data, durationMs: 15_000)],
            sliceSeconds: 8, hopSeconds: 4
        )
        #expect(matches.isEmpty)
    }
}
