import SwiftUI

/// YouTube channels as podcasts, via a self-hosted Podsync server.
struct YouTubeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var pasted = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                TextField("https://podsync.example.com", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.podsyncServer = server }
            } header: {
                Text("Podsync Server")
            } footer: {
                Text("Your own Podsync instance, which turns YouTube channels into podcast feeds.")
            }

            Section {
                TextField("https://youtube.com/@handle", text: $pasted)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add Channel") {
                    guard let url = URL(string: pasted.trimmingCharacters(in: .whitespaces)) else {
                        status = "That doesn't look like a link."
                        return
                    }
                    Task {
                        model.podsyncServer = server
                        status = await model.addYouTubeLink(url)
                        pasted = ""
                    }
                }
                .disabled(pasted.isEmpty)

                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Add a Channel")
            } footer: {
                Text("Or share any YouTube channel, playlist, or video from another app and pick Codex Cast — @handles are resolved automatically.")
            }
        }
        .navigationTitle("YouTube")
        .navigationBarTitleDisplayMode(.inline)
        .task { server = model.podsyncServer }
    }
}
