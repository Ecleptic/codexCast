import UIKit
import SwiftUI

/// Home-screen icon choice — the codexReader family tradition of named marks.
struct AppIconSettingsView: View {
    private struct Choice: Identifiable {
        var id: String { alternateName ?? "primary" }
        /// nil = the primary (light/dark-aware) icon.
        var alternateName: String?
        var title: String
        var detail: String
        /// Bundled preview file; the primary previews via the catalog name.
        var previewResource: String?
    }

    private static let choices: [Choice] = [
        Choice(alternateName: nil, title: "Codex Cast",
               detail: "Follows light and dark mode.", previewResource: nil),
        Choice(alternateName: "IconInk", title: "Ink",
               detail: "The dark mark, all the time.", previewResource: "IconInk@3x"),
        Choice(alternateName: "IconViolet", title: "Violet",
               detail: "Ink band on the accent field.", previewResource: "IconViolet@3x"),
    ]

    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var errorText: String?

    var body: some View {
        List {
            ForEach(Self.choices) { choice in
                Button {
                    select(choice)
                } label: {
                    HStack(spacing: 14) {
                        preview(for: choice)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 13))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title).foregroundStyle(.primary)
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if current == choice.alternateName {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.orange).font(.footnote) }
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func preview(for choice: Choice) -> some View {
        if let resource = choice.previewResource,
           let image = UIImage(named: resource) {
            Image(uiImage: image).resizable()
        } else if let primary = Bundle.main.primaryIconImage {
            Image(uiImage: primary).resizable()
        } else {
            RoundedRectangle(cornerRadius: 13).fill(.quaternary)
        }
    }

    private func select(_ choice: Choice) {
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            Task { @MainActor in
                if let error {
                    errorText = error.localizedDescription
                } else {
                    current = choice.alternateName
                }
            }
        }
    }
}

private extension Bundle {
    /// The primary icon's largest rendition, for the picker preview.
    var primaryIconImage: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last
        else { return UIImage(named: "AppIcon") }
        return UIImage(named: name)
    }
}
