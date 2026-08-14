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

        return VStack(spacing: 4) {
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
}
