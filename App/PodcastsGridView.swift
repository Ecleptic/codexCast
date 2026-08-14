import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// The library as an artwork grid (ux-architecture invariant 4): shows are
/// recognized by their covers, not read as text.
struct PodcastsGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.library.isEmpty {
                    ContentUnavailableView(
                        "No Subscriptions",
                        systemImage: "square.grid.3x3",
                        description: Text("Find shows in Discover, or add a feed by URL.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.library, id: \.id) { podcast in
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
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Podcasts")
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
