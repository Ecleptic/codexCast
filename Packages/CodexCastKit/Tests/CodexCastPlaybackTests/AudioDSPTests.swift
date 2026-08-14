import AVFoundation
import Foundation
import Testing

@testable import CodexCastPlayback

/// The DSP chain, driven sample-by-sample without a tap or a player.
@Suite struct AudioDSPTests {
    private let sampleRate = 44_100.0

    private func rms(_ samples: [Double]) -> Double {
        (samples.map { $0 * $0 }.reduce(0, +) / Double(samples.count)).squareRoot()
    }

    private func sine(hz: Double, seconds: Double, amplitude: Double) -> [Double] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { amplitude * sin(2 * .pi * hz * Double($0) / sampleRate) }
    }

    @Test func highPassRemovesRumbleAndKeepsSpeechBand() {
        var rumbleFilter = Biquad.highPass(frequency: 80, sampleRate: sampleRate)
        let rumble = sine(hz: 30, seconds: 0.5, amplitude: 0.5)
        let filteredRumble = rumble.map { rumbleFilter.process($0) }
        // Steady state only; the filter needs a moment to settle.
        let tail = Array(filteredRumble.suffix(filteredRumble.count / 2))
        #expect(rms(tail) < rms(Array(rumble.suffix(rumble.count / 2))) * 0.2)

        var speechFilter = Biquad.highPass(frequency: 80, sampleRate: sampleRate)
        let speech = sine(hz: 1_000, seconds: 0.5, amplitude: 0.5)
        let filteredSpeech = speech.map { speechFilter.process($0) }
        let speechTail = Array(filteredSpeech.suffix(filteredSpeech.count / 2))
        #expect(rms(speechTail) > rms(Array(speech.suffix(speech.count / 2))) * 0.9)
    }

    @Test func peakingBoostLiftsItsBand() {
        var filter = Biquad.peaking(frequency: 3_000, gainDb: 6, bandwidth: 1.0, sampleRate: sampleRate)
        let tone = sine(hz: 3_000, seconds: 0.5, amplitude: 0.25)
        let boosted = tone.map { filter.process($0) }
        let gain = rms(Array(boosted.suffix(boosted.count / 2)))
            / rms(Array(tone.suffix(tone.count / 2)))
        // +6 dB is ×2 in amplitude.
        #expect(gain > 1.8 && gain < 2.2)
    }

    @Test func compressionNarrowsTheGapBetweenQuietAndLoudVoices() {
        let parameters = VoiceBoostParameters.parameters(for: .high)!
        // Two "speakers": one at -30 dBFS, one at -10 dBFS, in the presence band.
        let quiet = sine(hz: 1_000, seconds: 1.0, amplitude: 0.032)
        let loud = sine(hz: 1_000, seconds: 1.0, amplitude: 0.32)

        var chainQuiet = VoiceBoostChain(parameters: parameters, sampleRate: sampleRate)
        var chainLoud = VoiceBoostChain(parameters: parameters, sampleRate: sampleRate)
        let processedQuiet = quiet.map { chainQuiet.process($0) }
        let processedLoud = loud.map { chainLoud.process($0) }

        let before = rms(Array(loud.suffix(loud.count / 2))) / rms(Array(quiet.suffix(quiet.count / 2)))
        let after = rms(Array(processedLoud.suffix(processedLoud.count / 2)))
            / rms(Array(processedQuiet.suffix(processedQuiet.count / 2)))
        // 20 dB apart going in; meaningfully closer coming out.
        #expect(after < before * 0.6)
        // And the quiet speaker came UP, not the loud one merely clipped down.
        #expect(rms(Array(processedQuiet.suffix(processedQuiet.count / 2)))
            > rms(Array(quiet.suffix(quiet.count / 2))))
    }

    @Test func normalizerPullsQuietAudioTowardTarget() {
        var normalizer = NormalizerState(sampleRate: sampleRate)
        let quiet = sine(hz: 440, seconds: 12, amplitude: 0.02)
        let out = quiet.map { normalizer.process($0) }
        let tail = Array(out.suffix(out.count / 4))
        #expect(rms(tail) > rms(Array(quiet.suffix(quiet.count / 4))) * 1.5)
    }
}

@Suite struct SilenceMapTests {
    /// Speech–pause–speech, written as a real audio file and analyzed the way
    /// playback does it.
    @Test func analyzeFindsThePauseAndRoundTrips() throws {
        let sampleRate = 22_050.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-map-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: SilenceMap.sidecarURL(for: url))
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let seconds = 6.0
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // Silence from 2.0s to 3.2s; "speech" (a loud tone) elsewhere.
            data[i] = (t >= 2.0 && t < 3.2) ? 0 : Float(0.4 * sin(2 * .pi * 220 * t))
        }
        try file.write(from: buffer)

        let map = try SilenceMap.analyze(fileURL: url)
        #expect(map.gaps.count == 1)
        let gap = try #require(map.gaps.first)
        #expect(abs(gap.startMs - 2_000) < 150)
        #expect(abs(gap.endMs - 3_200) < 150)
        #expect(abs(map.mediaDurationMs - 6_000) < 50)

        try map.save(for: url)
        let loaded = try #require(SilenceMap.load(for: url))
        #expect(loaded.gaps == map.gaps)
    }
}
