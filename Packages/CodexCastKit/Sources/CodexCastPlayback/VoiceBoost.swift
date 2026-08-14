import AVFoundation
import CodexCastCore
import Foundation

/// Voice Boost: a dynamics chain that raises the intelligibility of speech
/// recorded at inconsistent levels — two co-hosts on wildly different
/// microphones, or a phone-in guest.
///
/// It is **not** a volume increase.
///
/// § 10.1 of the spec is marked OPEN pending reference documentation from the
/// author. This implements the interim specification given there. The DSP sits
/// behind `VoiceBoostProcessor` so the chain can be replaced wholesale when
/// that material arrives, without touching the settings, UI, or engine wiring.
public enum VoiceBoostLevel: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    case low
    case high

    public var isEnabled: Bool { self != .off }
}

/// The parameter set for one level. Exposed as Off/Low/High in the UI — never
/// as DSP sliders.
public struct VoiceBoostParameters: Hashable, Sendable {
    /// Removes rumble and handling noise.
    public var highPassHz: Float
    /// Presence lift where consonant intelligibility lives.
    public var presenceCenterHz: Float
    public var presenceGainDb: Float
    /// Gentle cut to reduce muddiness.
    public var muddinessCenterHz: Float
    public var muddinessGainDb: Float
    /// Levels inter-speaker differences.
    public var compressionThresholdDb: Float
    public var compressionRatio: Float
    public var attackMs: Float
    /// Applied after compression, with limiting to prevent clipping.
    public var makeupGainDb: Float

    public static func parameters(for level: VoiceBoostLevel) -> VoiceBoostParameters? {
        switch level {
        case .off:
            return nil
        case .low:
            return VoiceBoostParameters(
                highPassHz: 80,
                presenceCenterHz: 3_000,
                presenceGainDb: 3,
                muddinessCenterHz: 300,
                muddinessGainDb: -2,
                compressionThresholdDb: -24,
                compressionRatio: 2.5,
                attackMs: 5,
                makeupGainDb: 3
            )
        case .high:
            return VoiceBoostParameters(
                highPassHz: 90,
                presenceCenterHz: 3_500,
                presenceGainDb: 6,
                muddinessCenterHz: 300,
                muddinessGainDb: -4,
                compressionThresholdDb: -30,
                compressionRatio: 4,
                attackMs: 3,
                makeupGainDb: 6
            )
        }
    }
}

/// Builds and applies the audio chain. Swap the implementation, not the callers,
/// when §10.1 is finalized.
public protocol VoiceBoostProcessor: Sendable {
    func makeNodes(for level: VoiceBoostLevel) -> [AVAudioUnit]
}

public struct DefaultVoiceBoostProcessor: VoiceBoostProcessor {
    public init() {}

    public func makeNodes(for level: VoiceBoostLevel) -> [AVAudioUnit] {
        guard let parameters = VoiceBoostParameters.parameters(for: level) else { return [] }

        // High-pass and the two EQ bands fit in a single AVAudioUnitEQ.
        let equalizer = AVAudioUnitEQ(numberOfBands: 3)
        equalizer.globalGain = parameters.makeupGainDb

        let highPass = equalizer.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = parameters.highPassHz
        highPass.bypass = false

        let presence = equalizer.bands[1]
        presence.filterType = .parametric
        presence.frequency = parameters.presenceCenterHz
        presence.bandwidth = 1.0
        presence.gain = parameters.presenceGainDb
        presence.bypass = false

        let muddiness = equalizer.bands[2]
        muddiness.filterType = .parametric
        muddiness.frequency = parameters.muddinessCenterHz
        muddiness.bandwidth = 1.0
        muddiness.gain = parameters.muddinessGainDb
        muddiness.bypass = false

        return [equalizer]
    }
}

/// Per-show playback settings, resolving against global defaults through the
/// same three-state mechanism the pipeline settings use (§10.4, §9.2).
public struct PlaybackSettings: Hashable, Sendable, Codable {
    public var voiceBoost: Inheritable<VoiceBoostLevel>
    public var trimSilence: Inheritable<Bool>
    public var speed: Inheritable<Double>
    public var monoDownmix: Inheritable<Bool>
    public var volumeNormalization: Inheritable<Bool>

    public init(
        voiceBoost: Inheritable<VoiceBoostLevel> = .inherit,
        trimSilence: Inheritable<Bool> = .inherit,
        speed: Inheritable<Double> = .inherit,
        monoDownmix: Inheritable<Bool> = .inherit,
        volumeNormalization: Inheritable<Bool> = .inherit
    ) {
        self.voiceBoost = voiceBoost
        self.trimSilence = trimSilence
        self.speed = speed
        self.monoDownmix = monoDownmix
        self.volumeNormalization = volumeNormalization
    }

    public static let globalDefaults = ResolvedPlaybackSettings(
        voiceBoost: .off,
        trimSilence: false,
        speed: 1.0,
        monoDownmix: false,
        volumeNormalization: false
    )

    public func resolved(
        against defaults: ResolvedPlaybackSettings = PlaybackSettings.globalDefaults
    ) -> ResolvedPlaybackSettings {
        ResolvedPlaybackSettings(
            voiceBoost: voiceBoost.resolved(default: defaults.voiceBoost),
            trimSilence: trimSilence.resolved(default: defaults.trimSilence),
            speed: speed.resolved(default: defaults.speed),
            monoDownmix: monoDownmix.resolved(default: defaults.monoDownmix),
            volumeNormalization: volumeNormalization.resolved(default: defaults.volumeNormalization)
        )
    }
}

public struct ResolvedPlaybackSettings: Hashable, Sendable, Codable {
    public var voiceBoost: VoiceBoostLevel
    public var trimSilence: Bool
    public var speed: Double
    public var monoDownmix: Bool
    public var volumeNormalization: Bool

    public init(
        voiceBoost: VoiceBoostLevel,
        trimSilence: Bool,
        speed: Double,
        monoDownmix: Bool,
        volumeNormalization: Bool
    ) {
        self.voiceBoost = voiceBoost
        self.trimSilence = trimSilence
        self.speed = speed
        self.monoDownmix = monoDownmix
        self.volumeNormalization = volumeNormalization
    }
}

/// Playback speed, constrained to the range and step the UI offers.
public enum PlaybackSpeed {
    public static let minimum = 0.5
    public static let maximum = 3.0
    public static let step = 0.05

    /// Clamps and quantizes to the nearest step, so a value from a slider or a
    /// restored setting cannot produce an unreachable speed.
    public static func normalize(_ value: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        return (clamped / step).rounded() * step
    }
}
