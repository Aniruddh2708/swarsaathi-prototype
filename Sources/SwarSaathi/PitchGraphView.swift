import SwiftUI
import QuartzCore

/// Whole-exercise preview with a left-to-right playhead. Y is log-frequency.
/// Purple = target note (with tolerance band), blue = your voice.
struct PitchGraphView: View {
    let points: [GraphPoint]
    let ladder: [LadderLine]
    let currentTarget: Double
    let thresholds: AccuracyThresholds
    let active: Bool
    var timeline: PracticeTimeline? = nil
    var sessionStart: Double? = nil
    var window: Double = 8   // fallback span when no timeline is supplied

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { _ in
            let end = sessionStart.map { $0 + (timeline?.duration ?? 0) }
            let now = active ? CACurrentMediaTime() : (end ?? points.last?.t ?? CACurrentMediaTime())
            Canvas { context, size in
                render(context, size: size, now: now)
            }
        }
    }

    private func render(_ context: GraphicsContext, size: CGSize, now: Double) {
        guard let lowest = ladder.first?.hz else { return }
        let yMin = lowest * pow(2, -150.0 / 1200)
        let span = 1500.0   // one octave + 150 cents padding above and below
        let plot = CGRect(x: 58, y: 8, width: max(1, size.width - 66), height: max(1, size.height - 28))
        let duration = max(0.001, timeline?.duration ?? window)

        func yPos(_ hz: Double) -> CGFloat {
            let c = 1200 * log2(max(hz, 1) / yMin)
            let f = min(max(c / span, -0.05), 1.05)
            return plot.maxY - CGFloat(f) * plot.height
        }
        // Every layer uses the same fixed 0...duration axis. The complete
        // expected phrase is visible before microphone capture/count-in.
        func xPos(_ elapsed: Double) -> CGFloat {
            plot.minX + CGFloat(elapsed / duration) * plot.width
        }

        // Swar lanes + labels
        for line in ladder {
            let y = yPos(line.hz)
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: y))
            p.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(p, with: .color(Color.gray.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
            let isCurrent = abs(line.hz - currentTarget) < 0.01
            context.draw(Text("\(line.name) \(Int(line.hz.rounded()))")
                            .font(.system(size: 9, weight: isCurrent ? .bold : .regular))
                            .foregroundColor(isCurrent ? .swarPurple : .gray),
                         at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
        }

        // Data layer, clipped to the plot area
        var data = context
        data.clip(to: Path(plot))

        func drawTarget(_ hz: Double, from x0: CGFloat, to x1: CGFloat) {
            let top50 = yPos(hz * pow(2, thresholds.onTargetCents / 1200)), bot50 = yPos(hz * pow(2, -thresholds.onTargetCents / 1200))
            let top25 = yPos(hz * pow(2, thresholds.veryAccurateCents / 1200)), bot25 = yPos(hz * pow(2, -thresholds.veryAccurateCents / 1200))
            data.fill(Path(CGRect(x: x0, y: top50, width: max(0, x1 - x0), height: bot50 - top50)),
                      with: .color(Color.swarPurple.opacity(0.10)))
            data.fill(Path(CGRect(x: x0, y: top25, width: max(0, x1 - x0), height: bot25 - top25)),
                      with: .color(Color.swarPurple.opacity(0.12)))
            var line = Path()
            line.move(to: CGPoint(x: x0, y: yPos(hz)))
            line.addLine(to: CGPoint(x: x1, y: yPos(hz)))
            data.stroke(line, with: .color(.swarPurple), style: StrokeStyle(lineWidth: 2.5))
        }

        if let timeline = timeline {
            // Expected segments come from the clocked score even in silence.
            // No target point is inferred from a microphone observation.
            for note in timeline.notes {
                let x0 = xPos(note.start), x1 = xPos(note.end)
                if x1 >= plot.minX && x0 <= plot.maxX {
                    drawTarget(note.target.frequency, from: max(plot.minX, x0), to: min(plot.maxX, x1))
                    data.draw(Text(note.target.label).font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.swarPurple),
                              at: CGPoint(x: (x0 + x1) / 2, y: yPos(note.target.frequency) - 14))
                }
            }
        } else {
            drawTarget(currentTarget, from: plot.minX, to: plot.maxX)
        }

        // Detected pitch line (gaps for silence)
        var path = Path()
        var prev: GraphPoint?
        for p in points {
            guard let start = sessionStart, let hz = p.hz,
                  p.t >= start, p.t <= start + duration else { prev = nil; continue }
            let pt = CGPoint(x: xPos(p.t - start), y: yPos(hz))
            if let pr = prev, p.t - pr.t < 0.25 { path.addLine(to: pt) } else { path.move(to: pt) }
            prev = p
        }
        data.stroke(path, with: .color(.swarBlue),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        if let start = sessionStart, let last = points.last, let hz = last.hz, now - last.t < 0.4 {
            let color = thresholds.classify(PitchMath.cents(detected: hz, expected: last.targetHz)).color
            let c = CGPoint(x: xPos(last.t - start), y: yPos(hz))
            data.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white))
            data.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(color))
        }

        // Clock progress moves; targets remain fixed. During count-in it stays
        // at zero, and after completion the whole phrase remains available.
        if let start = sessionStart {
            let elapsed = min(duration, max(0, now - start))
            let x = xPos(elapsed)
            var playhead = Path()
            playhead.move(to: CGPoint(x: x, y: plot.minY))
            playhead.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(playhead, with: .color(.primary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        // Fixed time axis labels
        context.draw(Text("0 s").font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.minX, y: size.height - 2), anchor: .bottomLeading)
        context.draw(Text(String(format: "%.1f s", duration)).font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.maxX, y: size.height - 2), anchor: .bottomTrailing)
        context.draw(Text("Time →").font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.midX, y: size.height - 2), anchor: .bottom)
    }
}
