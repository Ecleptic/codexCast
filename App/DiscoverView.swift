import CodexCastCore
import CodexCastFeeds
import CodexCastPersistence
import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var showAddByURL = false
    @State private var chart: [TopChartsClient.ChartEntry] = []
    @State private var selectedGenre: Int? = nil
    @State private var preview: PreviewTarget?

    /// What a tapped row opens: enough identity to look the show up.
    struct PreviewTarget: Identifiable {
        var id: String { title }
        var title: String
        var artist: String?
        var artworkURL: URL?
        var collectionID: Int?
        var feedURL: URL?
    }

    var body: some View {
        NavigationStack {
            List {
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
                if query.isEmpty && results.isEmpty {
                    genreChips

                    Section(selectedGenre == nil
                        ? "Top Podcasts"
                        : "Top in \(TopChartsClient.genres.first { $0.id == selectedGenre }?.name ?? "Genre")"
                    ) {
                        ForEach(visibleChart) { entry in
                            ChartRow(entry: entry) {
                                preview = PreviewTarget(
                                    title: entry.name, artist: entry.artistName,
                                    artworkURL: entry.artworkURL,
                                    collectionID: entry.id, feedURL: nil
                                )
                            }
                        }
                        if chart.isEmpty {
                            HStack { ProgressView(); Text("Loading charts…").foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(visibleResults) { result in
                    row(for: result)
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
            .sheet(item: $preview) { target in
                PodcastPreviewSheet(target: target)
            }
            .task {
                if chart.isEmpty {
                    chart = (try? await model.charts.topPodcasts()) ?? []
                }
            }
        }
    }

    // MARK: - Filtering (blocklist + already-subscribed for suggestions)

    private var visibleChart: [TopChartsClient.ChartEntry] {
        chart.filter { !model.isBlocked(collectionID: $0.id, artist: $0.artistName) }
    }

    private var visibleResults: [PodcastSearchResult] {
        results.filter { !model.isBlocked(collectionID: $0.collectionID, artist: $0.author) }
    }

    @ViewBuilder
    private var genreChips: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("All", selected: selectedGenre == nil) {
                        selectedGenre = nil
                        Task { chart = (try? await model.charts.topPodcasts()) ?? [] }
                    }
                    ForEach(TopChartsClient.genres, id: \.id) { genre in
                        chip(genre.name, selected: selectedGenre == genre.id) {
                            selectedGenre = genre.id
                            chart = []
                            Task {
                                chart = (try? await model.charts.topPodcasts(genre: genre.id)) ?? []
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        }
        .listSectionSeparator(.hidden)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentShape(Capsule())
        }
        // Borderless, NOT plain: a plain button inside a List row loses the
        // tap to the row's own hit-testing — the chips read as decoration.
        .buttonStyle(.borderless)
    }

    private func row(for result: PodcastSearchResult) -> some View {
        SearchResultRow(
            result: result,
            onOpen: {
                preview = PreviewTarget(
                    title: result.title, artist: result.author,
                    artworkURL: result.artworkURL,
                    collectionID: result.collectionID, feedURL: result.feedURL
                )
            },
            onSubscribe: {
                guard let feedURL = result.feedURL else { return }
                Task {
                    do {
                        try await model.subscribe(
                            feedURL: feedURL, itunesCollectionID: result.collectionID
                        )
                        statusMessage = nil
                    } catch {
                        statusMessage = "Couldn't add \(result.title): \(error.localizedDescription)"
                    }
                }
            }
        )
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

// MARK: - Rows

private struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    let result: PodcastSearchResult
    let onOpen: () -> Void
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
        Button(action: onOpen) {
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
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            DiscoverBlockMenu(collectionID: result.collectionID, artist: result.author)
        }
    }
}

/// A top-charts row; tapping opens the preview, Follow resolves the feed.
private struct ChartRow: View {
    @Environment(AppModel.self) private var model
    let entry: TopChartsClient.ChartEntry
    let onOpen: () -> Void
    @State private var isWorking = false
    @State private var errorText: String?

    private var isSubscribed: Bool {
        model.library.contains { $0.itunesCollectionID == entry.id }
    }

    var body: some View {
        Button(action: onOpen) {
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
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            DiscoverBlockMenu(collectionID: entry.id, artist: entry.artistName)
        }
    }
}

/// "Never show me this again" — hides a show (or everything by a producer)
/// from charts, search, and suggestions. Local preference only.
private struct DiscoverBlockMenu: View {
    @Environment(AppModel.self) private var model
    let collectionID: Int?
    let artist: String?

    var body: some View {
        if let collectionID {
            Button(role: .destructive) {
                model.blocklist.collectionIDs.insert(collectionID)
            } label: {
                Label("Block This Show", systemImage: "nosign")
            }
        }
        if let artist, !artist.isEmpty {
            Button(role: .destructive) {
                model.blocklist.producers.insert(artist.lowercased())
            } label: {
                Label("Block Everything by \(artist)", systemImage: "nosign")
            }
        }
    }
}

// MARK: - Preview sheet

/// Look before you follow: artwork, description, and recent episodes,
/// fetched straight from the feed without subscribing. Follow puts the show
/// with your regulars; Add just shelves it in the library.
private struct PodcastPreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: DiscoverView.PreviewTarget

    @State private var feedURL: URL?
    @State private var summary: String?
    @State private var episodes: [String] = []
    @State private var loadFailed = false
    @State private var isSubscribing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AsyncImage(url: target.artworkURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.title).font(.headline)
                            if let artist = target.artist {
                                Text(artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)

                    HStack(spacing: 10) {
                        Button {
                            subscribe(following: true)
                        } label: {
                            Label("Follow", systemImage: "heart.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)

                        Button {
                            subscribe(following: false)
                        } label: {
                            Label("Add", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .disabled(feedURL == nil || isSubscribing)
                } footer: {
                    Text("Follow: appears on Home and in New Releases. Add: kept in your library for browsing only.")
                }

                if let summary, !summary.isEmpty {
                    Section("About") {
                        Text(summary.htmlToPlainText).font(.callout)
                    }
                }

                if !episodes.isEmpty {
                    Section("Recent Episodes") {
                        ForEach(episodes, id: \.self) { title in
                            Text(title).font(.callout).lineLimit(2)
                        }
                    }
                } else if loadFailed {
                    Section {
                        Text("Couldn't load this show's feed.")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task { await load() }
        }
    }

    private func load() async {
        var url = target.feedURL
        if url == nil, let collectionID = target.collectionID {
            url = try? await model.search.lookup(collectionID: collectionID)?.feedURL
        }
        guard let url else {
            loadFailed = true
            return
        }
        feedURL = url
        guard let result = try? await model.fetcher.fetch(url),
              case .updated(let feed, _) = result
        else {
            loadFailed = true
            return
        }
        summary = feed.summary
        episodes = feed.episodes.prefix(10).map(\.title)
    }

    private func subscribe(following: Bool) {
        guard let feedURL else { return }
        isSubscribing = true
        Task {
            if following {
                try? await model.subscribe(feedURL: feedURL, itunesCollectionID: target.collectionID)
            } else {
                try? await model.addWithoutFollowing(feedURL: feedURL, itunesCollectionID: target.collectionID)
            }
            dismiss()
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