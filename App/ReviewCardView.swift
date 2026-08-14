import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// "We found these ads — is this right?" (A3.2). Shown once when an episode
/// finishes with unreviewed detections: one tap per item, or dismiss and the
/// segments stay unreviewed — silence is not treated as agreement.
struct ReviewCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let review: AppModel.EpisodeReview

    @State private var verdicts: [DetectedSegment.ID: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(review.segments, id: \.id) { segment in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rowLabel(segment))
                                    .font(.callout.weight(.medium))
                                if let rationale = segment.rationale {
                                    Text(rationale)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if let verdict = verdicts[segment.id] {
                                Image(systemName: verdict ? "checkmark.seal.fill" : "xmark.seal")
                                    .foregroundStyle(verdict ? .green : .secondary)
                            } else {
                                Button {
                                    verdicts[segment.id] = true
                                    Task { await model.confirmSegment(segment, episode: review.episode) }
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .tint(.green)
                                .accessibilityLabel("Yes, that was an ad")
                                Button {
                                    verdicts[segment.id] = false
                                    Task { await model.rejectSegment(segment, episode: review.episode) }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .tint(.red)
                                .accessibilityLabel("No, that was content")
                            }
                        }
                    }
                } header: {
                    Text("Found in this episode")
                } footer: {
                    Text("Every answer teaches this show's detector. Skip any you're not sure about.")
                }
            }
            .navigationTitle(review.episode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func rowLabel(_ segment: DetectedSegment) -> String {
        let kind: String = switch segment.kind {
        case .ad: "Ad"
        case .sponsorRead: "Sponsor read"
        case .selfPromo: "Self-promo"
        case .intro: "Intro"
        case .outro: "Outro"
        }
        return "\(kind) · \(timeString(segment.startMs))–\(timeString(segment.endMs))"
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
