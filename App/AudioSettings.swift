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

    /// Lenient decoding, on purpose.
    ///
    /// Swift's synthesized `Decodable` does NOT fall back to a property's
    /// default when its key is missing — it throws. Since these blobs are
    /// loaded with `try?` and fall back to a fresh instance, ADDING one field
    /// in a future build would silently reset every setting the listener had
    /// chosen. Decoding each key independently makes new fields additive.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        trimSilence = try container.decodeIfPresent(Bool.self, forKey: .trimSilence) ?? false
        voiceBoostEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceBoostEnabled) ?? false
        voiceBoostLevel = try container.decodeIfPresent(VoiceBoostLevel.self, forKey: .voiceBoostLevel) ?? .low
        monoDownmix = try container.decodeIfPresent(Bool.self, forKey: .monoDownmix) ?? false
        volumeNormalization = try container.decodeIfPresent(Bool.self, forKey: .volumeNormalization) ?? false
        autoSkipAds = try container.decodeIfPresent(Bool.self, forKey: .autoSkipAds) ?? false
    }

    init() {}

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
