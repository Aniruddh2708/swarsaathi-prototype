import Foundation

/// Offline, single-tap linear echo model. Never used in live capture or scoring.
struct ReferenceEchoModel {
    let delay: Int
    let gain: Double
    let calibrationCorrelation: Double
    /// Fit only during a separately known reference-only calibration. No singing.
    static func fit(reference: [Float], microphone: [Float], maxDelay: Int) -> Self? {
        guard reference.count == microphone.count, maxDelay >= 0,
              maxDelay < reference.count/2, reference.count > 128,
              reference.allSatisfy({ $0.isFinite }), microphone.allSatisfy({ $0.isFinite }) else { return nil }
        var best: Self?
        for delay in 0...maxDelay {
            var xx = 0.0, yy = 0.0, xy = 0.0
            // Same microphone interval for every candidate lag.
            for i in maxDelay..<reference.count {
                let x = Double(reference[i-delay]), y = Double(microphone[i])
                xx += x*x; yy += y*y; xy += x*y
            }
            guard xx > 1e-12, yy > 1e-12 else { continue }
            let corr = abs(xy)/sqrt(xx*yy)
            if corr > (best?.calibrationCorrelation ?? 0) {
                best = Self(delay:delay,gain:xy/xx,calibrationCorrelation:corr)
            }
        }
        guard let model = best, model.calibrationCorrelation >= 0.8, abs(model.gain) <= 2 else { return nil }
        return model
    }
    func subtract(reference: [Float], microphone: [Float]) -> [Float]? {
        guard reference.count == microphone.count, delay >= 0, delay < reference.count,
              gain.isFinite, abs(gain) <= 2, reference.allSatisfy({ $0.isFinite }),
              microphone.allSatisfy({ $0.isFinite }) else { return nil }
        var result = microphone
        for i in delay..<result.count { result[i] -= Float(gain)*reference[i-delay] }
        return result
    }
}

enum AttributionResearch {
    static func nearestWindow(time: Double, rate: Double, frame: Int, hop: Int) -> Int {
        Int(((time*rate-Double(frame)/2)/Double(hop)).rounded())
    }
    /// Distance to nearest annotated voicing change (midpoint of label pair).
    static func boundaryDistance(time: Double, boundaries: [Double]) -> Double? {
        boundaries.map { abs($0-time) }.min()
    }
    /// Independent descriptive waveform statistic, not a voice/source classifier.
    static func correlation(samples: [Float], start: Int, count: Int, lag: Int) -> Double? {
        guard start >= 0, count > lag, lag > 0, start+count <= samples.count else { return nil }
        let n = count-lag
        var sx=0.0, sy=0.0, xx=0.0, yy=0.0, xy=0.0
        for i in 0..<n {
            let x=Double(samples[start+i]), y=Double(samples[start+i+lag])
            sx += x; sy += y; xx += x*x; yy += y*y; xy += x*y
        }
        let a=xx-sx*sx/Double(n), b=yy-sy*sy/Double(n)
        guard a > 1e-12, b > 1e-12 else { return nil }
        return (xy-sx*sy/Double(n))/sqrt(a*b)
    }
}
