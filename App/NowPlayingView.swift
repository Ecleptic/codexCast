import CodexCastCore
import CodexCastPersistence
import CodexCastPlayback
import SwiftUI

/// The full player screen (§12): artwork, scrubber, transport, speed.
/// Opens from the mini player. The segment timeline (§11.3) joins this screen
/// when detection lands — the layout leaves it room.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Local scrub position while the finger is down, in display time.
    @State private var scrubMs: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Spacer(minLength: 0)

            artwork
                .frame(maxWidth: 320, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 12, y: 6)

            VStack(spacing: 6) {
                Text(model.nowPlaying?.title ?? "Nothing Playing")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let show = showTitle {
                    Text(show)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            scrubber
                .padding(.horizontal, 24)

            transport

            speedControl

            markAdControls

            Toggle(isOn: Binding(
                get: { model.audioSettings.autoSkipAds },
                set: { model.audioSettings.autoSkipAds = $0 }
            )) {
                Text("Skip detected ads automatically")
                    .font(.callout)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 12)
        }
        .presentationDragIndicator(.hidden)
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
        let episodeArt = episode.imageURL.flatMap(URL.init(string:))
        let showArt = model.library.first { $0.id == episode.podcastId }?
            .imageURL.flatMap(URL.init(string:))
        return episodeArt ?? showArt
    }

    // MARK: - Scrubber

    /// Positions are display time throughout (§11.4): the scrubber can never
    /// land inside a skipped region, because DisplayTimeline maps around them.
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
                value: Binding(
                    get: { positionMs },
                    set: { scrubMs = $0 }
                ),
                in: 0...Double(durationMs)
            ) { editing in
                model.player.isScrubbing = editing
                if !editing, let target = scrubMs {
                    model.player.seek(toDisplayMs: Int(target))
                    scrubMs = nil
                }
            }

            HStack {
                Text(time(Int(positionMs)))
                Spacer()
                Text("−" + time(max(0, durationMs - Int(positionMs))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 44) {
            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs - 15_000)
            } label: {
                Image(systemName: "gobackward.15").font(.title)
            }

            Button {
                if model.player.isPlaying {
                    model.player.pause()
                } else {
                    model.player.play()
                }
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }

            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs + 30_000)
            } label: {
                Image(systemName: "goforward.30").font(.title)
            }
        }
        .buttonStyle(.plain)
    }

    private var speedControl: some View {
        HStack(spacing: 14) {
            ForEach([1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { speed in
                Button(String(format: speed == floor(speed) ? "%.0f×" : "%.1f×", speed)) {
                    model.audioSettings.speed = speed
                    model.applyAudioSettings()
                }
                .font(.callout.monospacedDigit())
                .buttonStyle(.bordered)
                .tint(model.audioSettings.speed == speed ? .accentColor : .secondary)
            }
        }
    }

    private func time(_ ms: Int) -> String {
        let total = ms / 1000
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Teaching (§6.4)

    /// One tap at the moment an ad starts, one when it ends. The marked span
    /// becomes a confirmed segment and a learned pattern for this show.
    private var markAdControls: some View {
        HStack(spacing: 12) {
            if model.pendingAdStartMs == nil {
                Button {
                    model.markAdStart()
                } label: {
                    Label("Ad starts here", systemImage: "flag")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await model.markAdEnd() }
                } label: {
                    Label("Ad ends here", systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Cancel") {
                    model.cancelAdMark()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// The seek bar's segment overlay: detected regions drawn in place, like
/// YouTube chapter markers. Confirmed segments are solid; unreviewed model
/// output is translucent; rejected ones vanish.
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

                // Playhead tick.
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
