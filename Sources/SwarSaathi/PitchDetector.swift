import Foundation
#if canImport(Accelerate)
import Accelerate
#else
// Portability shim for testing the SAME original constant-window YIN formula.
// The Apple application continues to use Accelerate/vDSP.
private typealias vDSP_Length = UInt
private func vDSP_svesq(_ x: UnsafePointer<Float>, _ stride: Int,
                        _ result: inout Float, _ n: UInt) {
    result = 0
    for i in 0..<Int(n) { result += x[i * stride] * x[i * stride] }
}
private func vDSP_dotpr(_ x: UnsafePointer<Float>, _ sx: Int,
                        _ y: UnsafePointer<Float>, _ sy: Int,
                        _ result: inout Float, _ n: UInt) {
    result = 0
    for i in 0..<Int(n) { result += x[i * sx] * y[i * sy] }
}
#endif

/// One analysis result, delivered on the main thread.
struct PitchFrame: Codable {
    let time: Double          // monotonic audio-window center, seconds
    let frequency: Double?    // smoothed F0 in Hz, nil = silence / unvoiced / unreliable
    let confidence: Double    // 0...1 (1 - YIN CMND value)
    let level: Double         // RMS 0...1
    let rawFrequency: Double? // independent accepted YIN F0; use for calibration/scoring

    init(time: Double, frequency: Double?, confidence: Double, level: Double,
         rawFrequency: Double? = nil) {
        self.time = time; self.frequency = frequency
        self.confidence = confidence; self.level = level; self.rawFrequency = rawFrequency
    }
}

struct PitchConfig: Codable {
    var minFrequency: Double = 70      // Hz, lowest singing F0 searched
    var maxFrequency: Double = 1000    // Hz, highest singing F0 searched
    var silenceRMS: Float = 0.008      // below this = silence (no pitch computed)
    var minConfidence: Double = 0.85   // YIN: accept dips with CMND < 1 - minConfidence
    var frameSize: Int = 2048          // samples analysed per frame
    var hopSize: Int = 1024            // samples between frames (~21-23 ms)

    func validationError(sampleRate: Double) -> String? {
        guard sampleRate.isFinite, sampleRate > 0,
              minFrequency.isFinite, maxFrequency.isFinite,
              minFrequency > 0, minFrequency < maxFrequency,
              maxFrequency < sampleRate / 2,
              minConfidence.isFinite, minConfidence > 0, minConfidence < 1,
              silenceRMS.isFinite, silenceRMS >= 0,
              frameSize >= 512, hopSize > 0, hopSize <= frameSize else {
            return "Invalid sample rate, frequency, confidence, level or frame configuration."
        }
        // Preserve the original fixed-window YIN definition. The input must
        // contain the entire shifted window plus the interpolation neighbor.
        guard sampleRate / minFrequency <= Double(frameSize - 257),
              Int(sampleRate / minFrequency) > max(2, Int(sampleRate / maxFrequency)) + 1 else {
            return "Analysis window is too short for the requested pitch range."
        }
        return nil
    }
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
/// Difference function is computed with vDSP dot products (Accelerate).
final class YINPitchDetector {
    private let sampleRate: Double
    private let threshold: Float
    private let tauMin: Int
    private let tauMax: Int
    private let window: Int
    private let config: PitchConfig
    let configurationError: String?
    private var diff: [Float]
    private var cmnd: [Float]
    private var centered: [Float]

    var requiredSampleCount: Int { configurationError == nil ? window + tauMax + 1 : 0 }
    var differenceWindowSize: Int { window }

    init(sampleRate: Double, config: PitchConfig) {
        self.sampleRate = sampleRate
        self.config = config
        self.configurationError = config.validationError(sampleRate: sampleRate)
        self.threshold = configurationError == nil ? Float(1.0 - config.minConfidence) : 0
        self.tauMin = configurationError == nil ? max(2, Int(sampleRate / config.maxFrequency)) : 2
        self.tauMax = configurationError == nil ? Int(sampleRate / config.minFrequency) : 3
        self.window = configurationError == nil ? config.frameSize - Int(sampleRate / config.minFrequency) - 1 : 0
        self.diff = [Float](repeating: 0, count: tauMax + 2)
        self.cmnd = [Float](repeating: 1, count: tauMax + 2)
        self.centered = [Float](repeating: 0, count: configurationError == nil ? config.frameSize : 0)
    }

