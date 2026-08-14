import CodexCastCore
import CodexCastPersistence
import SwiftUI

@main
struct CodexCastApp: App {
    @State private var model: AppModel

    init() {
        do {
            let model = try AppModel()
            _model = State(initialValue: model)
            AppModel.registerBackgroundTasks(model: model)
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
        // The mini player is a tab-bar accessory (iOS 26 Liquid Glass), so it
        // docks ABOVE the tab bar instead of covering it — a bottom inset on
        // TabView buries the tabs entirely, which is exactly what happened.
        // Applied conditionally: an empty accessory still draws its capsule.
        if model.nowPlaying != nil {
            tabs.tabViewBottomAccessory {
                MiniPlayerView()
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
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
        .task {
            await model.restoreSession()
            model.scheduleBackgroundWork()
        }
    }
}
