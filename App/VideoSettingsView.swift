import SwiftUI

/// How video episodes play and look (§8.3).
struct VideoSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Play video when available", isOn: $model.videoSettings.playVideoWhenAvailable)
                Toggle("Show video instead of poster", isOn: $model.videoSettings.showVideoStage)
                Toggle("Crop video to fill", isOn: $model.videoSettings.cropToFill)
            } footer: {
                Text(
                    """
                    Video plays through the same player as audio — the same \
                    scrubber, ad skipping, and lock screen controls, and it \
                    keeps playing in the background as audio. Cropping fills \
                    the stage and trims the sides; off shows the whole frame. \
                    Downloaded episodes always play from this iPhone, so an \
                    audio download stays audio.
                    """
                )
            }
        }
        .navigationTitle("Video")
        .navigationBarTitleDisplayMode(.inline)
    }
}