    /// Checked, shared preprocessing for file/unit tests and capture workers.
    /// Reuses scratch storage; this object is confined to one processing queue.
    func analyze(_ samples: UnsafePointer<Float>, count: Int, time: Double) -> PitchFrame {
        let empty = PitchFrame(time: time, frequency: nil, confidence: 0, level: 0)
        guard configurationError == nil, count >= config.frameSize, time.isFinite else { return empty }
        let n = config.frameSize
        var sum: Double = 0
        for i in 0..<n {
            guard samples[i].isFinite else { return empty }
            sum += Double(samples[i])
        }
        let mean = Float(sum / Double(n))
        var energy: Double = 0
        for i in 0..<n {
            centered[i] = samples[i] - mean
            energy += Double(centered[i]) * Double(centered[i])
        }
        let rms = sqrt(energy / Double(n))
        guard rms >= Double(config.silenceRMS) else {
            return PitchFrame(time: time, frequency: nil, confidence: 0, level: rms)
        }
        let result = centered.withUnsafeBufferPointer { detect($0.baseAddress!) }
        guard let raw = result, raw.frequency >= config.minFrequency, raw.frequency <= config.maxFrequency else {
            return PitchFrame(time: time, frequency: nil, confidence: 0, level: rms)
        }
        return PitchFrame(time: time, frequency: raw.frequency, confidence: raw.confidence,
                          level: rms, rawFrequency: raw.frequency)
    }

    func analyze(_ samples: [Float], time: Double = 0) -> PitchFrame {
        guard !samples.isEmpty else { return PitchFrame(time: time, frequency: nil, confidence: 0, level: 0) }
        return samples.withUnsafeBufferPointer { analyze($0.baseAddress!, count: samples.count, time: time) }
    }

    /// A counted pointer entry point for callers that do not need preprocessing.
    func detect(_ x: UnsafePointer<Float>, count: Int) -> (frequency: Double, confidence: Double)? {
        guard configurationError == nil, count >= requiredSampleCount else { return nil }
        return detect(x)
    }

    /// Diagnostic access to the exact production difference calculation.
    func differenceValues(_ samples: [Float]) -> [Float]? {
        guard configurationError == nil, samples.count >= requiredSampleCount,
              samples.prefix(requiredSampleCount).allSatisfy({ $0.isFinite }) else { return nil }
        samples.withUnsafeBufferPointer { computeDifference($0.baseAddress!) }
        return Array(diff.prefix(tauMax + 1))
    }

    private func computeDifference(_ x: UnsafePointer<Float>) {
        let n = window
        let vn = vDSP_Length(n)
        var e0: Float = 0
        vDSP_svesq(x, 1, &e0, vn)
        var eTau = e0
        diff[0] = 0
        for tau in 1...tauMax {
            let a = x[tau - 1], b = x[tau - 1 + n]
            eTau += b * b - a * a
            var r: Float = 0
            vDSP_dotpr(x, 1, x + tau, 1, &r, vn)
            diff[tau] = max(0, e0 + eTau - 2 * r)
        }
    }

    /// `x` must point to at least `tauMax + window + 1` samples (DC-removed).
    func detect(_ x: UnsafePointer<Float>) -> (frequency: Double, confidence: Double)? {
        guard configurationError == nil else { return nil }
        // Step 1 preserves the supplied constant-window energy/dot formulation.
        computeDifference(x)

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
        guard f.isFinite, f > 0, confidence.isFinite, confidence >= config.minConfidence else { return nil }
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
            return nil // unvoiced observations always break the graph immediately
        }
        guard f.isFinite, f > 0 else { return process(nil) }
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
