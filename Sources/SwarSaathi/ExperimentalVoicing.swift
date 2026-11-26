import Foundation

/// Research-only: never used by PitchEngine or the production scorer.
enum VoicingExperiment: String, CaseIterable {
    case levelAware = "level-aware"
    case adaptiveGate = "adaptive-gate"
    case boundedNormalization = "bounded-normalization"
}
enum RecoveryStage: String {
    case baselineAccepted, baselineRejected, belowRecoveryFloor, noiseContrast,
         clippingRisk, recoveryPeriodicity, recoveryConfidence, awaitingAgreement, recovered
}
/// Worker-confined, causal experiment. The previous-window lower energy quantile
/// is a proxy, not a validated noise estimator. No reference labels or targets.
final class ExperimentalVoicing {
    let mode: VoicingExperiment
    private let baseline: YINPitchDetector
    private let recovery: YINPitchDetector
    private let config: PitchConfig
    private let rate: Double
    private var history: [Double] = []
    private var scratch: [Float]
    private var previous: (hz: Double, time: Double)?
    private(set) var stage: RecoveryStage = .baselineRejected
    private(set) var baselineRejection: PitchRejection?
    private(set) var noiseProxy: Double?
    private(set) var appliedGain: Double = 1

    init(sampleRate: Double, config: PitchConfig, mode: VoicingExperiment) {
        self.mode = mode; self.config = config; self.rate = sampleRate
        baseline = YINPitchDetector(sampleRate: sampleRate, config: config)
        var alternate = config
        // Explicit experimental floor, not a production threshold change.
        if mode != .boundedNormalization { alternate.silenceRMS = config.silenceRMS / 2 }
        recovery = YINPitchDetector(sampleRate: sampleRate, config: alternate)
        scratch = [Float](repeating: 0, count: max(0, config.frameSize))
    }
    var configurationError: String? { baseline.configurationError ?? recovery.configurationError }

    func analyze(_ samples: UnsafePointer<Float>, count: Int, time: Double) -> PitchFrame {
        let original = baseline.analyze(samples, count: count, time: time)
        baselineRejection = baseline.lastAnalysisRejection
        stage = .baselineRejected; appliedGain = 1
        // Only previously observed, valid frames contribute. No labels.
        noiseProxy = nil
        if history.count >= 20 {
            let sorted = history.sorted()
            noiseProxy = sorted[(sorted.count-1)/5]
        }
        defer {
            if baselineRejection != .invalidInput && original.level.isFinite {
                history.append(original.level)
                if history.count > 64 { history.removeFirst() }
            }
        }
        if original.rawFrequency != nil {
            previous = nil; stage = .baselineAccepted; return original
        }
        guard baselineRejection == .belowRMS else { previous = nil; return original }
        let gate = Double(config.silenceRMS)
        guard gate > 0, original.level >= gate/2, original.level < gate else {
            previous = nil; stage = .belowRecoveryFloor; return original
        }
        if mode != .levelAware {
            // Bootstrap conservatively; require 3x RMS contrast against the
            // causal proxy. If the proxy is high, do not recover quiet frames.
            guard let floor = noiseProxy, original.level >= 3 * max(floor, 0.0005) else {
                previous = nil; stage = .noiseContrast; return original
            }
        }
        let candidate: PitchFrame
        if mode == .boundedNormalization {
            let gain = min(2, gate / original.level * 1.001)
            var sum = 0.0
            for i in 0..<config.frameSize { sum += Double(samples[i]) }
            let mean = sum / Double(config.frameSize)
            for i in 0..<config.frameSize {
                let x = (Double(samples[i])-mean)*gain
                guard abs(x) <= 1 else { previous = nil; stage = .clippingRisk; return original }
                scratch[i] = Float(x)
            }
            appliedGain = gain
            candidate = recovery.analyze(scratch, time: time)
        } else {
            candidate = recovery.analyze(samples, count: count, time: time)
        }
        guard let hz = candidate.rawFrequency else {
            previous = nil; stage = .recoveryPeriodicity; return original
        }
        // Baseline minimum confidence stays 0.85; recovered low-energy
        // candidates require stricter periodicity, never a lower threshold.
        guard candidate.confidence >= max(config.minConfidence, 0.93) else {
            previous = nil; stage = .recoveryConfidence; return original
        }
        let prior = previous
        previous = (hz, time)
        let maxGap = 1.5 * Double(config.hopSize)/rate
        guard let p = prior, time > p.time, time-p.time <= maxGap,
              abs(PitchMath.cents(detected: hz, expected: p.hz)) <= 50 else {
            stage = .awaitingAgreement; return original
        }
        stage = .recovered
        // Keep measured original RMS; no backfill, no score reinterpretation.
        return PitchFrame(time: time, frequency: hz, confidence: candidate.confidence,
                          level: original.level, rawFrequency: hz)
    }
    func analyze(_ samples: [Float], time: Double) -> PitchFrame {
        guard !samples.isEmpty else {
            previous = nil; stage = .baselineRejected; baselineRejection = .invalidInput
            noiseProxy = nil; appliedGain = 1
            return baseline.analyze(samples, time: time)
        }
        return samples.withUnsafeBufferPointer { analyze($0.baseAddress!, count: $0.count, time: time) }
    }
}

/// Signed octave multiples, not just +/-1200 cents. No octave folding.
enum DevelopmentOctaveError {
    static func offset(detected: Double, reference: Double) -> Int? {
        guard detected.isFinite, reference.isFinite, detected > 0, reference > 0 else { return nil }
        let cents = 1200 * (log2(detected)-log2(reference))
        let multiple = Int((cents/1200).rounded())
        guard multiple != 0, abs(cents-1200*Double(multiple)) <= 50 else { return nil }
        return multiple
    }
}
