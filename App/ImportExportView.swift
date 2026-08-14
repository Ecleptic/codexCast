import CodexCastFeeds
import SwiftUI
import UniformTypeIdentifiers

/// OPML import and export (A5.1, §8.1) — the migration path in and out of
/// every other podcast app.
struct ImportExportView: View {
    @Environment(AppModel.self) private var model

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("Import OPML") { isImporting = true }
                Button("Export OPML") { isExporting = true }
                    .disabled(model.library.isEmpty)
            } footer: {
                Text(
                    """
                    OPML files are used to exchange subscriptions between \
                    podcast apps. An OPML file lists podcasts only — it does \
                    not carry episodes, playback positions, or anything Codex \
                    Cast has learned about ads.
                    """
                )
            }

            if let message {
                Section {
                    Text(message).font(.footnote)
                }
            }
        }
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.init(filenameExtension: "opml") ?? .xml, .xml]
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: OPMLDocument(text: model.exportOPML()),
            contentType: .xml,
            defaultFilename: "CodexCast Subscriptions"
        ) { result in
            if case .success = result {
                message = "Exported \(model.library.count) subscriptions."
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            do {
                // Files chosen from other apps are security-scoped.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let entries = try OPML.parse(try Data(contentsOf: url))
                let added = await model.importOPML(entries)
                message = "Imported \(added) of \(entries.count) subscriptions."
            } catch {
                message = "Couldn't read that OPML file."
            }
        }
    }
}

private struct OPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.xml]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
