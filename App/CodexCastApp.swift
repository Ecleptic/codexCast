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
    @State private var router = Router()

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
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: Router.TabID.home) {
                HomeView()
            }
            Tab("Podcasts", systemImage: "square.grid.3x3", value: Router.TabID.podcasts) {
                PodcastsGridView()
            }
            Tab("Discover", systemImage: "magnifyingglass", value: Router.TabID.discover) {
                DiscoverView()
            }
            Tab("Settings", systemImage: "gearshape", value: Router.TabID.settings) {
                SettingsView()
            }
        }
        .environment(router)
        // Native Liquid Glass behavior: the tab bar shrinks away on scroll and
        // the accessory floats inline with it — the system does the work.
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await model.restoreSession()
            model.scheduleBackgroundWork()
        }
    }
}
