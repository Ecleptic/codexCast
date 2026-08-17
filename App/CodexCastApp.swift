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
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = Router()

    var body: some View {
        // The mini player is a tab-bar accessory (iOS 26 Liquid Glass), so it
        // docks ABOVE the tab bar instead of covering it — a bottom inset on
        // TabView buries the tabs entirely, which is exactly what happened.
        // Applied conditionally: an empty accessory still draws its capsule.
        @Bindable var router = router
        @Bindable var model = model
        Group {
            if model.nowPlaying != nil {
                tabs
                    .tabViewBottomAccessory {
                        MiniPlayerView()
                    }
                    .sheet(isPresented: $router.showPlayer) {
                        // The sheet is hosted outside the tab hierarchy, so the
                        // router injected inside `tabs` never reaches it — inject
                        // it again here or the first environment read traps.
                        NowPlayingView()
                            .environment(router)
                    }
            } else {
                tabs
            }
        }
        // End-of-episode review card (A3): appears whichever state playback
        // lands in after an episode finishes.
        .sheet(item: $model.pendingReview) { review in
            ReviewCardView(review: review)
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
            await model.refreshIfStale()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is itself a "check for new episodes".
            guard phase == .active else { return }
            Task { await model.refreshIfStale() }
        }
    }
}
