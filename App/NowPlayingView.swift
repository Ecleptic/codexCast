import AVKit
import CodexCastCore
import CodexCastPersistence
import CodexCastPlayback
import SwiftUI

/// The full player: three swipeable pages — Queue | Now Playing | Info —
/// the structure Overcast's cards and Pocket Casts' tabs converge on
/// (ux-architecture invariant 6).
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    enum Page: Int {
        case queue = 0, player = 1, transcript = 2, info = 3
    }
    @State private var page: Page = .player

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("Up Next").tag(Page.queue)
                Text("Playing").tag(Page.player)
                Text("Script").tag(Page.transcript)
                Text("Info").tag(Page.info)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .padding(.top, 10)

            TabView(selection: $page) {
                QueuePage().tag(Page.queue)
                PlayerPage().tag(Page.player)
                TranscriptPage().tag(Page.transcript)
                InfoPage().tag(Page.info)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .overlay(alignment: .bottom) {
            UndoSkipBanner()
        }
        .presentationDragIndicator(.visible)
        .padding(.top, 6)
        .onChange(of: router.dismissPlayerSheet) {
            if router.dismissPlayerSheet {
                router.dismissPlayerSheet = false
                dismiss()
            }
        }
    }
}

// MARK: - Center page: transport

private struct PlayerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var scrubMs: Double?
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoAttached = true

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            stage

            VStack(spacing: 6) {
                // Tap the title for episode details, the show name for the
                // show — the player is a hub, not a dead end.
                Button {
                    if let episode = model.nowPlaying {
                        router.openEpisode(episode)
                    }
                } label: {
                    Text(model.nowPlaying?.title ?? "Nothing Playing")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens episode details")

                if let show = showTitle {
                    Button {
                        if let episode = model.nowPlaying {
                            router.openShow(episode.podcastId)
                        }
                    } label: {
                        Text(show).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens show page")
                }

                sourceRow
            }
            .padding(.horizontal, 24)

            scrubber.padding(.horizontal, 24)

            transport

            HStack(spacing: 18) {
                speedMenu
                markAdControls
                sleepMenu
                audioMenu
                AirPlayButton()
                    .frame(width: 34, height: 34)
            }

            // Which of those are on, said in one quiet line rather than by
            // three full-width switches. The switches pushed the transport
            // up the screen and made the busiest control on the page — the
            // scrubber — compete with settings nobody changes twice a day.
            if !activeEffects.isEmpty {
                Text(activeEffects.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)
        }
    }

    private var showTitle: String? {
        guard let episode = model.nowPlaying else { return nil }
        return model.library.first { $0.id == episode.podcastId }?.title
    }

    /// Where the bytes are coming from, with the one-tap fix beside it.
    ///
    /// Streaming and playing a download sound identical and behave very
    /// differently — no waveform, no Smart Speed pre-analysis, nothing in a
    /// tunnel. Saying which, here, is the whole point.
    @ViewBuilder
    private var sourceRow: some View {
        if let source = model.playbackSource {
            HStack(spacing: 8) {
                PlaybackSourceChip()
                if source.isStreaming, let episode = model.nowPlaying,
                   !model.isDownloaded(episode) {
                    if case .downloading = model.episodeWork[episode.id] {
                        StatusChip(text: model.workLabel(for: episode.id) ?? "Downloading…",
                                   systemImage: "arrow.down", tint: .accentColor)
                    } else {
                        Button {
                            Task { await model.downloadNowPlaying() }
                        } label: {
                            Text("Download")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// The sound-changing switches, still reachable mid-listen — a menu, not
    /// a stack of rows. Checkmarks carry the state.
    private var audioMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { model.audioSettings.autoSkipAds },
                set: { newValue in Task { await model.setAutoSkip(newValue) } }
            )) {
                Label("Skip detected ads", systemImage: "forward.end")
            }
            Toggle(isOn: Binding(
                get: { model.audioSettings.trimSilence },
                set: { newValue in
                    model.audioSettings.trimSilence = newValue
                    model.applyAudioSettings()
                }
            )) {
                Label("Shorten silences", systemImage: "scissors")
            }
            Toggle(isOn: Binding(
                get: { model.audioSettings.voiceBoostEnabled },
                set: { newValue in
                    model.audioSettings.voiceBoostEnabled = newValue
                    model.applyAudioSettings()
                }
            )) {
                Label("Voice boost", systemImage: "waveform.badge.mic")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(activeEffects.isEmpty ? Color.primary : .accentColor)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Audio options")
    }

    private var activeEffects: [String] {
        var names: [String] = []
        if model.audioSettings.autoSkipAds { names.append("Skipping ads") }
        if model.audioSettings.trimSilence { names.append("Shortened silences") }
        if model.audioSettings.voiceBoostEnabled { names.append("Voice boost") }
        return names
    }

    /// Poster or video, in the same slot. Video is inline and native —
    /// same engine, same scrubber below it, controls layered on top the way
    /// every video app does it.
    @ViewBuilder
    private var stage: some View {
        if model.player.hasVideo, model.videoSettings.showVideoStage {
            VideoLayerView(
                // Detached in the background so audio keeps playing.
                player: videoAttached ? model.player.underlyingPlayer : nil,
                gravity: model.videoSettings.cropToFill ? .resizeAspectFill : .resizeAspect
            )
            .aspectRatio(model.videoSettings.cropToFill ? 1 : 16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12, y: 6)
            .overlay(alignment: .topTrailing) { stageControls }
            .padding(.horizontal, model.videoSettings.cropToFill ? 24 : 0)
            .onChange(of: scenePhase) { _, phase in
                videoAttached = phase == .active
            }
            .accessibilityLabel("Video")
        } else {
            artwork
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 12, y: 6)
                .overlay(alignment: .topTrailing) {
                    if model.player.hasVideo { stageControls }
                }
        }
    }

    /// Video/poster and fit/fill, floating on the stage like every video app.
    private var stageControls: some View {
        HStack(spacing: 8) {
            if model.videoSettings.showVideoStage, model.player.hasVideo {
                Button {
                    model.videoSettings.cropToFill.toggle()
                } label: {
                    Image(systemName: model.videoSettings.cropToFill
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
                .accessibilityLabel(model.videoSettings.cropToFill ? "Show whole frame" : "Crop to fill")
            }

            Button {
                model.videoSettings.showVideoStage.toggle()
            } label: {
                Image(systemName: model.videoSettings.showVideoStage ? "photo" : "play.rectangle")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .accessibilityLabel(model.videoSettings.showVideoStage ? "Show poster" : "Show video")
        }
        .padding(10)
    }

    private var artwork: some View {
        AsyncImage(url: artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var artworkURL: URL? {
        guard let episode = model.nowPlaying else { return nil }
        return episode.imageURL.flatMap(URL.init(string:))
            ?? model.library.first { $0.id == episode.podcastId }?
                .imageURL.flatMap(URL.init(string:))
    }

    private var scrubber: some View {
        let durationMs = max(1, model.player.displayDurationMs)
        let positionMs = scrubMs ?? Double(model.player.displayPositionMs)

        return VStack(spacing: 6) {
            SegmentBar(
                segments: model.nowPlayingSegments,
                durationMs: model.nowPlaying?.durationMs ?? durationMs,
                positionMs: Int(positionMs),
                waveform: model.nowPlaying.flatMap { model.waveforms[$0.id] }
            )
            .frame(height: 34)
            // The system slider insets its track by the thumb's radius; the
            // bar must match or its cursor rides ahead of the thumb.
            .padding(.horizontal, 13)
            .task(id: model.nowPlaying?.id) {
                if let episode = model.nowPlaying {
                    await model.loadWaveform(for: episode)
                }
            }

            Slider(
                value: Binding(get: { positionMs }, set: { scrubMs = $0 }),
                in: 0...Double(durationMs)
            ) { editing in
                model.player.isScrubbing = editing
                if !editing, let target = scrubMs {
                    model.player.seek(toDisplayMs: Int(target))
                    scrubMs = nil
                }
            }

            HStack {
                Text(timeString(Int(positionMs)))
                Spacer()
                Text("−" + timeString(max(0, durationMs - Int(positionMs))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs - 15_000)
            } label: {
                Image(systemName: "gobackward.15").font(.title)
            }
            .accessibilityLabel("Skip back 15 seconds")
            Button {
                model.player.isPlaying ? model.player.pause() : model.player.play()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")
            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs + 30_000)
            } label: {
                Image(systemName: "goforward.30").font(.title)
            }
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .buttonStyle(.plain)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { speed in
                Button(String(format: "%.2g×", speed)) {
                    model.audioSettings.speed = speed
                    model.applyAudioSettings()
                }
            }
        } label: {
            Text(String(format: "%.2g×", model.audioSettings.speed))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44)
        }
        .buttonStyle(.glass)
    }

    private var sleepMenu: some View {
        Menu {
            Button("End of episode") { model.setSleepAtEndOfEpisode() }
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { model.setSleepTimer(minutes: minutes) }
            }
            if model.sleepTimer != .off {
                Button("Turn Off", role: .destructive) { model.setSleepTimer(minutes: nil) }
            }
        } label: {
            Image(systemName: model.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
                .font(.title3)
                .foregroundStyle(model.sleepTimer == .off ? Color.primary : .indigo)
        }
        .buttonStyle(.glass)
    }

    private var markAdControls: some View {
        Group {
            if model.pendingAdStartMs == nil {
                Button {
                    model.markAdStart()
                } label: {
                    Image(systemName: "flag").font(.title3)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    Task { await model.markAdEnd() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.checkered")
                        Text("End ad")
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
            }
        }
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Queue page

private struct QueuePage: View {
    @Environment(AppModel.self) private var model
    @State private var queue: [EpisodeRecord] = []
    /// The playlist currently being played through, and what is left of it.
    @State private var source: (playlist: Playlist, all: [EpisodeRecord], upcoming: [EpisodeRecord])?

    var body: some View {
        List {
            if queue.isEmpty && (source?.upcoming.isEmpty ?? true) {
                ContentUnavailableView(
                    "Queue is Empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Swipe an episode left and choose Play Next.")
                )
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(queue, id: \.id) { episode in
                    Button { model.play(episode) } label: { QueueRow(episode: episode) }
                        .buttonStyle(.plain)
                }
                .onMove { indices, destination in
                    queue.move(fromOffsets: indices, toOffset: destination)
                    let ids = queue.map(\.id)
                    Task {
                        if let playlist = upNextPlaylist {
                            await model.reorderPlaylist(playlist.id, episodeIDs: ids)
                        }
                    }
                }
                .onDelete { indices in
                    let removing = indices.map { queue[$0] }
                    queue.remove(atOffsets: indices)
                    Task {
                        guard let playlist = upNextPlaylist else { return }
                        for episode in removing {
                            try? await model.playlistRepository.remove(
                                episodeID: episode.id, from: playlist.id
                            )
                        }
                    }
                }
            } header: {
                if !queue.isEmpty { Text("Up Next") }
            }

            // What the playlist plays next, once hand-queued episodes run
            // out — the same order advanceQueue uses, shown rather than
            // guessed at.
            if let source, !source.upcoming.isEmpty {
                Section("From \(source.playlist.name)") {
                    ForEach(source.upcoming, id: \.id) { episode in
                        Button {
                            model.play(episode, from: source.playlist, ordered: source.all)
                        } label: {
                            QueueRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .deleteDisabled(true)
                        .moveDisabled(true)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        // Same reason: advancing removes the finished episode from the queue.
        .task(id: model.nowPlaying?.id) { await reload() }
    }

    private var upNextPlaylist: Playlist? {
        model.playlists.first { $0.name == Playlist.upNextName }
    }

    private func reload() async {
        if let playlist = upNextPlaylist {
            queue = await model.episodes(in: playlist)
        }
        source = await model.playbackQueueContents()
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    var body: some View {
        EpisodeRowContent(
            episode: episode,
            showTitle: model.library.first { $0.id == episode.podcastId }?.title,
            artworkSize: Metrics.compactArtwork
        )
    }
}

// MARK: - Info page: chapters + show notes + detected segments

private struct InfoPage: View {
    @Environment(AppModel.self) private var model
    @State private var chapters: [Chapter] = []

    var body: some View {
        List {
            if !chapters.isEmpty {
                Section("Chapters") {
                    ForEach(chapters, id: \.id) { chapter in
                        Button {
                            model.player.seek(toMediaMs: chapter.startMs)
                        } label: {
                            HStack {
                                Text(chapter.title).font(.callout)
                                Spacer()
                                Text(timeString(chapter.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if chapter.source == .generated {
                                    Image(systemName: "sparkles").font(.caption2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let episode = model.nowPlaying {
                Section("Detected Ads") {
                    if model.nowPlayingSegments.isEmpty {
                        switch model.scanState[episode.id] {
                        case .preparing(let step):
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(model.workLabel(for: episode.id) ?? step)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        case .scanning(let done, let total):
                            HStack(spacing: 10) {
                                ProgressView(value: Double(done), total: Double(max(1, total)))
                                Text("\(done)/\(total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        case .unavailable(let reason):
                            Text(reason).foregroundStyle(.orange).font(.callout)
                        default:
                            Text("No ads detected yet.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            Button {
                                Task {
                                    await model.scanForAds(episode)
                                    await model.refreshNowPlayingSegments()
                                }
                            } label: {
                                Label("Scan for Ads", systemImage: "sparkle.magnifyingglass")
                            }
                        }
                    }
                    ForEach(model.nowPlayingSegments, id: \.id) { segment in
                        SegmentReviewRow(segment: segment, episode: episode)
                    }
                }
            }

            if let notes = model.nowPlaying?.summary, !notes.isEmpty {
                Section("Show Notes") {
                    Text(notes.htmlToPlainText).font(.callout)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if chapters.isEmpty && model.nowPlayingSegments.isEmpty
                && (model.nowPlaying?.summary ?? "").isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "doc.text")
            }
        }
        // id: — the player sheet outlives the episode. Without it, Script
        // and Info kept showing the PREVIOUS episode after auto-advance.
        .task(id: model.nowPlaying?.id) {
            guard let episode = model.nowPlaying else { return }
            chapters = await model.loadChapters(for: episode)
        }
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A detected segment with confirm/reject — §6.4's verbs where the listener is.
struct SegmentReviewRow: View {
    @Environment(AppModel.self) private var model
    let segment: DetectedSegment
    let episode: EpisodeRecord
    @State private var showAdjust = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text("\(timeString(segment.startMs))–\(timeString(segment.endMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch segment.userState {
            case .confirmed:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .rejected:
                Image(systemName: "xmark.seal").foregroundStyle(.secondary)
            case .adjusted:
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.player.seek(toMediaMs: max(0, segment.startMs - 5_000))
            } label: {
                Label("Listen", systemImage: "play")
            }
            .tint(.accentColor)
            Button {
                Task { await model.confirmSegment(segment, episode: episode) }
            } label: {
                Label("It's an ad", systemImage: "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Full swipe = "not an ad": the correction Cam reaches for most,
            // and the one whose custom button silently did nothing.
            Button {
                Task { await model.rejectSegment(segment, episode: episode) }
            } label: {
                Label("Not an ad", systemImage: "xmark")
            }
            .tint(.orange)
            Button(role: .destructive) {
                Task { await model.deleteSegment(segment) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                Task { await model.rejectSegment(segment, episode: episode) }
            } label: {
                Label("Not an Ad", systemImage: "xmark.circle")
            }
            Button {
                Task { await model.confirmSegment(segment, episode: episode) }
            } label: {
                Label("Confirm as Ad", systemImage: "checkmark.circle")
            }
            Button {
                showAdjust = true
            } label: {
                Label("Adjust Boundaries…", systemImage: "arrow.left.and.right")
            }
            Button {
                Task { await model.alwaysSkipPosition(segment, episode: episode) }
            } label: {
                Label("Always Skip This Position", systemImage: "pin.slash")
            }
            if segment.startMs < 120_000 {
                Button {
                    Task { await model.neverSkipIntro(segment, episode: episode) }
                } label: {
                    Label("Never Skip This Show's Intro", systemImage: "hand.raised")
                }
            }
            Button(role: .destructive) {
                Task { await model.deleteSegment(segment) }
            } label: {
                Label("Delete Segment", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showAdjust) {
            SegmentAdjustSheet(segment: segment, episode: episode)
        }
    }

    private var label: String {
        let kind: String = switch segment.kind {
        case .ad: "Ad"
        case .sponsorRead: "Sponsor read"
        case .selfPromo: "Self-promo"
        case .intro: "Intro"
        case .outro: "Outro"
        }
        return "\(kind) · \(Int(segment.confidence * 100))%"
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Undo banner (§11.2)

/// "Skipped 68s — Undo", visible for the engine's 8-second undo window. One
/// tap, at exactly the moment the listener noticed — the most important
/// correction entry point in the app.
struct UndoSkipBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let skip = model.lastSkip {
            HStack(spacing: 12) {
                Image(systemName: "forward.fill")
                Text("Skipped \(skip.block.durationMs / 1000)s")
                    .font(.callout.weight(.medium))
                Button("Undo") {
                    model.undoLastSkip()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Segment bar (unchanged behavior)

struct SegmentBar: View {
    let segments: [DetectedSegment]
    let durationMs: Int
    let positionMs: Int
    /// Normalized peaks for downloaded episodes; nil falls back to a flat bar.
    var waveform: [Float]? = nil

    /// §11.3: the one place custom drawing is sanctioned, which is exactly why
    /// it must carry an accessible representation of the segments.
    private var accessibilitySummary: String {
        let active = segments.filter { $0.userState != .rejected }
        guard !active.isEmpty else { return "No detected segments" }
        let parts = active.map { segment in
            let kind = switch segment.kind {
            case .ad: "ad"
            case .sponsorRead: "sponsor read"
            case .selfPromo: "self promotion"
            case .intro: "intro"
            case .outro: "outro"
            }
            return "\(kind) from \(spoken(segment.startMs)) to \(spoken(segment.endMs))"
        }
        return "Detected segments: " + parts.joined(separator: "; ")
    }

    private func spoken(_ ms: Int) -> String {
        let total = ms / 1000
        return "\(total / 60) minutes \(total % 60) seconds"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let waveform, !waveform.isEmpty {
                    // The episode's actual shape, with ad regions tinted in
                    // place — the same way Cam found a hidden ad by eye.
                    WaveformShape(peaks: waveform)
                        .fill(.quaternary)
                    WaveformShape(peaks: waveform)
                        .fill(.tint.opacity(0.55))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: fraction(positionMs) * proxy.size.width)
                        }
                    ForEach(segments.filter { $0.userState != .rejected }, id: \.id) { segment in
                        let start = fraction(segment.startMs) * proxy.size.width
                        let width = max(3, (fraction(segment.endMs) - fraction(segment.startMs)) * proxy.size.width)
                        WaveformShape(peaks: waveform)
                            .fill(color(for: segment))
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: width).offset(x: start)
                            }
                    }
                } else {
                    Capsule().fill(.quaternary).frame(height: 6).offset(y: proxy.size.height / 2 - 3)
                    ForEach(segments.filter { $0.userState != .rejected }, id: \.id) { segment in
                        let start = fraction(segment.startMs) * proxy.size.width
                        let width = max(3, (fraction(segment.endMs) - fraction(segment.startMs)) * proxy.size.width)
                        Capsule()
                            .fill(color(for: segment))
                            .frame(width: width, height: 6)
                            .offset(x: start, y: proxy.size.height / 2 - 3)
                    }
                }

                Rectangle()
                    .fill(.primary)
                    .frame(width: 2)
                    .offset(x: fraction(positionMs) * proxy.size.width - 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode timeline")
        .accessibilityValue(accessibilitySummary)
    }

    private func fraction(_ ms: Int) -> CGFloat {
        guard durationMs > 0 else { return 0 }
        return CGFloat(min(max(0, ms), durationMs)) / CGFloat(durationMs)
    }

    private func color(for segment: DetectedSegment) -> Color {
        let base: Color = switch segment.kind {
        case .ad, .sponsorRead: .orange
        case .selfPromo: .purple
        case .intro, .outro: .teal
        }
        return segment.userState == .confirmed ? base : base.opacity(0.45)
    }
}


/// Mirrored bar waveform, one bar per peak bin.
struct WaveformShape: Shape {
    let peaks: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty else { return path }
        let barWidth = rect.width / CGFloat(peaks.count)
        let gap = barWidth * 0.25
        let midY = rect.midY

        for (index, peak) in peaks.enumerated() {
            let height = max(2, CGFloat(peak) * rect.height * 0.95)
            let x = CGFloat(index) * barWidth
            path.addRoundedRect(
                in: CGRect(x: x, y: midY - height / 2, width: barWidth - gap, height: height),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}

// MARK: - Transcript page (the "Script" tab)

/// The live transcript: current line highlighted and kept in view, any line
/// tappable to seek — the labeler's fastest navigation, inside the player.
private struct TranscriptPage: View {
    @Environment(AppModel.self) private var model
    @State private var transcript: TimedTranscript?

    var body: some View {
        Group {
            if let transcript {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, cue in
                            Button {
                                model.player.seek(toMediaMs: cue.startMs)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(timeString(cue.startMs))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    Text(cue.text)
                                        .font(.callout)
                                        .foregroundStyle(isCurrent(cue) ? .primary : .secondary)
                                        .fontWeight(isCurrent(cue) ? .semibold : .regular)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: model.player.mediaPositionMs) {
                        guard let index = currentIndex(in: transcript) else { return }
                        withAnimation { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            } else if let episode = model.nowPlaying,
                      let work = model.episodeWork[episode.id] {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(workDescription(work)).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "No Transcript Yet",
                        systemImage: "text.quote",
                        description: Text("Transcription happens on this iPhone. Audio never leaves your phone.")
                    )
                    Button {
                        Task {
                            guard let episode = model.nowPlaying else { return }
                            await model.transcribeOnDevice(episode)
                            transcript = try? await model.transcripts.transcript(episodeID: episode.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                            Text("Transcribe This Episode")
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .task(id: model.nowPlaying?.id) {
            guard let episode = model.nowPlaying else { return }
            transcript = try? await model.transcripts.transcript(episodeID: episode.id)
        }
    }

    private func workDescription(_ work: AppModel.EpisodeWork) -> String {
        switch work {
        case .downloading: "Downloading episode…"
        case .preparingSpeechModel: "Preparing the speech model…"
        case .transcribing: "Transcribing on this iPhone…"
        }
    }

    private func isCurrent(_ cue: TimedTranscript.Segment) -> Bool {
        let position = model.player.mediaPositionMs
        return cue.startMs <= position && position < cue.endMs
    }

    private func currentIndex(in transcript: TimedTranscript) -> Int? {
        let position = model.player.mediaPositionMs
        return transcript.segments.lastIndex { $0.startMs <= position }
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
