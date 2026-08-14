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

    enum Page: Int {
        case queue = 0, player = 1, transcript = 2, info = 3
    }
    @State private var page: Page = .player

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 38, height: 5)
                .padding(.top, 10)

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
    }
}

// MARK: - Center page: transport

private struct PlayerPage: View {
    @Environment(AppModel.self) private var model
    @State private var scrubMs: Double?

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            artwork
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 12, y: 6)

            VStack(spacing: 6) {
                Text(model.nowPlaying?.title ?? "Nothing Playing")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let show = showTitle {
                    Text(show).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            scrubber.padding(.horizontal, 24)

            transport

            HStack(spacing: 20) {
                speedMenu
                markAdControls
                sleepMenu
                AirPlayButton()
                    .frame(width: 34, height: 34)
            }

            Toggle(isOn: Binding(
                get: { model.audioSettings.autoSkipAds },
                set: { newValue in Task { await model.setAutoSkip(newValue) } }
            )) {
                Text("Skip detected ads automatically").font(.callout)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 8)
        }
    }

    private var showTitle: String? {
        guard let episode = model.nowPlaying else { return nil }
        return model.library.first { $0.id == episode.podcastId }?.title
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
            .task {
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
            Button {
                model.player.isPlaying ? model.player.pause() : model.player.play()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs + 30_000)
            } label: {
                Image(systemName: "goforward.30").font(.title)
            }
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
        .buttonStyle(.bordered)
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
        .buttonStyle(.bordered)
    }

    private var markAdControls: some View {
        Group {
            if model.pendingAdStartMs == nil {
                Button {
                    model.markAdStart()
                } label: {
                    Image(systemName: "flag").font(.title3)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await model.markAdEnd() }
                } label: {
                    Label("End ad", systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
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

    var body: some View {
        List {
            if queue.isEmpty {
                ContentUnavailableView(
                    "Queue is Empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Swipe an episode left and choose Play Next.")
                )
                .listRowSeparator(.hidden)
            }
            ForEach(queue, id: \.id) { episode in
                Button {
                    model.play(episode)
                } label: {
                    HStack(spacing: 10) {
                        EpisodeArtwork(episode: episode, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title).font(.subheadline).lineLimit(2)
                            if let duration = episode.durationMs {
                                Text(Duration.milliseconds(duration),
                                     format: .units(allowed: [.hours, .minutes], width: .narrow))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .task { await reload() }
    }

    private var upNextPlaylist: Playlist? {
        model.playlists.first { $0.name == Playlist.upNextName }
    }

    private func reload() async {
        guard let playlist = upNextPlaylist else { return }
        queue = await model.episodes(in: playlist)
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

            if !model.nowPlayingSegments.isEmpty, let episode = model.nowPlaying {
                Section("Detected Segments") {
                    ForEach(model.nowPlayingSegments, id: \.id) { segment in
                        SegmentReviewRow(segment: segment, episode: episode)
                    }
                }
            }

            if let notes = model.nowPlaying?.summary, !notes.isEmpty {
                Section("Show Notes") {
                    Text(notes.strippingHTMLTags).font(.callout)
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
        .task {
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
            default:
                Button {
                    Task { await model.confirmSegment(segment, episode: episode) }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .tint(.green)
                Button {
                    Task { await model.rejectSegment(segment, episode: episode) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.player.seek(toMediaMs: max(0, segment.startMs - 5_000))
            } label: {
                Label("Listen", systemImage: "play")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await model.deleteSegment(segment) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await model.deleteSegment(segment) }
            } label: {
                Label("Delete Segment", systemImage: "trash")
            }
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
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

extension String {
    /// Display-only HTML cleanup, shared by notes surfaces.
    var strippingHTMLTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            } else {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.quote",
                    description: Text("Transcribe this episode from its detail page.")
                )
            }
        }
        .task {
            guard let episode = model.nowPlaying else { return }
            transcript = try? await model.transcripts.transcript(episodeID: episode.id)
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
