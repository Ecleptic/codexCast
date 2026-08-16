import CodexCastCore
import CodexCastPersistence
import SwiftUI

/// Boundary editor for one detected segment — §6.4's "Adjust boundaries",
/// the correction that teaches most: the corrected span becomes a pattern
/// and the old→new delta trains the show's boundary bias.
///
/// Nudge buttons rather than a drag: exact, accessible, and each edge can
/// be auditioned in place before saving.
struct SegmentAdjustSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let segment: DetectedSegment
    let episode: EpisodeRecord

    @State private var startMs: Int
    @State private var endMs: Int

    init(segment: DetectedSegment, episode: EpisodeRecord) {
        self.segment = segment
        self.episode = episode
        _startMs = State(initialValue: segment.startMs)
        _endMs = State(initialValue: segment.endMs)
    }

    var body: some View {
        NavigationStack {
            Form {
                boundarySection(
                    title: "Starts at",
                    valueMs: $startMs,
                    lowerLimit: 0,
                    upperLimit: endMs - 1_000,
                    // Audition the transition INTO the ad: start a touch early.
                    previewFromMs: max(0, startMs - 3_000)
                )
                boundarySection(
                    title: "Ends at",
                    valueMs: $endMs,
                    lowerLimit: startMs + 1_000,
                    upperLimit: episode.durationMs ?? .max,
                    // Audition the transition OUT: land just before the edge.
                    previewFromMs: max(0, endMs - 3_000)
                )

                Section {
                    LabeledContent("Length") {
                        Text(durationString(endMs - startMs)).monospacedDigit()
                    }
                } footer: {
                    Text("Adjusting confirms this as an ad and teaches the detector both the corrected words and how far off it was.")
                }
            }
            .navigationTitle("Adjust Boundaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let start = startMs
                        let end = endMs
                        Task {
                            await model.adjustSegment(
                                segment, newStartMs: start, newEndMs: end, episode: episode
                            )
                        }
                        dismiss()
                    }
                    .disabled(startMs == segment.startMs && endMs == segment.endMs)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func boundarySection(
        title: String,
        valueMs: Binding<Int>,
        lowerLimit: Int,
        upperLimit: Int,
        previewFromMs: Int
    ) -> some View {
        Section(title) {
            HStack {
                Text(timeString(valueMs.wrappedValue))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer()
                Button {
                    model.player.seek(toMediaMs: previewFromMs)
                    model.player.play()
                } label: {
                    Label("Listen", systemImage: "play.circle")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 10) {
                nudge("-5s", -5_000, valueMs, lowerLimit, upperLimit)
                nudge("-1s", -1_000, valueMs, lowerLimit, upperLimit)
                Spacer()
                nudge("+1s", 1_000, valueMs, lowerLimit, upperLimit)
                nudge("+5s", 5_000, valueMs, lowerLimit, upperLimit)
            }
            .buttonStyle(.bordered)
        }
    }

    private func nudge(
        _ label: String, _ deltaMs: Int,
        _ valueMs: Binding<Int>, _ lowerLimit: Int, _ upperLimit: Int
    ) -> some View {
        Button(label) {
            valueMs.wrappedValue = min(max(valueMs.wrappedValue + deltaMs, lowerLimit), upperLimit)
        }
        .font(.callout.monospacedDigit())
    }

    private func timeString(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func durationString(_ ms: Int) -> String {
        let total = ms / 1000
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
