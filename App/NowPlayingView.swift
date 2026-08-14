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
        case queue = 0, player = 1, info = 2
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
                Text("Info").tag(Page.info)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .padding(.top, 10)

            TabView(selection: $page) {
                QueuePage().tag(Page.queue)
                PlayerPage().tag(Page.player)
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
                set: { model.audioSettings.autoSkipAds = $0 }
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
                positionMs: Int(positionMs)
            )
            .frame(height: 6)

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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                ForEach(segments.filter { $0.userState != .rejected }, id: \.id) { segment in
                    let start = fraction(segment.startMs) * proxy.size.width
                    let width = max(3, (fraction(segment.endMs) - fraction(segment.startMs)) * proxy.size.width)
                    Capsule()
                        .fill(color(for: segment))
                        .frame(width: width)
                        .offset(x: start)
                }

                Rectangle()
                    .fill(.primary)
                    .frame(width: 2, height: 10)
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
