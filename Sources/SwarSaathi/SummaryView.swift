import SwiftUI

struct SummaryView: View {
    let summary: PracticeSummary
    let results: [NoteResult?]
    let bpm: Double
    let captureWarning: String?
    let timingWasEstimated: Bool
    let targets: [NoteTarget]
    let auditURL: URL?
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let captureWarning {
                Text("Recording incomplete").font(.title2.bold())
                Text(captureWarning)
            } else {
                Text("Pitch match · \(Int(bpm)) BPM").font(.title2.bold())
                Text(String(format: "%.1f%%", summary.practiceMatchPercent))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                    startPoint: .leading, endPoint: .trailing))
            }
            Text(String(format: "Reliable voice in %.1f%% of the exercise. Every scheduled note counts.", summary.reliableCoveragePercent))
                .font(.subheadline).foregroundColor(.secondary)

            Text("Each note").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                ForEach(targets) { target in
                    NoteCardView(target: target,
                                 result: results.indices.contains(target.index) ? results[target.index] : nil,
                                 isCurrent: false, thresholds: AccuracyThresholds())
                }
            }

            Button("Practice Again", action: onRestart)
                .buttonStyle(PrimaryButtonStyle())

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: "Without note-change allowance: %.1f%%", summary.accuracyPercent))
                    Text(String(format: "With note changes: %.1f%% at %d BPM", summary.practiceMatchPercent, Int(bpm)))
                    Text("Pitch match allows ±50 cents, with \(Int((1000 * summary.transitionWindowSeconds).rounded())) ms either side of a note change.")
                    let notes = results.compactMap { $0 }
                    let expected = notes.reduce(0) { $0 + $1.expectedFrames }
                    let observed = notes.reduce(0) { $0 + ($1.observedCells ?? 0) }
                    let voiced = notes.reduce(0) { $0 + $1.voicedFrames }
                    let correct = notes.reduce(0) { $0 + $1.correctFrames }
                    let transitions = notes.reduce(0) { $0 + $1.transitionAcceptedFrames }
                    Text("Of \(expected) time slots: \(correct) on pitch, \(transitions) allowed during changes, \(voiced - correct - transitions) off target, \(observed - voiced) without clear pitch, \(expected - observed) without a reading.")
                    if timingWasEstimated {
                        Text("Some capture times were estimated. Timing near a note change may be less precise.")
                    }
                    if let url = auditURL {
                        ShareLink(item: url) {
                            Label("Share report", systemImage: "square.and.arrow.up")
                        }
                        .fontWeight(.semibold)
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .card()
    }
}
