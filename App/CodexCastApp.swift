import CodexCastCore
import CodexCastPersistence
import SwiftUI

@main
struct CodexCastApp: App {
    @State private var model: AppModel

    init() {
        do {
            _model = State(initialValue: try AppModel())
        } catch {
            // A database that cannot open on first launch is unrecoverable;
            // crash with the reason visible rather than limping.
            fatalError("Failed to open database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
            }
            Tab("Podcasts", systemImage: "square.grid.3x3") {
                PodcastsGridView()
            }
            Tab("Discover", systemImage: "magnifyingglass") {
                DiscoverView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        // The mini player is global (ux-architecture invariant 1): present on
        // every tab while something plays, never scoped to one screen.
        .safeAreaInset(edge: .bottom) {
            if model.nowPlaying != nil {
                MiniPlayerView()
            }
        }
    }
}
