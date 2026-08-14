import CodexCastPlayback
import Foundation

/// The global audio defaults the settings screen edits (A5.4).
///
/// Flat and simple by design: per-show overrides use `PlaybackSettings`'
/// three-state `Inheritable` values and resolve against these.
struct AudioSettings: Hashable, Sendable, Codable {
    var speed: Double = 1.0
    var trimSilence: Bool = false
    var voiceBoostEnabled: Bool = false
    var voiceBoostLevel: VoiceBoostLevel = .low
    var monoDownmix: Bool = false
    var volumeNormalization: Bool = false
    /// Off by default while the model is unproven: the first field test
    /// produced five confident false positives and zero real ads. Detected
    /// segments are always shown; skipping them silently is opt-in.
    var autoSkipAds: Bool = false

    /// Resolved per-show defaults for the playback engine.
    var resolvedDefaults: ResolvedPlaybackSettings {
        ResolvedPlaybackSettings(
            voiceBoost: voiceBoostEnabled ? voiceBoostLevel : .off,
            trimSilence: trimSilence,
            speed: PlaybackSpeed.normalize(speed),
            monoDownmix: monoDownmix,
            volumeNormalization: volumeNormalization
        )
    }
}
