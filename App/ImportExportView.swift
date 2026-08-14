import CodexCastFeeds
import SwiftUI
import UniformTypeIdentifiers

/// OPML import and export (A5.1, §8.1) — the migration path in and out of
/// every other podcast app.
struct ImportExportView: View {
    @Environment(AppModel.self) private var model

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isExportingLearning = false
    @State private var isImportingLearning = false
    @State private var learningJSON = ""
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

            Section {
                Button("Export Learning Data") {
                    Task {
                        if let json = await model.exportLearningJSON() {
                            learningJSON = json
                            isExportingLearning = true
                        } else {
                            message = "Nothing to export yet."
                        }
                    }
                }
                Button("Import Learning Data") { isImportingLearning = true }
            } header: {
                Text("Ad Detection Knowledge")
            } footer: {
                Text(
                    """
                    One file with everything learned about ads: patterns, \
                    sponsors, ad positions, and your review history. Send it \
                    out for distilling, and import the result — or a file \
                    from another device — as starting knowledge. Importing \
                    only adds; it never removes what this device learned.
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
        .fileExporter(
            isPresented: $isExportingLearning,
            document: OPMLDocument(text: learningJSON),
            contentType: .json,
            defaultFilename: "CodexCast Learning"
        ) { result in
            if case .success = result {
                message = "Learning data exported."
            }
        }
        .fileImporter(
            isPresented: $isImportingLearning,
            allowedContentTypes: [.json]
        ) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                message = await model.importLearningJSON(from: url)
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
    static let readableContentTypes: [UTType] = [.xml, .json]

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
