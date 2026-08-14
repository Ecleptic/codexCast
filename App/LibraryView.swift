import CodexCastCore
import CodexCastPersistence
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.library.isEmpty {
                    ContentUnavailableView(
                        "No Subscriptions",
                        systemImage: "square.stack",
                        description: Text("Find shows in Discover, or add a feed by URL.")
                    )
                } else {
                    List(model.library, id: \.id) { podcast in
                        NavigationLink(value: podcast.id) {
                            PodcastRow(podcast: podcast)
                        }
                    }
                    .navigationDestination(for: CodexCastCore.Podcast.ID.self) { id in
                        if let podcast = model.library.first(where: { $0.id == id }) {
                            EpisodeListView(podcast: podcast)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .refreshable {
                for podcast in model.library {
                    await model.refresh(podcast)
                }
                await model.reloadLibrary()
            }
        }
        .task {
            await model.reloadLibrary()
        }
    }
}

private struct PodcastRow: View {
    let podcast: PodcastRecord

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = podcast.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let error = podcast.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }
}
