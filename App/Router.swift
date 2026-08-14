import CodexCastCore
import CodexCastPersistence
import Foundation
import Observation
import SwiftUI

/// One navigation authority for deep links, so any surface — including the
/// player sheet, which lives outside every tab's stack — can open episode or
/// show details. All deep links land on the Home tab's stack.
@MainActor
@Observable
final class Router {
    enum TabID: Hashable {
        case home, podcasts, discover, settings
    }

    var tab: TabID = .home
    var homePath = NavigationPath()

    /// Set when a sheet (the player) needs to close before navigation runs.
    var dismissPlayerSheet = false

    func openEpisode(_ episode: EpisodeRecord) {
        dismissPlayerSheet = true
        tab = .home
        homePath.append(episode)
    }

    func openShow(_ podcastID: Podcast.ID) {
        dismissPlayerSheet = true
        tab = .home
        homePath.append(podcastID)
    }
}
