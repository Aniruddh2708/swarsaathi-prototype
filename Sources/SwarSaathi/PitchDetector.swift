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

    var startsNewSegment: Bool?

    init(time: Double, frequency: Double?, confidence: Double, level: Double,
         rawFrequency: Double? = nil, startsNewSegment: Bool = false) {
        self.time = time; self.frequency = frequency
        self.confidence = confidence; self.level = level; self.rawFrequency = rawFrequency
        self.startsNewSegment = startsNewSegment
    }
}

struct PitchConfig: Codable {
    var minFrequency: Double = 70      // Hz, lowest singing F0 searched
    var maxFrequency: Double = 1000    // Hz, highest singing F0 searched
    var silenceRMS: Float = 0.008      // below this = silence (no pitch computed)
    var minConfidence: Double = 0.85   // YIN: accept dips with CMND < 1 - minConfidence
    var frameSize: Int = 2048          // samples analysed per frame
    var hopSize: Int = 1024            // samples between frames (~21-23 ms)

    static func forCapture(sampleRate: Double) -> PitchConfig {
        var config = PitchConfig()
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate) else { return config }
        // Keep at least one independent update per 40 ms scoring cell, including at
        // faster tempos. Preserve the 44.1/48 kHz defaults.
        while Double(config.hopSize) / sampleRate > 0.025 { config.hopSize /= 2 }
        while Double(config.hopSize * 2) / sampleRate <= 0.025 { config.hopSize *= 2 }
        config.frameSize = max(512, config.hopSize * 2)
        if Double(config.frameSize - 257) < sampleRate / config.minFrequency { config.frameSize *= 2 }
        return config
    }

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
    private var rumbleReduced: [Float]
    private let mainsBases: [MainsBasis]

    // Least-squares sine/cosine basis, precomputed at the actual input rate.
    // Both columns are centred to match the analysed samples.
    private struct MainsBasis {
        let sine: [Double], cosine: [Double]
        let ss: Double, cc: Double, sc: Double

        init(hz: Double, rate: Double, count: Int) {
            let step = 2 * Double.pi * hz / rate
            let s = (0..<count).map { sin(step * Double($0)) }
            let c = (0..<count).map { cos(step * Double($0)) }
            let sm = s.reduce(0, +) / Double(count), cm = c.reduce(0, +) / Double(count)
            sine = s.map { $0 - sm }; cosine = c.map { $0 - cm }
            ss = sine.reduce(0) { $0 + $1 * $1 }
            cc = cosine.reduce(0) { $0 + $1 * $1 }
            sc = zip(sine, cosine).reduce(0) { $0 + $1.0 * $1.1 }
        }

        func fit(_ input: [Float]) -> (a: Double, b: Double, energy: Double) {
            var xs = 0.0, xc = 0.0
            for i in input.indices {
                xs += Double(input[i]) * sine[i]
                xc += Double(input[i]) * cosine[i]
            }
            let determinant = ss * cc - sc * sc
            let a = (xs * cc - xc * sc) / determinant, b = (xc * ss - xs * sc) / determinant
            return (a, b, a * xs + b * xc)
        }
    }

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
        self.mainsBases = configurationError == nil ? [50.0, 60.0].filter { $0 < config.minFrequency }.map {
            MainsBasis(hz: $0, rate: sampleRate, count: config.frameSize)
        } : []
        self.rumbleReduced = [Float](repeating: 0, count: configurationError == nil ? config.frameSize : 0)
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
        let result = estimateVoice(energy: energy)
        guard let raw = result, raw.frequency >= config.minFrequency, raw.frequency <= config.maxFrequency else {
            return PitchFrame(time: time, frequency: nil, confidence: 0, level: rms)
        }
        return PitchFrame(time: time, frequency: raw.frequency, confidence: raw.confidence,
                          level: rms, rawFrequency: raw.frequency)
    }

    private typealias Estimate = (frequency: Double, confidence: Double)
    private typealias HumFit = (basis: MainsBasis, a: Double, b: Double)

    private func estimateVoice(energy: Double) -> Estimate? {
        let primary = centered.withUnsafeBufferPointer { detect($0.baseAddress!) }
        guard (primary?.confidence ?? 0) < 0.985, let hum = mainsFit(energy: energy),
              let filtered = estimateWithoutRumble() else { return primary }
        guard let primary else { return filtered }
        guard abs(PitchMath.cents(detected: filtered.frequency, expected: primary.frequency)) > 600 else {
            return primary
        }
        // Two plausible but incompatible registers. Subtract only the fitted
        // mains sinusoid and require independent agreement before choosing.
        guard let verified = estimateRemoving(hum) else { return nil }
        if abs(PitchMath.cents(detected: verified.frequency, expected: filtered.frequency)) <= 30 { return filtered }
        if abs(PitchMath.cents(detected: verified.frequency, expected: primary.frequency)) <= 30 { return primary }
        return nil
    }

    private func estimateWithoutRumble() -> Estimate? {
        // A symmetric second difference suppresses very slow motion. All three
        // samples are inside the captured window; the shorter YIN window needs no padding.
        let stride = max(1, Int((sampleRate * 0.0005).rounded()))
        let length = centered.count - 2 * stride
        guard window - 2 * stride >= 256 else { return nil }
        var energy = 0.0
        for i in 0..<length {
            let value = centered[i + stride] * 2 - centered[i] - centered[i + 2 * stride]
            rumbleReduced[i] = value
            energy += Double(value) * Double(value)
        }
        let gate = Double(config.silenceRMS)
        guard energy >= Double(length) * gate * gate else { return nil }
        return rumbleReduced.withUnsafeBufferPointer { estimate($0.baseAddress!, windowLength: window - 2 * stride) }
    }

    private func estimateRemoving(_ hum: HumFit) -> Estimate? {
        var energy = 0.0
        for i in centered.indices {
            let residual = Double(centered[i]) - hum.a * hum.basis.sine[i] - hum.b * hum.basis.cosine[i]
            rumbleReduced[i] = Float(residual)
            energy += residual * residual
        }
        let gate = Double(config.silenceRMS)
        guard energy >= Double(centered.count) * gate * gate else { return nil }
        return rumbleReduced.withUnsafeBufferPointer { detect($0.baseAddress!) }
    }

    private func mainsFit(energy: Double) -> HumFit? {
        var best: HumFit?
        var minimum = 0.10 * energy
        for basis in mainsBases {
            let fit = basis.fit(centered)
            if fit.energy > minimum {
                minimum = fit.energy
                best = (basis, fit.a, fit.b)
            }
        }
        return best
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
        samples.withUnsafeBufferPointer { computeDifference($0.baseAddress!, windowLength: window) }
        return Array(diff.prefix(tauMax + 1))
    }

    private func computeDifference(_ x: UnsafePointer<Float>, windowLength n: Int) {
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
        estimate(x, windowLength: window)
    }

    private func estimate(_ x: UnsafePointer<Float>, windowLength: Int) -> (frequency: Double, confidence: Double)? {
        guard configurationError == nil else { return nil }
        // Step 1 preserves the supplied constant-window energy/dot formulation.
        computeDifference(x, windowLength: windowLength)

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

        // A strong second harmonic can make half a cycle look periodic. Require
        // a substantial absolute AND relative improvement around twice that lag.
        // Pure tones also repeat at twice their period, with no such improvement.
        if cmnd[tauEst] > 0.025, 2 * tauEst + 2 < tauMax {
            let center = 2 * tauEst
            var candidate = center
            for lag in (center - 2)...(center + 2) where cmnd[lag] < cmnd[candidate] { candidate = lag }
            if cmnd[candidate] < cmnd[tauEst] * 0.20 { tauEst = candidate }
        }

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
    private var newPitchCandidate: Double?
    private var lastOutput: Double?

    mutating func reset() {
        history.removeAll(); missing = 0; newPitchCandidate = nil; lastOutput = nil
    }

    mutating func process(_ raw: Double?) -> Double? {
        guard let f = raw else {
            missing += 1
            newPitchCandidate = nil
            if missing >= 3 { history.removeAll(); lastOutput = nil }
            return nil // unvoiced observations always break the graph immediately
        }
        guard f.isFinite, f > 0 else { return process(nil) }
        missing = 0

        // Two agreeing raw frames establish a new note. An isolated octave
        // spike still cannot move the trace. Only the display uses this state.
        if history.count >= 2, let last = lastOutput,
           abs(PitchMath.cents(detected: f, expected: last)) >= 90 {
            if let previous = newPitchCandidate, abs(PitchMath.cents(detected: f, expected: previous)) < 45 {
                history.removeAll(keepingCapacity: true)
                history.append(previous)
                lastOutput = nil
                newPitchCandidate = nil
            } else {
                let isolated = newPitchCandidate == nil
                newPitchCandidate = f
                if isolated { return lastOutput }
                // A continuing glide may have no pair within 45 cents. Let the
                // median follow its actual samples instead of freezing the trace.
            }
        } else {
            newPitchCandidate = nil
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
