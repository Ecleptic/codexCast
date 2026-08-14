import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Episode detail: description, transcript, and (once detection lands)
/// chapters and detected segments (§12).
struct EpisodeDetailView: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    @State private var transcript: TimedTranscript?
    @State private var isLoadingTranscript = false
    @State private var transcriptError: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.title).font(.title3.bold())
                    HStack(spacing: 10) {
                        if let published = episode.publishedAt {
                            Text(published, style: .date)
                        }
                        if let duration = episode.durationMs {
                            Text(
                                Duration.milliseconds(duration),
                                format: .units(allowed: [.hours, .minutes], width: .narrow)
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            model.play(episode)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await model.addToUpNext(episode) }
                        } label: {
                            Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            if let summary = episode.summary, !summary.isEmpty {
                Section("Description") {
                    Text(summary.strippingHTML)
                        .font(.callout)
                }
            }

            Section("Transcript") {
                if let transcript {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, cue in
                        Button {
                            // Tapping a line seeks there — the fastest way to
                            // navigate an episode, and the same interaction the
                            // Phase 0 labeler proved out.
                            model.play(episode, startAtMs: cue.startMs)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(timestamp(cue.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let speaker = cue.speaker {
                                        Text(speaker)
                                            .font(.caption.bold())
                                            .foregroundStyle(.tint)
                                    }
                                    Text(cue.text).font(.callout)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else if isLoadingTranscript {
                    HStack {
                        ProgressView()
                        Text("Loading transcript…").foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(transcriptError ?? "No transcript yet.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        if episode.feedTranscripts != nil {
                            Button("Fetch from feed") {
                                Task { await loadFeedTranscript() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            transcript = try? await model.transcripts.transcript(episodeID: episode.id)
            if transcript == nil, episode.feedTranscripts != nil {
                await loadFeedTranscript()
            }
        }
    }

    private func timestamp(_ ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The §8.2 fast path: a feed-supplied transcript costs one download and
    /// skips on-device transcription entirely.
    private func loadFeedTranscript() async {
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }
        do {
            transcript = try await model.loadFeedTranscript(for: episode)
        } catch {
            transcriptError = "Couldn't load this episode's transcript."
        }
    }
}

private extension String {
    /// Feed descriptions are HTML; this is display-only cleanup, not parsing.
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
