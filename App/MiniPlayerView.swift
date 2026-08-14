import CodexCastPlayback
import SwiftUI

/// Compact transport pinned above the tab bar while something plays.
/// The full player screen (timeline, chapters, segments) arrives with
/// detection; this makes listening work today.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var showNowPlaying = false

    var body: some View {
        // Inline (tab bar minimized): just title and play — the system gives
        // us a narrow strip. Expanded: full transport.
        HStack(spacing: placement == .inline ? 10 : 16) {
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

            if placement != .inline {
                Button {
                    model.player.seek(toMediaMs: model.player.mediaPositionMs - 15_000)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .accessibilityLabel("Skip back 15 seconds")
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
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            if placement != .inline {
                Button {
                    model.player.seek(toMediaMs: model.player.mediaPositionMs + 30_000)
                } label: {
                    Image(systemName: "goforward.30")
                }
                .accessibilityLabel("Skip forward 30 seconds")
            }
        }
        .padding(.horizontal, 14)
        // No background: the accessory itself is the Liquid Glass surface —
        // painting .bar over it is what made it look flat and gray.
        .contentShape(Rectangle())
        .onTapGesture { showNowPlaying = true }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
