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
    var body: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                LibraryView()
            }
            Tab("Discover", systemImage: "magnifyingglass") {
                DiscoverView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
