import CodexCastCore
import Foundation

/// Per-show pipeline configuration: which stages run and when (§9).
/// Every field is three-state — Inherit / On / Off — resolving against the
/// global defaults, and stored as one JSON blob on the podcast row.
public struct PipelineSettings: Hashable, Sendable, Codable {
    public struct StageSetting: Hashable, Sendable, Codable {
        public var enabled: Inheritable<Bool>
        public var trigger: Inheritable<TriggerMode>

        public init(
            enabled: Inheritable<Bool> = .inherit,
            trigger: Inheritable<TriggerMode> = .inherit
        ) {
            self.enabled = enabled
            self.trigger = trigger
        }
    }

    public var download: StageSetting
    public var transcribe: StageSetting
    public var chapters: StageSetting
    public var adScan: StageSetting

    public init(
        download: StageSetting = StageSetting(),
        transcribe: StageSetting = StageSetting(),
        chapters: StageSetting = StageSetting(),
        adScan: StageSetting = StageSetting()
    ) {
        self.download = download
        self.transcribe = transcribe
        self.chapters = chapters
        self.adScan = adScan
    }

    public subscript(stage: PipelineStage) -> StageSetting {
        get {
            switch stage {
            case .download: download
            case .transcribe: transcribe
            case .chapters: chapters
            case .adScan: adScan
            }
        }
        set {
            switch stage {
            case .download: download = newValue
            case .transcribe: transcribe = newValue
            case .chapters: chapters = newValue
            case .adScan: adScan = newValue
            }
        }
    }
}

/// The global defaults (§9.3): download on Wi-Fi, transcribe and scan
/// overnight, chapters off — useful, but the least essential and not free.
public struct GlobalPipelineDefaults: Hashable, Sendable, Codable {
    public var enabled: [PipelineStage: Bool]
    public var triggers: [PipelineStage: TriggerMode]

    public init(
        enabled: [PipelineStage: Bool]? = nil,
        triggers: [PipelineStage: TriggerMode]? = nil
    ) {
        self.enabled = enabled ?? [
            .download: true, .transcribe: true, .chapters: false, .adScan: true,
        ]
        self.triggers = triggers ?? [
            .download: .wifiOnly, .transcribe: .overnight, .chapters: .overnight, .adScan: .overnight,
        ]
    }
}

/// The fully-resolved answer for one stage of one show, carrying provenance so
/// the settings screen can honestly render "Off — inherited from global" (§9.2).
public struct ResolvedStage: Hashable, Sendable {
    public var stage: PipelineStage
    public var enabled: ResolvedSetting<Bool>
    public var trigger: ResolvedSetting<TriggerMode>
    /// Set when the stage is configured on but cannot run because a stage it
    /// needs is off. §9.4: this state is surfaced, never silently ignored.
    public var blockedBy: PipelineStage?

    /// Truly runnable: enabled and unblocked.
    public var isActive: Bool {
        enabled.value && blockedBy == nil
    }
}

public enum PipelineResolver {
    /// Resolves every stage for one show, enforcing the dependency chain: a
    /// stage whose prerequisite is disabled resolves as blocked, so "scan with
    /// nothing to scan" is unrepresentable downstream (§9.4).
    public static func resolve(
        show: PipelineSettings,
        defaults: GlobalPipelineDefaults = GlobalPipelineDefaults()
    ) -> [ResolvedStage] {
        var resolved: [PipelineStage: ResolvedStage] = [:]

        for stage in PipelineStage.allCases {
            let setting = show[stage]
            let enabled = setting.enabled.resolve(default: defaults.enabled[stage] ?? false)
            let trigger = setting.trigger.resolve(default: defaults.triggers[stage] ?? .manual)

            // Nearest disabled prerequisite, if any.
            let blocker = stage.allPrerequisites.first { prerequisite in
                resolved[prerequisite].map { !$0.enabled.value } ?? false
            }

            resolved[stage] = ResolvedStage(
                stage: stage,
                enabled: enabled,
                trigger: trigger,
                blockedBy: enabled.value ? blocker : nil
            )
        }

        return PipelineStage.allCases.compactMap { resolved[$0] }
    }

    /// What enabling a stage requires (§9.4): the prerequisites currently off,
    /// nearest first, so the UI can offer to enable them in the same
    /// interaction.
    public static func prerequisitesToEnable(
        _ stage: PipelineStage,
        show: PipelineSettings,
        defaults: GlobalPipelineDefaults = GlobalPipelineDefaults()
    ) -> [PipelineStage] {
        let resolved = resolve(show: show, defaults: defaults)
        return stage.allPrerequisites.filter { prerequisite in
            resolved.first { $0.stage == prerequisite }.map { !$0.enabled.value } ?? false
        }
    }
}

// MARK: - Notifications (§9.5)

/// What pipeline event a show notifies on. "On download complete" is the
/// important one: for a time-sensitive daily show, waiting for a scan defeats
/// the purpose.
public enum NotificationTrigger: String, Hashable, Sendable, Codable, CaseIterable {
    case never
    case onPublish
    case onDownloadComplete
    case onFullyProcessed
}

public struct NotificationSettings: Hashable, Sendable, Codable {
    public var trigger: Inheritable<NotificationTrigger>

    public init(trigger: Inheritable<NotificationTrigger> = .inherit) {
        self.trigger = trigger
    }

    public static let globalDefault = NotificationTrigger.never

    public func resolved(
        default fallback: NotificationTrigger = Self.globalDefault
    ) -> NotificationTrigger {
        trigger.resolved(default: fallback)
    }
}
