import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The three pipeline queues, in one place, with the verbs to act on them.
///
/// Before this, "is anything happening?" was answered by a single line in
/// Settings that said "3 episodes" and nothing else — no way to see which
/// three, no way to retry the one that failed, no way to reach the setting
/// that put them there. Downloads, transcripts and ad scans get their own
/// lane because they fail for different reasons and are configured in
/// different places.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot = ActivitySnapshot()
    @State private var lane: AppModel.PipelineLane = .download

    private var items: [ActivityItem] { snapshot.items(in: lane) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The lane filter is chrome, not content: pinned above the
                // list so it stays put while rows scroll, and so switching
                // lanes doesn't require finding it again.
                lanePicker

                List {
                    summary

                if items.isEmpty {
                    Section {
                        emptyLane
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            ActivityRow(item: item, onNavigate: { open(item) })
                        }
                    } header: {
                        Text(lane.title)
                    } footer: {
                        Text(laneFooter)
                    }
                }

                    laneSettings
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear Finished", systemImage: "eraser") {
                        model.clearCompletions(lane: lane)
                        Task { await reload() }
                    }
                    .disabled(!items.contains { $0.status.isFinished })
                }
            }
            .refreshable {
                model.invalidatePendingWork()
                await reload()
            }
            // Progress moves continuously and none of it is @Observable state
            // this view reads directly, so it polls. One second is slower than
            // the eye notices and cheap enough to run while the sheet is up;
            // the loop dies with the view.
            .task {
                while !Task.isCancelled {
                    await reload()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: - Header

    private var summary: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(snapshot.failureCount > 0
                            ? AnyShapeStyle(Color.orange.opacity(0.15))
                            : AnyShapeStyle(.tint.opacity(0.15)))
                        .frame(width: 44, height: 44)
                    if model.isDrainingQueue {
                        ProgressView()
                    } else {
                        Image(systemName: snapshot.failureCount > 0
                            ? "exclamationmark.triangle.fill" : "checkmark")
                            .font(.headline)
                            .foregroundStyle(snapshot.failureCount > 0
                                ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                    Text(subhead)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isDrainingQueue {
                    Button("Pause") { model.suspendQueue() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                } else {
                    Button("Run Now") { model.drainQueue() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .disabled(snapshot.activeCount == 0)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Work runs while Codex Cast is open. Downloads run a few at a time; transcription and ad scanning run one at a time, newest episode first.")
        }
    }

    /// Says what is true, in priority order. A failure is not "waiting" —
    /// it will sit there forever until someone retries it, and calling it
    /// waiting is how a stuck queue looks healthy.
    private var headline: String {
        let active = snapshot.activeCount
        if model.isDrainingQueue && active > 0 {
            return "Working through \(active) item\(active == 1 ? "" : "s")"
        }
        if active > 0 {
            return "\(active) item\(active == 1 ? "" : "s") waiting"
        }
        if snapshot.failureCount > 0 {
            let count = snapshot.failureCount
            return "\(count) item\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") a retry"
        }
        return "All caught up"
    }

    private var subhead: String {
        if snapshot.failureCount > 0 && snapshot.activeCount > 0 {
            return "\(snapshot.failureCount) also need\(snapshot.failureCount == 1 ? "s" : "") a retry"
        }
        if snapshot.failureCount > 0 {
            return "Swipe a row, or tap the arrow, to try again"
        }
        if let last = model.lastRefreshedAt {
            return "Feeds checked \(last.formatted(.relative(presentation: .named)))"
        }
        return "Feeds not checked yet"
    }

    private var lanePicker: some View {
        Picker("Lane", selection: $lane) {
            ForEach(AppModel.PipelineLane.allCases) { lane in
                Text(laneTab(lane)).tag(lane)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }

    /// The tab keeps its count, so the lane that needs attention is visible
    /// without opening it.
    private func laneTab(_ lane: AppModel.PipelineLane) -> String {
        let pending = snapshot.pendingCount(in: lane)
        return pending > 0 ? "\(lane.title) (\(pending))" : lane.title
    }

    // MARK: - Lane body

    @ViewBuilder
    private var emptyLane: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: lane.systemImage)
        } description: {
            Text(emptyMessage)
        } actions: {
            NavigationLink("Show Defaults") { DefaultShowSettingsView() }
        }
    }

    private var emptyTitle: String {
        switch lane {
        case .download: "No Downloads Queued"
        case .transcript: "No Transcripts Queued"
        case .adScan: "No Scans Queued"
        }
    }

    private var emptyMessage: String {
        switch lane {
        case .download:
            "Turn on auto-download for a show, or download any episode from its row menu."
        case .transcript:
            "Transcription happens on this iPhone. Turn it on per show, or transcribe one episode from its detail page."
        case .adScan:
            "Scanning transcribes on its way through, so one tap is enough. Turn it on per show."
        }
    }

    private var laneFooter: String {
        switch lane {
        case .download:
            "Swipe a row for its actions. Cancelling a download leaves the episode streamable."
        case .transcript:
            "Audio never leaves your phone. A failed transcript stops retrying so it can't starve the queue — retry it here."
        case .adScan:
            "Scanning needs Apple Intelligence. Segments are drawn on the seek bar whether or not auto-skip is on."
        }
    }

    // MARK: - Settings for this lane

    @ViewBuilder
    private var laneSettings: some View {
        Section("Settings") {
            switch lane {
            case .download:
                NavigationLink("Auto-Download by Show") { DefaultShowSettingsView() }
                NavigationLink("Storage") { StorageView() }
                NavigationLink("Episode Limits") { EpisodeLimitsView() }
            case .transcript:
                NavigationLink("Auto-Transcribe by Show") { DefaultShowSettingsView() }
            case .adScan:
                Toggle("Skip detected ads automatically", isOn: Binding(
                    get: { model.audioSettings.autoSkipAds },
                    set: { newValue in Task { await model.setAutoSkip(newValue) } }
                ))
                NavigationLink("Auto-Scan by Show") { DefaultShowSettingsView() }
                NavigationLink("Learned Patterns") { PatternsView() }
                NavigationLink("Sponsors") { SponsorsView() }
            }
        }
    }

    // MARK: -

    private func open(_ item: ActivityItem) {
        dismiss()
        router.openEpisode(item.episode)
    }

    private func reload() async {
        snapshot = await model.activitySnapshot()
    }
}

/// One episode in one lane, with everything you can do about it.
private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let item: ActivityItem
    var onNavigate: () -> Void

    var body: some View {
        EpisodeRowContent(
            episode: item.episode,
            showTitle: item.showTitle,
            artworkSize: Metrics.compactArtwork,
            statusLine: AnyView(statusLine)
        ) {
            trailing
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canRun {
                Button {
                    Task { await model.runLane(item.lane, for: item.episode) }
                } label: {
                    Label(runTitle, systemImage: runIcon)
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canDismiss {
                Button(role: .destructive) {
                    model.dismiss(item)
                } label: {
                    Label(dismissTitle, systemImage: dismissIcon)
                }
            }
        }
        .contextMenu {
            if canRun {
                Button {
                    Task { await model.runLane(item.lane, for: item.episode) }
                } label: {
                    Label(runTitle, systemImage: runIcon)
                }
            }
            Button(action: onNavigate) {
                Label("Episode Details", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                model.play(item.episode)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            if model.isDownloaded(item.episode) {
                Button(role: .destructive) {
                    Task { await model.deleteDownload(item.episode) }
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            }
            if canDismiss {
                Button(role: .destructive) {
                    model.dismiss(item)
                } label: {
                    Label(dismissTitle, systemImage: dismissIcon)
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .waiting:
            HStack(spacing: 5) {
                Image(systemName: "clock")
                Text("Waiting")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .running(let label, let fraction):
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(height: 3)
                } else {
                    // An indeterminate bar, not a spinner: it lines up with
                    // the determinate rows above and below it instead of
                    // making the list jump.
                    ProgressView().progressViewStyle(.linear)
                        .frame(height: 3)
                }
            }

        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)

        case .done(let detail, let at):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text(detail ?? "Done")
                Text("·").foregroundStyle(.tertiary)
                Text(at, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .failed:
            Button {
                Task { await model.runLane(item.lane, for: item.episode) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel("Retry \(item.lane.verb.lowercased()) for \(item.episode.title)")
        case .waiting:
            Button {
                Task { await model.runLane(item.lane, for: item.episode) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel("Do this now")
        case .running where item.lane == .download:
            Button {
                model.cancelDownload(item.episode.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel("Cancel download")
        default:
            EmptyView()
        }
    }

    // MARK: - Verbs

    private var canRun: Bool {
        switch item.status {
        case .running: false
        default: true
        }
    }

    private var runTitle: String {
        switch item.status {
        case .failed: "Retry"
        case .done: "Run Again"
        default: "Do It Now"
        }
    }

    private var runIcon: String {
        if case .failed = item.status { return "arrow.clockwise" }
        return item.lane.systemImage
    }

    private var canDismiss: Bool {
        switch item.status {
        case .waiting: false
        case .running: item.lane == .download
        default: true
        }
    }

    private var dismissTitle: String {
        switch item.status {
        case .running: "Cancel"
        case .failed: "Dismiss"
        default: "Clear"
        }
    }

    private var dismissIcon: String {
        if case .running = item.status { return "xmark.circle" }
        return "eraser"
    }
}

/// The Home toolbar's way in: one glyph that says whether the phone is busy,
/// how much it still owes, and whether anything failed — without opening it.
struct ActivityToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var pending = 0
    @State private var failures = 0

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ZStack(alignment: .topTrailing) {
                // One steady glyph. The badge and its colour carry the
                // state; an animating toolbar icon just pulls the eye.
                Image(systemName: "tray.full")
                    .foregroundStyle(failures > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))

                if pending > 0 {
                    Text(pending > 99 ? "99+" : "\(pending)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(failures > 0 ? Color.orange : Color.accentColor, in: Capsule())
                        .offset(x: 10, y: -8)
                }
            }
        }
        .accessibilityLabel(label)
        // Cheap and periodic: the badge is glanceable state, not a live
        // readout, so five seconds is plenty and keeps Home off the
        // database on every frame.
        .task {
            while !Task.isCancelled {
                let snapshot = await model.activitySnapshot()
                pending = snapshot.pendingCount
                failures = snapshot.failureCount
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var label: String {
        if failures > 0 { return "Activity — \(failures) failed" }
        if pending > 0 { return "Activity — \(pending) waiting" }
        return "Activity"
    }
}
