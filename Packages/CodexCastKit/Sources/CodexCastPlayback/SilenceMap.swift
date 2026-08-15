import AVFoundation
import Foundation

/// Where the silences are in one downloaded episode — the offline half of
/// Smart Speed (§10.2).
///
/// Playback never analyzes audio in real time: the map is computed once per
/// file (seconds of work, decode is far faster than real time), saved as a
/// sidecar next to the media, and dies with it when retention evicts the file.
public struct SilenceMap: Codable, Sendable {
    public var gaps: [SilenceDetector.Gap]
    public var mediaDurationMs: Int

    public init(gaps: [SilenceDetector.Gap], mediaDurationMs: Int) {
        self.gaps = gaps
        self.mediaDurationMs = mediaDurationMs
    }

    /// Everything down to a breath is stored — Stage 3 boundary snapping
    /// (§5.4) needs the half-second pause before "this episode is brought to
    /// you by", which trimming would never care about.
    public static let minimumStoredGapMs = 180

    /// Gaps worth speeding through. Shorter pauses are natural speech rhythm;
    /// removing them is what makes aggressive trim settings sound breathless.
    public static let minimumTrimGapMs = 600

    /// The subset of gaps Smart Speed glides through.
    public var trimGaps: [SilenceDetector.Gap] {
        gaps.filter { $0.durationMs >= Self.minimumTrimGapMs }
    }

    /// Decodes the whole file in chunks, keeping only per-frame energies
    /// (about 180k doubles for an hour — the samples themselves never
    /// accumulate). Blocking; call it off the main actor.
    public static func analyze(
        fileURL: URL,
        detector: SilenceDetector = SilenceDetector()
    ) throws -> SilenceMap {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let frameLength = max(1, Int(sampleRate * Double(detector.frameMs) / 1000))
        // Chunks aligned to whole detector frames so per-chunk energies concat
        // into exactly the energies of the whole file.
        let chunkFrames = AVAudioFrameCount(frameLength * 2048)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var energies: [Double] = []
        var mono: [Float] = []
        var carry: [Float] = []

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)

            mono.removeAll(keepingCapacity: true)
            mono.reserveCapacity(carry.count + frames)
            mono.append(contentsOf: carry)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += channelData[channel][frame]
                }
                mono.append(sum / Float(channels))
            }

            let usable = (mono.count / frameLength) * frameLength
            energies.append(contentsOf: detector.frameEnergies(
                samples: Array(mono[..<usable]), sampleRate: sampleRate
            ))
            carry = Array(mono[usable...])
        }

        let gaps = detector.gaps(
            energies: energies, minimumDurationMs: Self.minimumStoredGapMs
        )
        let durationMs = Int(Double(file.length) / sampleRate * 1000)
        return SilenceMap(gaps: gaps, mediaDurationMs: durationMs)
    }

    // MARK: - Sidecar persistence

    public static func sidecarURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("silence.json")
    }

    public static func load(for mediaURL: URL) -> SilenceMap? {
        guard let data = try? Data(contentsOf: sidecarURL(for: mediaURL)) else { return nil }
        return try? JSONDecoder().decode(SilenceMap.self, from: data)
    }

    public func save(for mediaURL: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.sidecarURL(for: mediaURL), options: .atomic)
    }
}
