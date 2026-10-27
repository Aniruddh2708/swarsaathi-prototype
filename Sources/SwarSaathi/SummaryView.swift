import SwiftUI
import Charts

struct SummaryView: View {
    let summary: PracticeSummary
    let results: [NoteResult?]
    let targets: [NoteTarget]
    let onRestart: () -> Void

    private var detected: [NoteResult] {
        results.compactMap { $0 }.filter { $0.detectedHz != nil }
    }

    private var yDomain: ClosedRange<Double> {
        let all = targets.map { $0.frequency } + detected.compactMap { $0.detectedHz }
        let lo = (all.min() ?? 100) * 0.92
        let hi = (all.max() ?? 200) * 1.06
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Practice Summary", systemImage: "rosette")
                .font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile("Notes attempted", "\(summary.attempted) of \(summary.total)")
                tile("Sung on target", "\(summary.onTarget)")
                tile("Need improvement", "\(summary.needsImprovement)")
                tile("Avg. deviation", String(format: "%.0f cents", summary.avgAbsCents))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Overall pitch accuracy").font(.subheadline).foregroundColor(.secondary)
                Text(String(format: "%.0f%%", summary.accuracyPercent))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.swarBlue, .swarPurple],
                                                    startPoint: .leading, endPoint: .trailing))
            }

            Text("Target vs. what you sang")
                .font(.headline)
            Chart {
                ForEach(targets) { t in
                    LineMark(x: .value("Note", t.index), y: .value("Hz", t.frequency))
                        .foregroundStyle(by: .value("Series", "Target"))
                    PointMark(x: .value("Note", t.index), y: .value("Hz", t.frequency))
                        .foregroundStyle(by: .value("Series", "Target"))
                }
                ForEach(detected) { r in
                    LineMark(x: .value("Note", r.index), y: .value("Hz", r.detectedHz ?? 0))
                        .foregroundStyle(by: .value("Series", "You"))
                    PointMark(x: .value("Note", r.index), y: .value("Hz", r.detectedHz ?? 0))
                        .foregroundStyle(by: .value("Series", "You"))
                }
            }
            .chartForegroundStyleScale(["Target": Color.swarPurple, "You": Color.swarBlue])
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: Array(0..<targets.count)) { value in
                    AxisValueLabel {
                        if let i = value.as(Int.self), i < targets.count {
                            Text(targets[i].label).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 220)

            Text("This measures pitch matching only. It does not judge complete musical correctness such as gamak, rhythm, or expression.")
                .font(.footnote)
                .foregroundColor(.secondary)

            Button("Practice Again", action: onRestart)
                .buttonStyle(PrimaryButtonStyle())
        }
        .card()
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.swarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
