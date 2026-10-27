import SwiftUI
import QuartzCore

/// Scrolling pitch graph. Y axis is a log-frequency (musical) scale with a lane for each swar.
/// Purple = target note (with tolerance band), blue = your voice.
struct PitchGraphView: View {
    let points: [GraphPoint]
    let ladder: [LadderLine]
    let currentTarget: Double
    let thresholds: AccuracyThresholds
    let active: Bool
    var window: Double = 8   // seconds shown

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { _ in
            let now = active ? CACurrentMediaTime() : (points.last?.t ?? CACurrentMediaTime())
            Canvas { context, size in
                render(context, size: size, now: now)
            }
        }
    }

    private func render(_ context: GraphicsContext, size: CGSize, now: Double) {
        guard let lowest = ladder.first?.hz else { return }
        let yMin = lowest * pow(2, -150.0 / 1200)
        let span = 1500.0   // one octave + 150 cents padding above and below
        let plot = CGRect(x: 58, y: 8, width: size.width - 66, height: size.height - 28)

        func yPos(_ hz: Double) -> CGFloat {
            let c = 1200 * log2(max(hz, 1) / yMin)
            let f = min(max(c / span, -0.05), 1.05)
            return plot.maxY - CGFloat(f) * plot.height
        }
        func xPos(_ t: Double) -> CGFloat {
            plot.maxX - CGFloat((now - t) / window) * plot.width
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
            let top50 = yPos(hz * pow(2, 50.0 / 1200)), bot50 = yPos(hz * pow(2, -50.0 / 1200))
            let top25 = yPos(hz * pow(2, 25.0 / 1200)), bot25 = yPos(hz * pow(2, -25.0 / 1200))
            data.fill(Path(CGRect(x: x0, y: top50, width: max(0, x1 - x0), height: bot50 - top50)),
                      with: .color(Color.swarPurple.opacity(0.10)))
            data.fill(Path(CGRect(x: x0, y: top25, width: max(0, x1 - x0), height: bot25 - top25)),
                      with: .color(Color.swarPurple.opacity(0.12)))
            var line = Path()
            line.move(to: CGPoint(x: x0, y: yPos(hz)))
            line.addLine(to: CGPoint(x: x1, y: yPos(hz)))
            data.stroke(line, with: .color(.swarPurple), style: StrokeStyle(lineWidth: 2.5))
        }

        if points.isEmpty {
            drawTarget(currentTarget, from: plot.minX, to: plot.maxX)
        } else {
            var i = 0
            while i < points.count {
                let tHz = points[i].targetHz
                var j = i
                while j + 1 < points.count && points[j + 1].targetHz == tHz { j += 1 }
                let x0 = max(plot.minX, xPos(points[i].t))
                let x1 = j == points.count - 1 ? plot.maxX : xPos(points[j + 1].t)
                drawTarget(tHz, from: x0, to: x1)
                i = j + 1
            }
        }

        // Detected pitch line (gaps for silence)
        var path = Path()
        var prev: GraphPoint?
        for p in points {
            guard let hz = p.hz else { prev = nil; continue }
            let pt = CGPoint(x: xPos(p.t), y: yPos(hz))
            if let pr = prev, p.t - pr.t < 0.25 { path.addLine(to: pt) } else { path.move(to: pt) }
            prev = p
        }
        data.stroke(path, with: .color(.swarBlue),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        if let last = points.last, let hz = last.hz, now - last.t < 0.4 {
            let color = thresholds.classify(PitchMath.cents(detected: hz, expected: last.targetHz)).color
            let c = CGPoint(x: xPos(last.t), y: yPos(hz))
            data.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white))
            data.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(color))
        }

        // Time axis labels
        context.draw(Text("\(Int(window)) s ago").font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.minX, y: size.height - 2), anchor: .bottomLeading)
        context.draw(Text("now").font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.maxX, y: size.height - 2), anchor: .bottomTrailing)
        context.draw(Text("Time →").font(.system(size: 9)).foregroundColor(.gray),
                     at: CGPoint(x: plot.midX, y: size.height - 2), anchor: .bottom)
    }
}
