import SwiftUI

struct SummaryView: View {
    let summary: PracticeSummary
    let results: [NoteResult?]
    let targets: [NoteTarget]
    let auditURL: URL?
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pitch match").font(.title2.bold())
            Text(String(format: "%.1f%%", summary.practiceMatchPercent))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Includes every note, with room for small variations and note changes. Missing notes count too.")
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
                    Text(String(format: "Voice detected: %.1f%%", summary.reliableCoveragePercent))
                    Text("Pitch match accepts ±50 cents and allows 0.1 seconds either side of a note change. It measures this exercise, not your overall singing ability.")
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
