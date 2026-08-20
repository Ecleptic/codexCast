import CodexCastCore
import AVKit
import CodexCastFeeds
import CodexCastPersistence
import SwiftUI

/// Episode detail: description, transcript, and (once detection lands)
/// chapters and detected segments (§12).
struct EpisodeDetailView: View {
    @Environment(AppModel.self) private var model
    let episode: EpisodeRecord

    @State private var transcript: TimedTranscript?
    @State private var segments: [DetectedSegment] = []

    enum Page: String, CaseIterable {
        case notes = "Notes"
        case transcript = "Transcript"
        case ads = "Ads"
        case info = "Info"
    }
    @State private var page: Page = .notes
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
                            // Explicit HStack: Label's icon was rendering
                            // inconsistently inside prominent button styles.
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Play")
                            }
                            .fontWeight(.semibold)
                        }
                        .buttonStyle(.glassProminent)

                        Button {
                            Task { await model.addToUpNext(episode) }
                        } label: {
                            Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .buttonStyle(.glass)

                        if model.videoURL(for: episode) != nil {
                            Button {
                                Task { await model.playVideo(episode) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("Video")
                                }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Section", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if page == .ads {
            Section("Ad Detection") {
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
                case .done(let found, let seconds):
                    Text(found == 0
                        ? "No ads found (scanned in \(seconds)s)."
                        : "Found \(found) segment\(found == 1 ? "" : "s") in \(seconds)s. They'll be skipped during playback.")
                        .font(.callout)
                case nil:
                    EmptyView()
                }

                ForEach(segments, id: \.id) { segment in
                    Button {
                        model.play(episode, startAtMs: max(0, segment.startMs - 5_000))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segmentTitle(segment)).font(.callout.weight(.medium))
                                if let rationale = segment.rationale {
                                    Text(rationale).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text("\(timestamp(segment.startMs))–\(timestamp(segment.endMs))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Always offered: the scan chains download → transcribe →
                // scan itself when steps are missing (Cam: one tap, no
                // "do the other thing first").
                if model.scanState[episode.id] == nil || segments.isEmpty {
                    Button {
                        Task {
                            await model.scanForAds(episode)
                            segments = (try? await model.segmentRepository.segments(episodeID: episode.id)) ?? []
                        }
                    } label: {
                        Label(
                            transcript == nil ? "Transcribe & Scan for Ads" : "Scan for Ads",
                            systemImage: "sparkle.magnifyingglass"
                        )
                    }
                }
            }

            }

            if page == .notes, let summary = episode.summary, !summary.isEmpty {
                Section("Show Notes") {
                    Text(summary.htmlToPlainText)
                        .font(.callout)
                }
            }

            if page == .info {
                Section("Poster") {
                    AsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            .frame(height: 240)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets())
                }
                Section("Details") {
                    if let published = episode.publishedAt {
                        LabeledContent("Published") { Text(published, style: .date) }
                    }
                    if let duration = episode.durationMs {
                        LabeledContent("Length") {
                            Text(Duration.milliseconds(duration),
                                 format: .units(allowed: [.hours, .minutes], width: .wide))
                        }
                    }
                    if let number = episode.episodeNumber {
                        LabeledContent("Episode", value: "#\(number)")
                    }
                    LabeledContent("Playback source") {
                        Text(model.isDownloaded(episode)
                            ? "Downloaded to this iPhone"
                            : "Streams over the network")
                    }
                }
            }

            if page == .transcript {
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
                } else if let work = model.episodeWork[episode.id] {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(workLabel(work)).foregroundStyle(.secondary)
                    }
                } else if isLoadingTranscript {
                    HStack {
                        ProgressView()
                        Text("Loading transcript…").foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.episodeWorkErrors[episode.id] ?? transcriptError {
                            Text(error).foregroundStyle(.orange).font(.callout)
                        }

                        if hasFeedTranscript {
                            Button("Fetch from feed") {
                                Task { await loadFeedTranscript() }
                            }
                        } else {
                            // Honest about why, and about what happens instead:
                            // only ~1 show in 11 publishes usable transcripts.
                            Text("This show doesn't publish transcripts.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }

                        Button {
                            Task { await transcribeHere() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                Text("Transcribe on this iPhone")
                            }
                        }
                        .buttonStyle(.glassProminent)

                        Text("Downloads the episode and transcribes it on-device. Audio never leaves your phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            }
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let podcast = model.library.first(where: { $0.id == episode.podcastId }) {
                NavigationLink {
                    EpisodeListView(podcast: podcast)
                } label: {
                    Label("Go to Show", systemImage: "square.stack")
                }
            }
        }
        .task {
            transcript = try? await model.transcripts.transcript(episodeID: episode.id)
            segments = (try? await model.segmentRepository.segments(episodeID: episode.id)) ?? []
            if transcript == nil, episode.feedTranscripts != nil {
                await loadFeedTranscript()
            }
        }
    }

    private var artworkURL: URL? {
        episode.imageURL.flatMap(URL.init(string:))
            ?? model.library.first { $0.id == episode.podcastId }?
                .imageURL.flatMap(URL.init(string:))
    }

    /// True only when the feed advertises at least one actual transcript —
    /// an empty stored list must not grow a button that does nothing.
    private var hasFeedTranscript: Bool {
        guard let json = episode.feedTranscripts?.data(using: .utf8),
              let references = try? JSONDecoder().decode([FeedTranscriptReference].self, from: json)
        else { return false }
        return !references.isEmpty
    }

    private func workLabel(_ work: AppModel.EpisodeWork) -> String {
        switch work {
        case .downloading: "Downloading episode…"
        case .preparingSpeechModel: "Preparing the speech model (first run only)…"
        case .transcribing: "Transcribing on this iPhone…"
        }
    }

    private func transcribeHere() async {
        await model.transcribeOnDevice(episode)
        transcript = try? await model.transcripts.transcript(episodeID: episode.id)
    }

    private func segmentTitle(_ segment: DetectedSegment) -> String {
        let kind: String
        switch segment.kind {
        case .ad: kind = "Ad"
        case .sponsorRead: kind = "Sponsor read"
        case .selfPromo: kind = "Self-promo"
        case .intro: kind = "Intro"
        case .outro: kind = "Outro"
        }
        return "\(kind) · \(Int(segment.confidence * 100))%"
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


