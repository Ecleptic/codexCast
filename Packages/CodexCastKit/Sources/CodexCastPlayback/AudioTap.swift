import AVFoundation
import Foundation
import MediaToolbox
import os

/// Real-time audio processing for `AVPlayer` via `MTAudioProcessingTap`.
///
/// §10.1's chain runs here rather than in an `AVAudioEngine` graph so that ONE
/// playback engine serves both streamed and downloaded episodes — a second
/// engine would mean two timelines, two seek paths, and two remote-control
/// integrations that drift. The tap gives us the decoded samples in place;
/// the chain below is the same math `AVAudioUnitEQ` + a compressor would do.
///
/// Everything in this file below `AudioTapController` runs on the media
/// render thread. No allocation, no Objective-C, no actor hops — parameter
/// changes cross over through one lock.

// MARK: - DSP primitives

/// Direct-form-1 biquad (RBJ cookbook). One instance per channel per band.
struct Biquad {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0, a1: Double = 0, a2: Double = 0
    var x1: Double = 0, x2: Double = 0, y1: Double = 0, y2: Double = 0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func resetState() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 + cosw) / 2 / a0
        f.b1 = -(1 + cosw) / a0
        f.b2 = (1 + cosw) / 2 / a0
        f.a1 = -2 * cosw / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    /// Peaking EQ; `bandwidth` in octaves.
    static func peaking(frequency: Double, gainDb: Double, bandwidth: Double, sampleRate: Double) -> Biquad {
        let amp = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw * sinh(log(2) / 2 * bandwidth * w0 / sinw)
        let a0 = 1 + alpha / amp
        var f = Biquad()
        f.b0 = (1 + alpha * amp) / a0
        f.b1 = -2 * cosw / a0
        f.b2 = (1 - alpha * amp) / a0
        f.a1 = -2 * cosw / a0
        f.a2 = (1 - alpha / amp) / a0
        return f
    }
}

/// The per-channel §10.1 chain: high-pass → presence lift → mud cut →
/// compression with makeup gain → optional slow AGC → limiter.
///
/// A plain struct so tests can drive it sample-by-sample without a tap.
struct VoiceBoostChain {
    var highPass: Biquad
    var presence: Biquad
    var muddiness: Biquad

    // Compressor state (envelope in linear amplitude).
    var envelope: Double = 0
    let attackCoef: Double
    let releaseCoef: Double
    let thresholdDb: Double
    let ratio: Double
    let makeupGain: Double

    init(parameters: VoiceBoostParameters, sampleRate: Double) {
        highPass = .highPass(frequency: Double(parameters.highPassHz), sampleRate: sampleRate)
        presence = .peaking(
            frequency: Double(parameters.presenceCenterHz),
            gainDb: Double(parameters.presenceGainDb), bandwidth: 1.0, sampleRate: sampleRate
        )
        muddiness = .peaking(
            frequency: Double(parameters.muddinessCenterHz),
            gainDb: Double(parameters.muddinessGainDb), bandwidth: 1.0, sampleRate: sampleRate
        )
        attackCoef = 1 - exp(-1 / (sampleRate * Double(parameters.attackMs) / 1000))
        releaseCoef = 1 - exp(-1 / (sampleRate * 0.12))
        thresholdDb = Double(parameters.compressionThresholdDb)
        ratio = Double(parameters.compressionRatio)
        makeupGain = pow(10, Double(parameters.makeupGainDb) / 20)
    }

    mutating func process(_ x: Double) -> Double {
        var y = highPass.process(x)
        y = presence.process(y)
        y = muddiness.process(y)

        // Envelope follower on the filtered signal.
        let magnitude = abs(y)
        if magnitude > envelope {
            envelope += attackCoef * (magnitude - envelope)
        } else {
            envelope += releaseCoef * (magnitude - envelope)
        }
        let envelopeDb = 20 * log10(max(envelope, 1e-6))
        let over = envelopeDb - thresholdDb
        let reductionDb = over > 0 ? -over * (1 - 1 / ratio) : 0
        y *= pow(10, reductionDb / 20) * makeupGain
        return y
    }
}

/// Slow automatic gain toward a spoken-word comfortable level (§10.4 volume
/// normalization). Deliberately sluggish: it levels episodes, not syllables.
struct NormalizerState {
    var meanSquare: Double = 0
    var gain: Double = 1
    let rmsCoef: Double
    let gainCoef: Double
    /// ~ -20 dBFS RMS, the loudness ballpark of professionally mastered speech.
    let targetRms: Double = 0.1

    init(sampleRate: Double) {
        rmsCoef = 1 - exp(-1 / (sampleRate * 3.0))
        gainCoef = 1 - exp(-1 / (sampleRate * 1.0))
    }

    mutating func process(_ x: Double) -> Double {
        meanSquare += rmsCoef * (x * x - meanSquare)
        // Hold the gain through silence instead of cranking it into the noise.
        if meanSquare > 1e-7 {
            let target = min(4.0, max(0.5, targetRms / meanSquare.squareRoot()))
            gain += gainCoef * (target - gain)
        }
        return x * gain
    }
}

// MARK: - Shared tap state

