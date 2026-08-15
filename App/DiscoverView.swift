import CodexCastFeeds
import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var showAddByURL = false
    @State private var chart: [TopChartsClient.ChartEntry] = []

    var body: some View {
        NavigationStack {
            List {
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
                if query.isEmpty && results.isEmpty {
                    Section("Top Podcasts") {
                        ForEach(chart) { entry in
                            ChartRow(entry: entry)
                        }
                        if chart.isEmpty {
                            HStack { ProgressView(); Text("Loading charts…").foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(results) { result in
                    SearchResultRow(result: result) {
                        guard let feedURL = result.feedURL else { return }
                        Task {
                            do {
                                try await model.subscribe(
                                    feedURL: feedURL,
                                    itunesCollectionID: result.collectionID
                                )
                                statusMessage = nil
                            } catch {
                                // A dead button teaches the user the app is
                                // broken; a reason teaches them what happened.
                                statusMessage = "Couldn't add \(result.title): \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Search podcasts")
            .onChange(of: query) {
                scheduleSearch()
            }
            .toolbar {
                // Add-by-URL is first-class, not buried (§8.1): private feeds
                // and self-hosted shows never appear in the directory.
                Button("Add by URL", systemImage: "link") {
                    showAddByURL = true
                }
            }
            .sheet(isPresented: $showAddByURL) {
                AddByURLView()
            }
            .task {
                if chart.isEmpty {
                    chart = (try? await model.charts.topPodcasts()) ?? []
                }
            }
        }
    }

    /// Debounced search: the directory rate-limits aggressively, and a
    /// keystroke is not a commitment.
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                results = try await model.search.search(term: term)
                statusMessage = nil
            } catch let error as HTTPError {
                if case .rateLimited = error {
                    // Throttling is not "no results" — say so (§8.1).
                    statusMessage = "Search is busy — try again in a moment."
                } else {
                    statusMessage = "Search failed."
                }
            } catch {
                statusMessage = "Search failed."
            }
        }
    }
}

private struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    let result: PodcastSearchResult
    let onSubscribe: () -> Void

    private var isSubscribed: Bool {
        // Match by feed URL as well as iTunes ID: shows imported via OPML
        // have no iTunes ID until a re-follow backfills it.
        model.library.contains {
            $0.itunesCollectionID == result.collectionID
                || (result.feedURL.map(\.absoluteString) == $0.feedURL)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline).lineLimit(2)
                if let author = result.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()

            if isSubscribed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if result.feedURL != nil {
                Button("Follow", action: onSubscribe)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

private struct AddByURLView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/feed.rss", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add by URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(urlText.isEmpty || isWorking)
                }
            }
        }
    }

    private func add() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true
        else {
            errorMessage = "That doesn't look like a feed URL."
            return
        }
        isWorking = true
        Task {
            do {
                try await model.subscribe(feedURL: url)
                dismiss()
            } catch {
                errorMessage = "Couldn't load that feed: \(error.localizedDescription)"
                isWorking = false
            }
        }
    }
}

/// A top-charts row: subscribing resolves the feed URL through one lookup.
private struct ChartRow: View {
    @Environment(AppModel.self) private var model
    let entry: TopChartsClient.ChartEntry
    @State private var isWorking = false
    @State private var errorText: String?

    private var isSubscribed: Bool {
        model.library.contains { $0.itunesCollectionID == entry.id }
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(2)
                if let artist = entry.artistName {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let errorText {
                    Text(errorText).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }

            Spacer()

            if isSubscribed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else if isWorking {
                ProgressView()
            } else {
                Button("Follow") {
                    isWorking = true
                    errorText = nil
                    Task {
                        do {
                            guard let feedURL = try await model.charts.feedURL(for: entry) else {
                                throw HTTPError.status(404)
                            }
                            try await model.subscribe(feedURL: feedURL, itunesCollectionID: entry.id)
                        } catch {
                            errorText = "Couldn't add: \(error.localizedDescription)"
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}
