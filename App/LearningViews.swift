import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import SwiftUI

/// The learned pattern library (§12 "Patterns"): every ad script the app has
/// been taught, with its track record, deletable. This screen is what makes
/// the learning legible — and legibility is what builds trust in the skipping.
struct PatternsView: View {
    @Environment(AppModel.self) private var model
    @State private var patterns: [AdPatternRecord] = []

    var body: some View {
        List {
            if patterns.isEmpty {
                ContentUnavailableView(
                    "Nothing Learned Yet",
                    systemImage: "brain",
                    description: Text("Mark ads during playback and their scripts appear here.")
                )
                .listRowSeparator(.hidden)
            }
            ForEach(patterns, id: \.id) { pattern in
                VStack(alignment: .leading, spacing: 4) {
                    Text(pattern.text)
                        .font(.callout)
                        .lineLimit(3)
                    HStack(spacing: 10) {
                        Label("\(pattern.confirmCount)", systemImage: "checkmark.circle")
                        if pattern.falsePositiveCount > 0 {
                            Label("\(pattern.falsePositiveCount)", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                        Text(showName(for: pattern))
                        Spacer()
                        Text(pattern.createdAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task {
                            try? await model.database.write { db in
                                _ = try AdPatternRecord.deleteOne(db, key: pattern.id)
                            }
                            await reload()
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Learned Patterns")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func showName(for pattern: AdPatternRecord) -> String {
        guard let id = pattern.podcastId else { return "All shows" }
        return model.library.first { $0.id == id }?.title ?? "One show"
    }

    private func reload() async {
        patterns = (try? await model.patternRepository.all()) ?? []
    }
}

/// The sponsor registry (§6.2, §12 "Sponsors"): who advertises, where, how
/// often — aggregated from show-notes hints across subscribed episodes plus
/// sponsors named on marked segments.
struct SponsorsView: View {
    @Environment(AppModel.self) private var model

    struct Entry: Identifiable {
        var id: String { name }
        var name: String
        var shows: Set<String>
        var occurrences: Int
        var promoCodes: Set<String>
    }

    @State private var entries: [Entry] = []
    @State private var isLoading = true

    /// Registry entries — sponsors the detector has actually heard and the
    /// listener confirmed (§6.2), distinct from show-notes hints below.
    @State private var learned: [(record: SponsorRecord, shows: Set<String>)] = []

    var body: some View {
        List {
            if !learned.isEmpty {
                Section {
                    ForEach(learned, id: \.record.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.record.canonicalName).font(.headline)
                                Spacer()
                                Text("\(entry.record.occurrenceCount)×")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.shows.isEmpty {
                                Text(entry.shows.sorted().joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                } header: {
                    Text("Heard in Ads")
                } footer: {
                    Text("Sponsors from ads you've confirmed. When one turns up on another show, it's recognized immediately.")
                }
            }

            if isLoading {
                HStack { ProgressView(); Text("Scanning show notes…").foregroundStyle(.secondary) }
            } else if entries.isEmpty && learned.isEmpty {
                ContentUnavailableView(
                    "No Sponsors Found",
                    systemImage: "megaphone",
                    description: Text("Sponsors named in your shows' episode notes appear here.")
                )
                .listRowSeparator(.hidden)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.name).font(.headline)
                        Spacer()
                        Text("\(entry.occurrences)×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.shows.sorted().joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !entry.promoCodes.isEmpty {
                        Text("Codes: " + entry.promoCodes.sorted().joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Sponsors")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    /// Aggregates sponsor hints across the newest episodes of every show.
    /// Cheap: the summaries are already in the database.
    private func reload() async {
        let records = (try? await model.sponsors.all()) ?? []
        let shows = (try? await model.sponsors.showTitles()) ?? [:]
        learned = records.map { ($0, shows[$0.id] ?? []) }

        var byName: [String: Entry] = [:]

        for podcast in model.library {
            let episodes = (try? await model.episodes.episodes(podcastID: podcast.id, limit: 10)) ?? []
            for episode in episodes {
                guard let summary = episode.summary else { continue }
                for hint in SponsorHintExtractor.extract(from: summary) {
                    var entry = byName[hint.name] ?? Entry(
                        name: hint.name, shows: [], occurrences: 0, promoCodes: []
                    )
                    entry.shows.insert(podcast.title)
                    entry.occurrences += 1
                    entry.promoCodes.formUnion(hint.promoCodes)
                    byName[hint.name] = entry
                }
            }
        }

        entries = byName.values.sorted { $0.occurrences > $1.occurrences }
        isLoading = false
    }
}
