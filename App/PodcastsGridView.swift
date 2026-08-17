import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The library as an artwork grid (ux-architecture invariant 4): shows are
/// recognized by their covers, not read as text.
struct PodcastsGridView: View {
    @Environment(AppModel.self) private var model

    /// Followed shows are the regulars — they feed Home and New Releases.
    /// Everything else is the browsing library: kept, searchable, quiet.
    private enum Filter: String, CaseIterable {
        case following = "Following"
        case everything = "Everything"
    }

    @State private var filter: Filter = .following
    @State private var showCuration = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    private var visible: [PodcastRecord] {
        filter == .following ? model.library.filter(\.isFollowed) : model.library
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)

                if model.library.isEmpty {
                    ContentUnavailableView(
                        "No Subscriptions",
                        systemImage: "square.grid.3x3",
                        description: Text("Find shows in Discover, or add a feed by URL.")
                    )
                    .padding(.top, 60)
                } else if visible.isEmpty {
                    ContentUnavailableView(
                        "Not Following Anything Yet",
                        systemImage: "heart",
                        description: Text("Follow the shows you listen to regularly — only they appear on Home and in New Releases. Tap Curate to pick them quickly.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(visible, id: \.id) { podcast in
                            NavigationLink(value: podcast.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(.quaternary)
                                            .overlay {
                                                Text(podcast.title.prefix(2))
                                                    .font(.title2.bold())
                                                    .foregroundStyle(.secondary)
                                            }
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                    Text(podcast.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PodcastContextMenu(podcast: podcast)
                            }
                            .overlay(alignment: .topTrailing) {
                                if podcast.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .padding(5)
                                        .glassEffect(.regular, in: Circle())
                                        .padding(4)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                // In Everything, mark the regulars.
                                if filter == .everything, podcast.isFollowed {
                                    Image(systemName: "heart.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                        .padding(5)
                                        .glassEffect(.regular, in: Circle())
                                        .padding(4)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Podcasts")
            .toolbar {
                Button("Curate", systemImage: "heart.text.square") {
                    showCuration = true
                }
            }
            .sheet(isPresented: $showCuration) {
                FollowCurationSheet()
            }
            .navigationDestination(for: Podcast.ID.self) { id in
                if let podcast = model.library.first(where: { $0.id == id }) {
                    EpisodeListView(podcast: podcast)
                }
            }
            .refreshable {
                for podcast in model.library { await model.refresh(podcast) }
                await model.reloadLibrary()
                await model.enforceRetention()
            }
            .task { await model.reloadLibrary() }
        }
    }
}

/// Fast bulk curation of followed shows: 97 OPML-imported feeds all landed
/// as "followed", which made New Releases a stranger's feed ("I don't know
/// who Jim Bianco is and I don't care"). One list, one toggle per show,
/// unfollow-all to start clean.
struct FollowCurationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnfollowAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Unfollow All", role: .destructive) {
                        confirmUnfollowAll = true
                    }
                } footer: {
                    Text("Followed shows appear on Home and in New Releases. Everything else stays in your library for browsing — nothing is removed.")
                }

                Section("Shows") {
                    ForEach(model.library, id: \.id) { podcast in
                        HStack(spacing: 10) {
                            AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(podcast.title).lineLimit(1)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { podcast.isFollowed },
                                set: { followed in
                                    Task { await model.setFollowed(followed, podcast: podcast) }
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
            .navigationTitle("Follow Shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog(
                "Unfollow all \(model.library.count) shows?",
                isPresented: $confirmUnfollowAll,
                titleVisibility: .visible
            ) {
                Button("Unfollow All", role: .destructive) {
                    Task {
                        for podcast in model.library where podcast.isFollowed {
                            await model.setFollowed(false, podcast: podcast)
                        }
                    }
                }
            } message: {
                Text("They stay in your library — this only clears Home and New Releases so you can re-follow just your regulars.")
            }
        }
    }
}
