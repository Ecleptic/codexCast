import CodexCastPlayback
import SwiftUI

/// Compact transport pinned above the tab bar while something plays.
/// The full player screen (timeline, chapters, segments) arrives with
/// detection; this makes listening work today.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var showNowPlaying = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                // Display time comes from the timeline, never raw player time
                // (§11.4). With no segments yet the two are equal — the point
                // is that no view ever reads the raw clock.
                Text(
                    Duration.milliseconds(model.player.displayPositionMs),
                    format: .time(pattern: .hourMinuteSecond)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs - 15_000)
            } label: {
                Image(systemName: "gobackward.15")
            }

            Button {
                if model.player.isPlaying {
                    model.player.pause()
                } else {
                    model.player.play()
                }
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }

            Button {
                model.player.seek(toMediaMs: model.player.mediaPositionMs + 30_000)
            } label: {
                Image(systemName: "goforward.30")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { showNowPlaying = true }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
