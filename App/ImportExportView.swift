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
    @State private var isExportingCorpus = false
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
                Button("Export Tagged Ads (corpus)") {
                    Task {
                        if let json = await model.exportLabeledCorpusJSON() {
                            learningJSON = json
                            isExportingCorpus = true
                        } else {
                            message = "No tagged ads yet — confirm or mark some first."
                        }
                    }
                }
            } header: {
                Text("Ad Detection Knowledge")
            } footer: {
                Text(
                    """
                    Learning data is everything the detector knows: patterns, \
                    sponsors, ad positions, and your review history including \
                    the words of every span you judged. Tagged Ads exports the \
                    episodes you've labeled in the evaluation corpus format, \
                    for measuring the detector against your own ears. \
                    Importing only adds; it never removes what this device \
                    learned.
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
        .fileExporter(
            isPresented: $isExportingCorpus,
            document: OPMLDocument(text: learningJSON),
            contentType: .json,
            defaultFilename: "CodexCast Tagged Ads"
        ) { result in
            if case .success = result {
                message = "Tagged ads exported in corpus format."
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
                let result = await model.importOPML(entries)
                var summary = "Imported \(result.added) of \(entries.count) subscriptions."
                if !result.failures.isEmpty {
                    let list = result.failures
                        .map { "• \($0.title) — \($0.reason)" }
                        .joined(separator: "\n")
                    summary += "\n\nCouldn't add:\n" + list
                }
                message = summary
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
