import Foundation

/// A per-show setting that may defer to the global default (§9.2).
///
/// Deliberately not a plain `Bool` at two levels: "I haven't decided" must stay
/// distinguishable from "I chose off", or the settings UI cannot honestly show
/// the user what is actually happening. Both pipeline settings (§9.2) and
/// playback settings (§10.4) use this, so it lives here and is written once.
public enum Inheritable<Value: Sendable & Hashable & Codable>: Hashable, Sendable, Codable {
    case inherit
    case override(Value)

    public func resolved(default fallback: Value) -> Value {
        switch self {
        case .inherit: fallback
        case .override(let value): value
        }
    }

    public var isInherited: Bool {
        if case .inherit = self { return true }
        return false
    }

    public var overrideValue: Value? {
        if case .override(let value) = self { return value }
        return nil
    }
}

/// The resolved value plus where it came from, so the UI can render
/// "Off — inherited from global" rather than a bare toggle state.
public struct ResolvedSetting<Value: Sendable & Hashable & Codable>: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        case global
        case show
    }

    public var value: Value
    public var origin: Origin

    public init(value: Value, origin: Origin) {
        self.value = value
        self.origin = origin
    }
}

extension Inheritable {
    public func resolve(default fallback: Value) -> ResolvedSetting<Value> {
        switch self {
        case .inherit: ResolvedSetting(value: fallback, origin: .global)
        case .override(let value): ResolvedSetting(value: value, origin: .show)
        }
    }
}

/// The pipeline stages that can be independently toggled (§9.1). `fetch` is
/// absent deliberately — it always runs.
public enum PipelineStage: String, Hashable, Sendable, Codable, CaseIterable {
    case download
    case transcribe
    case chapters
    case adScan

    /// Stages that must be enabled for this one to do anything. Enforced in the
    /// UI, not merely implied: a show configured to scan with nothing to scan
    /// is a bug, not a user choice (§9.4).
    public var prerequisites: [PipelineStage] {
        switch self {
        case .download: []
        case .transcribe: [.download]
        case .chapters: [.transcribe]
        case .adScan: [.transcribe]
        }
    }

    /// Transitive prerequisites, nearest first.
    public var allPrerequisites: [PipelineStage] {
        var seen: [PipelineStage] = []
        var queue = prerequisites
        while !queue.isEmpty {
            let stage = queue.removeFirst()
            guard !seen.contains(stage) else { continue }
            seen.append(stage)
            queue.append(contentsOf: stage.prerequisites)
        }
        return seen
    }

    /// Stages that become unavailable when this one is disabled.
    public var dependents: [PipelineStage] {
        Self.allCases.filter { $0 != self && $0.allPrerequisites.contains(self) }
    }
}

/// When an enabled stage is allowed to run (§9.3).
public enum TriggerMode: String, Hashable, Sendable, Codable, CaseIterable {
    case onPublish
    case wifiOnly
    case overnight
    case manual
}
