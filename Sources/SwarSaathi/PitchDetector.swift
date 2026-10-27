import Foundation
import Accelerate

/// One analysis result, delivered on the main thread.
struct PitchFrame {
    let time: Double          // CACurrentMediaTime() seconds
    let frequency: Double?    // smoothed F0 in Hz, nil = silence / unvoiced / unreliable
    let confidence: Double    // 0...1 (1 - YIN CMND value)
    let level: Double         // RMS 0...1
}

struct PitchConfig {
    var minFrequency: Double = 70      // Hz, lowest singing F0 searched
    var maxFrequency: Double = 1000    // Hz, highest singing F0 searched
    var silenceRMS: Float = 0.008      // below this = silence (no pitch computed)
    var minConfidence: Double = 0.85   // YIN: accept dips with CMND < 1 - minConfidence
    var frameSize: Int = 2048          // samples analysed per frame
    var hopSize: Int = 1024            // samples between frames (~21-23 ms)
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
/// Difference function is computed with vDSP dot products (Accelerate).
final class YINPitchDetector {
    private let sampleRate: Double
    private let threshold: Float
    private let tauMin: Int
    private let tauMax: Int
    private let window: Int
    private var diff: [Float]
    private var cmnd: [Float]

    init(sampleRate: Double, config: PitchConfig) {
        self.sampleRate = sampleRate
        self.threshold = Float(1.0 - config.minConfidence)
        self.tauMin = max(2, Int(sampleRate / config.maxFrequency))
        self.tauMax = Int(sampleRate / config.minFrequency)
        self.window = max(256, config.frameSize - Int(sampleRate / config.minFrequency) - 1)
        self.diff = [Float](repeating: 0, count: tauMax + 2)
        self.cmnd = [Float](repeating: 1, count: tauMax + 2)
    }

    /// `x` must point to at least `tauMax + window + 1` samples (DC-removed).
    func detect(_ x: UnsafePointer<Float>) -> (frequency: Double, confidence: Double)? {
        let n = window
        let vn = vDSP_Length(n)

        // Step 1: difference function d(tau) = e0 + e(tau) - 2 r(tau)
        var e0: Float = 0
        vDSP_svesq(x, 1, &e0, vn)
        if e0 <= 1e-9 { return nil }
        var eTau = e0
        diff[0] = 0
        for tau in 1...tauMax {
            let a = x[tau - 1], b = x[tau - 1 + n]
            eTau += b * b - a * a
            var r: Float = 0
            vDSP_dotpr(x, 1, x + tau, 1, &r, vn)
            diff[tau] = max(0, e0 + eTau - 2 * r)
        }

        // Step 2: cumulative mean normalised difference
        cmnd[0] = 1
        var running: Float = 0
        for tau in 1...tauMax {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }

        // Step 3: first dip below threshold, then walk down to its local minimum.
        // Choosing the FIRST dip (smallest period) avoids sub-harmonic (octave-low) errors.
        var tauEst = -1
        var tau = tauMin
        while tau < tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 < tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEst = tau
                break
            }
            tau += 1
        }
        if tauEst < 0 { return nil }   // no reliable periodicity -> reject

        // Step 4: parabolic interpolation for sub-sample accuracy
        var better = Double(tauEst)
        let s0 = cmnd[tauEst - 1], s1 = cmnd[tauEst], s2 = cmnd[tauEst + 1]
        let denom = s0 + s2 - 2 * s1
        if abs(denom) > 1e-9 { better += Double((s0 - s2) / (2 * denom)) }

        let f = sampleRate / better
        let confidence = Double(1 - min(max(s1, 0), 1))
        return (f, confidence)
    }
}

/// Temporal smoothing: octave-jump suppression, median-of-5, light log-domain EMA.
struct PitchSmoother {
    private var history: [Double] = []
    private var missing = 0
    private var octaveCandidates = 0
    private var lastOutput: Double?

    mutating func reset() {
        history.removeAll(); missing = 0; octaveCandidates = 0; lastOutput = nil
    }

    mutating func process(_ raw: Double?) -> Double? {
        guard let f = raw else {
            missing += 1
            octaveCandidates = 0
            if missing >= 3 { history.removeAll(); lastOutput = nil }
            return missing <= 1 ? lastOutput : nil   // bridge a single dropped frame
        }
        missing = 0

        // A sudden jump of exactly one octave is usually an estimation error.
        // Accept it only if it persists for several frames.
        if history.count >= 3, let ref = PitchMath.median(history) {
            let c = 1200 * log2(f / ref)
            if abs(abs(c) - 1200) < 70 {
                octaveCandidates += 1
                if octaveCandidates < 4 { return lastOutput }
                history.removeAll()
                lastOutput = nil
            } else {
                octaveCandidates = 0
            }
        }

        history.append(f)
        if history.count > 5 { history.removeFirst() }
        let m = PitchMath.median(history) ?? f
        var out = m
        if let last = lastOutput {
            let l = log2(last)
            out = pow(2, l + 0.65 * (log2(m) - l))
        }
        lastOutput = out
        return out
    }
}
