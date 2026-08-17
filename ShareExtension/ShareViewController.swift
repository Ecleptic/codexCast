import UIKit
import UniformTypeIdentifiers

/// Share a YouTube channel from anywhere; it lands in Codex Cast as a
/// podcast. The extension does no work of its own — it hands the URL to the
/// app, which resolves the channel and subscribes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await handleSharedItem() }
    }

    private func handleSharedItem() async {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let provider = item.attachments?.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                      || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
              })
        else { return finish(nil) }

        let shared = await loadURL(from: provider)
        finish(shared)
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(
               forTypeIdentifier: UTType.url.identifier
           ) as? URL {
            return url
        }
        // Some share sources hand over the link as text.
        if let text = try? await provider.loadItem(
            forTypeIdentifier: UTType.plainText.identifier
        ) as? String {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func finish(_ shared: URL?) {
        defer { extensionContext?.completeRequest(returningItems: nil) }
        guard let shared,
              var components = URLComponents(string: "codexcast://add")
        else { return }
        components.queryItems = [URLQueryItem(name: "url", value: shared.absoluteString)]
        guard let handoff = components.url else { return }
        openHost(handoff)
    }

    /// `extensionContext.open` is the documented route but is unreliable from
    /// share extensions; walking the responder chain to UIApplication is the
    /// long-standing fallback every app of this kind uses.
    private func openHost(_ url: URL) {
        extensionContext?.open(url) { opened in
            guard !opened else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let application = current as? UIApplication {
                    application.open(url)
                    return
                }
                responder = current.next
            }
        }
    }
}
