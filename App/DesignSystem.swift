import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The measurements every screen shares.
///
/// They existed already — as literals, slightly different on each screen, so
/// artwork was 48pt in playlists, 52 on Home and 44 in the queue, and rows
/// that showed the same episode looked like three different components.
/// One place, so "make the rows breathe" is one edit rather than nine.
enum Metrics {
    /// Screen-edge inset for content that isn't in a grouped list.
    static let gutter: CGFloat = 16
    /// Vertical padding inside a list row.
    static let rowPadding: CGFloat = 9
    /// Gap between artwork and the text beside it.
    static let rowSpacing: CGFloat = 12
    /// Artwork in a standard episode row.
    static let rowArtwork: CGFloat = 54
    /// Artwork in a dense row: queue, pickers, activity.
    static let compactArtwork: CGFloat = 44
    /// Artwork on a shelf card.
    static let cardArtwork: CGFloat = 148

    /// Continuous corner radius, proportional to the thing it rounds — a
    /// fixed 8pt on a 148pt card reads as a square, and 14pt on a 34pt
    /// thumbnail reads as a blob.
    static func corner(for size: CGFloat) -> CGFloat {
        max(6, min(16, size * 0.16))
    }
}

/// A small capsule of state: icon, a word or two, one colour.
///
/// Every "this thing is in this condition" indicator in the app is one of
/// these, so downloaded / streaming / failed / scanned all carry the same
/// visual weight and nothing shouts louder than its importance warrants.
struct StatusChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    /// Filled chips are for states the listener acts on; plain ones are
    /// ambient facts.
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .background(
            prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
    }
}

/// Downloaded or streaming, for one episode, in a list.
///
/// Reads the file system through the model rather than `episode.localPath`:
/// the stored path outlives the file it names across app updates, so the
/// column said "downloaded" for episodes that would in fact stream.
struct DownloadStateIcon: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    var body: some View {
        let downloaded = model.isDownloaded(episode)
        Image(systemName: downloaded ? "arrow.down.circle.fill" : "cloud")
            .font(.caption2)
            .foregroundStyle(downloaded ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .accessibilityLabel(downloaded ? "Downloaded" : "Streams")
    }
}

/// What the player is actually pulling bytes from, said plainly.
///
/// The player chooses a local file over the network silently, which is
/// correct behaviour and invisible behaviour — and invisible is why "am I
/// streaming right now?" had no answer anywhere in the app.
struct PlaybackSourceChip: View {
    @Environment(AppModel.self) private var model
    /// Compact drops the word and keeps the glyph, for the mini player.
    var compact = false

    var body: some View {
        if let source = model.playbackSource {
            if compact {
                Image(systemName: source.systemImage)
                    .font(.caption2)
                    .foregroundStyle(source.isStreaming ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .accessibilityLabel(source.label)
            } else {
                StatusChip(
                    text: source.label,
                    systemImage: source.systemImage,
                    tint: source.isStreaming ? .secondary : .accentColor
                )
            }
        }
    }
}

/// Artwork for a show, at any size, with the same rounding rule everywhere.
struct ShowArtwork: View {
    let url: URL?
    let size: CGFloat
    /// Shown behind a failed or missing image.
    var fallbackText: String?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: Metrics.corner(for: size), style: .continuous)
                .fill(.quaternary)
                .overlay {
                    if let fallbackText, size >= 40 {
                        Text(fallbackText.prefix(2))
                            .font(.system(size: size * 0.3, weight: .bold))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: max(10, size * 0.28)))
                            .foregroundStyle(.tertiary)
                    }
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner(for: size), style: .continuous))
    }
}

/// The one episode row.
///
/// Home, playlists, the player queue and the activity screen all render this,
/// which is what makes invariant 7 — "every list that shows an episode shows
/// its state" — true by construction instead of by remembering. Trailing
/// content is the only thing that varies: a play button here, a retry button
/// there.
struct EpisodeRowContent<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord
    var showTitle: String?
    var artworkSize: CGFloat = Metrics.rowArtwork
    /// Replaces the date/duration line — used by Activity to say what step
    /// is running instead of when the episode was published.
    var statusLine: AnyView?
    @ViewBuilder var trailing: Trailing

    private var isPlaying: Bool { model.nowPlaying?.id == episode.id }

    /// Fraction listened, once far enough in to be worth drawing.
    private var progress: Double? {
        guard episode.playbackPositionMs > 15_000,
              let duration = episode.durationMs, duration > 0,
              !episode.isPlayed
        else { return nil }
        return min(1, Double(episode.playbackPositionMs) / Double(duration))
    }

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            ShowArtwork(url: artworkURL, size: artworkSize, fallbackText: showTitle)
                // State rides on the artwork, not in front of the title.
                // Inline glyphs shortened the title's column, so the row
                // that happened to be playing wrapped differently from every
                // other row in the same list.
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying || episode.isPlayed {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                            .padding(3)
                            .accessibilityLabel(isPlaying ? "Now playing" : "Played")
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                if let showTitle {
                    Text(showTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(episode.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                if let statusLine {
                    statusLine
                } else {
                    defaultStatusLine
                }

                if let progress {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .scaleEffect(x: 1, y: 0.55, anchor: .center)
                        .frame(height: 3)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.vertical, Metrics.rowPadding)
        .contentShape(Rectangle())
    }

    private var defaultStatusLine: some View {
        HStack(spacing: 6) {
            if let published = episode.publishedAt {
                Text(published, format: .relative(presentation: .named))
            }
            if let duration = episode.durationMs {
                Text("·").foregroundStyle(.tertiary)
                if progress != nil {
                    // Remaining, not total, once started — what you actually
                    // want to know before pressing play.
                    Text("\(max(0, duration - episode.playbackPositionMs) / 60_000) min left")
                } else {
                    Text(
                        Duration.milliseconds(duration),
                        format: .units(allowed: [.hours, .minutes], width: .narrow)
                    )
                }
            }
            DownloadStateIcon(episode: episode)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var artworkURL: URL? {
        episode.imageURL.flatMap(URL.init(string:))
            ?? model.library.first { $0.id == episode.podcastId }?
                .imageURL.flatMap(URL.init(string:))
    }
}

extension EpisodeRowContent where Trailing == EmptyView {
    init(
        episode: EpisodeRecord,
        showTitle: String? = nil,
        artworkSize: CGFloat = Metrics.rowArtwork,
        statusLine: AnyView? = nil
    ) {
        self.init(
            episode: episode,
            showTitle: showTitle,
            artworkSize: artworkSize,
            statusLine: statusLine,
            trailing: { EmptyView() }
        )
    }
}

/// The circular play button that sits at the end of a row.
struct RowPlayButton: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    var body: some View {
        Button {
            model.play(episode)
        } label: {
            Image(systemName: model.nowPlaying?.id == episode.id && model.player.isPlaying
                ? "pause.fill" : "play.fill")
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .accessibilityLabel("Play \(episode.title)")
    }
}
