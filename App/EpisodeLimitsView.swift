import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Per-show download retention, all shows on one screen (A5.3).
///
/// Deletes downloaded audio only — transcripts and everything the app has
/// learned about a show stay, because they are small and cannot be cheaply
/// re-derived.
struct EpisodeLimitsView: View {
    @Environment(AppModel.self) private var model

    /// Nil is Unlimited.
    private static let choices: [Int?] = [nil, 1, 2, 3, 5, 10, 20, 50]

    @State private var limits: [Podcast.ID: Int?] = [:]

    var body: some View {
        List(model.library, id: \.id) { podcast in
            HStack(spacing: 12) {
                AsyncImage(url: podcast.imageURL.flatMap(URL.init(string:))) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(podcast.title)
                    .lineLimit(2)

                Spacer()

                Picker("", selection: binding(for: podcast)) {
                    ForEach(Self.choices, id: \.self) { choice in
                        Text(label(for: choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .navigationTitle("Episode Limits")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for podcast in model.library {
                limits[podcast.id] = podcast.episodeLimit
            }
        }
    }

    private func binding(for podcast: PodcastRecord) -> Binding<Int?> {
        Binding(
            get: { limits[podcast.id] ?? podcast.episodeLimit },
            set: { newValue in
                limits[podcast.id] = newValue
                Task { await model.setEpisodeLimit(newValue, for: podcast.id) }
            }
        )
    }

    private func label(for choice: Int?) -> String {
        guard let choice else { return "Unlimited" }
        return choice == 1 ? "1 Newest" : "\(choice) Newest"
    }
}
