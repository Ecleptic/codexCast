import AVFoundation
import SwiftUI
import UIKit

/// The playback engine's video output, rendered inline — not a modal file
/// player. Same `AVPlayer`, so the timeline, ad skips, scrubber, lock screen,
/// and Up Next all keep working while video is on screen.
///
/// `player` is optional on purpose: passing nil detaches the layer, which is
/// what lets audio keep playing when the app goes to the background. iOS
/// suspends a foreground video pipeline; audio-only continues.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer?
    /// `.resizeAspect` shows the whole frame; `.resizeAspectFill` crops to
    /// fill the space (the TikTok/Reels look).
    var gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
