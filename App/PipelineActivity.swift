import CodexCastCore
import CodexCastPersistence
import Foundation

/// One episode's standing in one pipeline lane.
///
/// A flat snapshot, deliberately: the Activity screen renders it and nothing
/// else, so the four sources it is assembled from (in-flight work, scan
/// state, sticky failures, the pending queue) never have to be reconciled in
/// a view body.
struct ActivityItem: Identifiable, Sendable {
    enum Status: Sendable, Equatable {
        /// The queue owes this work but hasn't reached it.
        case waiting
        /// Happening now. `fraction` is nil for steps with no honest measure —
        /// a spinner is better than a bar that lies about being half done.
        case running(label: String, fraction: Double?)
        case failed(String)
        case done(detail: String?, at: Date)

        var sortRank: Int {
            switch self {
            case .running: 0
            case .waiting: 1
            case .failed: 2
            case .done: 3
            }
        }

        var isFinished: Bool {
            if case .done = self { return true }
            return false
        }
    }

    let lane: AppModel.PipelineLane
    let episode: EpisodeRecord
    let showTitle: String
    let status: Status

    var id: String { "\(lane.rawValue)-\(episode.id)" }
}

/// Everything the Activity screen shows, in one value.
struct ActivitySnapshot: Sendable {
    var items: [ActivityItem] = []

    func items(in lane: AppModel.PipelineLane) -> [ActivityItem] {
        items.filter { $0.lane == lane }
            .sorted { left, right in
                if left.status.sortRank != right.status.sortRank {
                    return left.status.sortRank < right.status.sortRank
                }
                return left.episode.publishedAt ?? .distantPast
                    > right.episode.publishedAt ?? .distantPast
            }
    }

    /// Work still owed, per lane — the number the Home badge counts.
    /// Failures count: they are owed work too, they just need a nudge.
    func pendingCount(in lane: AppModel.PipelineLane) -> Int {
        items.filter { $0.lane == lane && !$0.status.isFinished }.count
    }

    /// Waiting or running — work that will move on its own, unlike a failure.
    var activeCount: Int {
        items.filter {
            switch $0.status {
            case .waiting, .running: true
            default: false
            }
        }.count
    }

    func failureCount(in lane: AppModel.PipelineLane) -> Int {
        items.filter { $0.lane == lane }.filter {
            if case .failed = $0.status { return true } else { return false }
        }.count
    }

    var pendingCount: Int { items.filter { !$0.status.isFinished }.count }

    var failureCount: Int {
        items.filter { if case .failed = $0.status { return true } else { return false } }.count
    }

    var isEmpty: Bool { items.isEmpty }
}

extension AppModel {
    /// Assembles the current picture of pipeline work.
    ///
    /// Order matters. Running work is added first and later sources cannot
    /// overwrite it, because the pending queue is a recomputed snapshot that
    /// still lists an episode as "waiting" while its download is halfway
    /// done — and a row that flips between Downloading and Waiting on every
    /// refresh is worse than no row.
    func activitySnapshot() async -> ActivitySnapshot {
        var snapshot = ActivitySnapshot()
        var seen: Set<String> = []

        func add(_ lane: PipelineLane, _ episode: EpisodeRecord, _ status: ActivityItem.Status) {
            let key = "\(lane.rawValue)-\(episode.id)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            snapshot.items.append(
                ActivityItem(
                    lane: lane,
                    episode: episode,
                    showTitle: showTitle(for: episode),
                    status: status
                )
            )
        }

        // 1. In flight right now.
        for (episodeID, work) in episodeWork {
            guard let episode = try? await episodes.find(id: episodeID) else { continue }
            let label = workLabel(for: episodeID) ?? "Working…"
            switch work {
            case .downloading(let fraction):
                add(.download, episode, .running(label: label, fraction: fraction))
            case .preparingSpeechModel, .transcribing:
                add(.transcript, episode, .running(label: label, fraction: nil))
            }
        }

        // 2. Ad scanning keeps its own richer state machine.
        for (episodeID, state) in scanState {
            guard let episode = try? await episodes.find(id: episodeID) else { continue }
            switch state {
            case .preparing(let step):
                add(.adScan, episode, .running(label: step, fraction: nil))
            case .scanning(let done, let total):
                add(.adScan, episode, .running(
                    label: "Scanning window \(done) of \(total)",
                    fraction: total > 0 ? Double(done) / Double(total) : nil
                ))
            case .unavailable(let reason):
                add(.adScan, episode, .failed(reason))
            case .done:
                break  // Completions carry these, with a timestamp.
            }
        }

        // 3. Sticky failures. These are what Retry exists for, and the reason
        //    the queue skips an episode on every later pass until cleared.
        for (episodeID, message) in episodeWorkErrors {
            guard let episode = try? await episodes.find(id: episodeID) else { continue }
            add(failedLane[episodeID] ?? .transcript, episode, .failed(message))
        }

        // 4. What the queue still owes.
        for work in await pendingWork() {
            if work.needsDownload { add(.download, work.episode, .waiting) }
            if work.needsTranscript { add(.transcript, work.episode, .waiting) }
            if work.needsScan { add(.adScan, work.episode, .waiting) }
        }

        // 5. Finished this session.
        for completion in recentCompletions {
            guard let episode = try? await episodes.find(id: completion.episodeID) else { continue }
            add(completion.lane, episode, .done(detail: completion.detail, at: completion.finishedAt))
        }

        return snapshot
    }

    func showTitle(for episode: EpisodeRecord) -> String {
        library.first { $0.id == episode.podcastId }?.title ?? "Unknown show"
    }

    /// Runs one lane's step for one episode, now, clearing whatever failure
    /// was blocking it. This is Retry, and it is also "do it now" for an
    /// episode still sitting in the queue — the same verb either way.
    func runLane(_ lane: PipelineLane, for episode: EpisodeRecord) async {
        clearFailure(for: episode.id)
        switch lane {
        case .download:
            _ = try? await downloadAudio(for: episode)
        case .transcript:
            await transcribeOnDevice(episode)
        case .adScan:
            await scanForAds(episode)
        }
    }

    /// Takes the item off the list without doing its work: an in-flight
    /// download is cancelled, a failure is dismissed, a finished row is
    /// cleared from the session log.
    func dismiss(_ item: ActivityItem) {
        switch item.status {
        case .running where item.lane == .download:
            cancelDownload(item.episode.id)
        case .failed:
            clearFailure(for: item.episode.id)
        case .done:
            clearCompletion(id: item.id)
        default:
            break
        }
    }
}