/// The bridge between the main thread (settings changes) and the render
/// thread (the process callback). All mutable fields are guarded by `lock`.
final class AudioTapState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    // Set by the prepare callback.
    private var sampleRate: Double = 0
    private var channelCount: Int = 0
    private var isSupportedFormat = false

    // Desired configuration, applied lazily once the format is known.
    private var voiceBoostLevel: VoiceBoostLevel = .off
    private var monoDownmix = false
    private var volumeNormalization = false

    // Built lazily from level + format; one chain per channel.
    private var chains: [VoiceBoostChain] = []
    private var normalizers: [NormalizerState] = []
    private var builtForLevel: VoiceBoostLevel = .off

    func configure(voiceBoost: VoiceBoostLevel, monoDownmix: Bool, volumeNormalization: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.voiceBoostLevel = voiceBoost
        self.monoDownmix = monoDownmix
        self.volumeNormalization = volumeNormalization
        rebuildIfNeeded()
    }

    func prepare(description: AudioStreamBasicDescription) {
        lock.lock()
        defer { lock.unlock() }
        sampleRate = description.mSampleRate
        channelCount = Int(description.mChannelsPerFrame)
        // The tap is created with PreEffects/PostEffects on AVPlayer's decoded
        // output, which is non-interleaved Float32 — anything else passes
        // through untouched rather than corrupting audio.
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        isSupportedFormat = description.mFormatID == kAudioFormatLinearPCM
            && isFloat && isNonInterleaved && description.mBitsPerChannel == 32
        builtForLevel = .off
        chains = []
        normalizers = []
        rebuildIfNeeded()
    }

    func unprepare() {
        lock.lock()
        defer { lock.unlock() }
        isSupportedFormat = false
        chains = []
        normalizers = []
        builtForLevel = .off
    }

    /// Must be called with the lock held.
    private func rebuildIfNeeded() {
        guard sampleRate > 0, channelCount > 0 else { return }
        if builtForLevel != voiceBoostLevel {
            if let parameters = VoiceBoostParameters.parameters(for: voiceBoostLevel) {
                chains = (0..<channelCount).map { _ in
                    VoiceBoostChain(parameters: parameters, sampleRate: sampleRate)
                }
            } else {
                chains = []
            }
            builtForLevel = voiceBoostLevel
        }
        if volumeNormalization, normalizers.count != channelCount {
            normalizers = (0..<channelCount).map { _ in NormalizerState(sampleRate: sampleRate) }
        }
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard isSupportedFormat else { return }
        let anyProcessing = voiceBoostLevel.isEnabled || monoDownmix || volumeNormalization
        guard anyProcessing else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: [UnsafeMutablePointer<Float>] = []
        channels.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData else { return }
            channels.append(data.assumingMemoryBound(to: Float.self))
        }
        guard !channels.isEmpty else { return }

        if monoDownmix, channels.count > 1 {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in channels { sum += channel[frame] }
                let mono = sum / Float(channels.count)
                for channel in channels { channel[frame] = mono }
            }
        }

        for (index, channel) in channels.enumerated() {
            let hasChain = index < chains.count
            let hasNormalizer = volumeNormalization && index < normalizers.count
            guard hasChain || hasNormalizer else { continue }
            for frame in 0..<frameCount {
                var sample = Double(channel[frame])
                if hasChain {
                    sample = chains[index].process(sample)
                }
                if hasNormalizer {
                    sample = normalizers[index].process(sample)
                }
                // Hard safety limiter; the compressor's makeup gain and the
                // AGC can both push peaks over full scale.
                channel[frame] = Float(min(max(sample, -0.985), 0.985))
            }
        }
    }
}

// MARK: - Tap callbacks (C conventions — no captures allowed)

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let state = Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    state.prepare(description: processingFormat.pointee)
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let state = Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    state.unprepare()
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }
    let state = Unmanaged<AudioTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    state.process(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
}

// MARK: - Controller

/// Owns the shared DSP state and attaches a fresh tap to each player item.
///
/// Settings survive across episodes: `update` changes the state every live
/// tap reads, so flipping Voice Boost mid-episode is audible within a buffer.
@MainActor
public final class AudioTapController {
    private let state = AudioTapState()

    public init() {}

    public func update(_ settings: ResolvedPlaybackSettings) {
        state.configure(
            voiceBoost: settings.voiceBoost,
            monoDownmix: settings.monoDownmix,
            volumeNormalization: settings.volumeNormalization
        )
    }

    /// Builds the audio mix for `item` once its audio track is known. Async
    /// because track loading is; the first seconds of playback are untapped,
    /// which is inaudible for speech and beats blocking play().
    public func attach(to item: AVPlayerItem) {
        let state = state
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
                return
            }
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passRetained(state).toOpaque(),
                init: tapInit,
                finalize: tapFinalize,
                prepare: tapPrepare,
                unprepare: tapUnprepare,
                process: tapProcess
            )
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &tap
            )
            guard status == noErr, let tap else {
                // Creation failed after the retain: balance it here since
                // finalize will never run.
                Unmanaged.passUnretained(state).release()
                return
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }
}
