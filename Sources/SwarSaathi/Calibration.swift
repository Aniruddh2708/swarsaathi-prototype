import Foundation

/// Raw detector evidence. Missing frames remain in temporal coverage; graph
/// smoothing and exercise targets never supply a calibration frequency.
struct CalibrationObservation: Codable, Equatable {
    let time: Double
    let frequency: Double?
    let confidence: Double
}

struct CalibrationSample: Codable, Equatable {
    let medianHz: Double
    let stabilityCents: Double
    let spreadCents: Double
    let voicedSeconds: Double
    let usableSeconds: Double
    let coverage: Double
    let frameCount: Int
}

struct SaRecommendation: Codable, Equatable {
    var saHz: Double
    let lowerHz: Double
    let upperHz: Double
    let measuredHz: [Double]
    let selectionMethod: String
    let rangeCenterHz: Double
    let preferredSaHz: Double
    var explanation: String

    /// Whether the reference pitch itself is inside the recorded boundaries.
    /// Exercise notes are checked independently by Alankaar.fits.
    func supports(_ frequency: Double) -> Bool {
        frequency.isFinite && frequency > 0 &&
            frequency >= lowerHz - 1e-9 && frequency <= upperHz + 1e-9
    }
}

enum CalibrationFailure: LocalizedError {
    case inconclusive(String)
    var errorDescription: String? {
        switch self {
        case .inconclusive(let reason): return "Calibration inconclusive — please retry. \(reason)"
        }
    }
}

enum CalibrationAnalyzer {
    static let trimSeconds = 0.3
    static let minimumConfidence = 0.85
    static let minimumVoicedSeconds = 1.0
    static let minimumCoverage = 0.70
    static let minimumFrames = 20
    static let maximumSpreadCents = 80.0
    static let marginCents = 50.0

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Explicit recording bounds keep absent beginnings/endings in the evidence.
    /// One accepted observation supports at most 50 ms, preventing stale or sparse
    /// repeated readings from impersonating sustained voice.
    static func summarize(_ observations: [CalibrationObservation],
                          recordingStart: Double? = nil,
                          recordingEnd: Double? = nil) throws -> CalibrationSample {
        var unique: [Double: CalibrationObservation] = [:]
        for row in observations where row.time.isFinite { unique[row.time] = row }
        let rows = unique.values.sorted { $0.time < $1.time }
        guard rows.count >= minimumFrames, let first = rows.first, let last = rows.last else {
            throw CalibrationFailure.inconclusive("Too few timestamped analysis frames.")
        }
        let outerStart = recordingStart ?? first.time
        let outerEnd = recordingEnd ?? last.time
        guard outerStart.isFinite, outerEnd.isFinite else {
            throw CalibrationFailure.inconclusive("Invalid recording timestamps.")
        }
        let start = outerStart + trimSeconds
        let end = outerEnd - trimSeconds
        let usable = end - start
        guard usable >= minimumVoicedSeconds else {
            throw CalibrationFailure.inconclusive("Hold one comfortable Aa for about three seconds.")
        }
        let intervals = zip(rows.dropFirst(), rows).map { $0.0.time - $0.1.time }
        let hop = min(0.05, PitchMath.median(intervals) ?? 0)
        let accepted = rows.filter { row in
            guard row.time >= start, row.time <= end,
                  row.confidence.isFinite, row.confidence >= minimumConfidence,
                  row.confidence <= 1, let frequency = row.frequency else { return false }
            return frequency.isFinite && frequency > 0
        }
        var voiced = 0.0
        var previousEnd = -Double.infinity
        for row in accepted {
            let left = max(start, row.time - hop / 2)
            let right = min(end, row.time + hop / 2)
            voiced += max(0, right - max(left, previousEnd))
            previousEnd = max(previousEnd, right)
        }
        let coverage = voiced / usable
        guard accepted.count >= minimumFrames,
              voiced >= minimumVoicedSeconds - 1e-9,
              coverage >= minimumCoverage - 1e-9 else {
            throw CalibrationFailure.inconclusive(String(format:
                "Reliable voice %.2f s, %.0f%% coverage, %d frames. Need at least 1 s, 70%% and 20 frames; sing steadily without strain.",
                voiced, 100 * coverage, accepted.count))
        }
        let frequencies = accepted.compactMap { $0.frequency }
        guard let median = PitchMath.median(frequencies) else {
            throw CalibrationFailure.inconclusive("No reliable voice remained.")
        }
        let deviations = frequencies.map { PitchMath.cents(detected: $0, expected: median) }
        let spread = percentile(deviations, 0.9) - percentile(deviations, 0.1)
        guard spread <= maximumSpreadCents else {
            throw CalibrationFailure.inconclusive(String(format:
                "Pitch moved across %.0f cents; hold a single steady vowel.", spread))
        }
        let center = PitchMath.median(deviations) ?? 0
        let stability = 1.4826 * (PitchMath.median(deviations.map { abs($0 - center) }) ?? 0)
        return CalibrationSample(medianHz: median, stabilityCents: stability,
                                 spreadCents: spread, voicedSeconds: voiced,
                                 usableSeconds: usable, coverage: coverage, frameCount: accepted.count)
    }

    /// Voice-only starting-point heuristic, independent of exercise definitions.
    /// Balance the measured range center and comfortable middle in log frequency.
    /// The singer confirms the reference; this does not infer a unique personal Sa.
    static func recommend(samples: [CalibrationSample]) throws -> SaRecommendation {
        guard samples.count == 3 else {
            throw CalibrationFailure.inconclusive("Three measured samples are required.")
        }
        for sample in samples {
            guard sample.medianHz.isFinite, sample.medianHz > 0,
                  sample.stabilityCents.isFinite, sample.stabilityCents >= 0,
                  sample.spreadCents.isFinite, sample.spreadCents >= 0,
                  sample.spreadCents <= maximumSpreadCents,
                  sample.voicedSeconds.isFinite,
                  sample.voicedSeconds >= minimumVoicedSeconds - 1e-9,
                  sample.usableSeconds.isFinite, sample.usableSeconds > 0,
                  sample.voicedSeconds <= sample.usableSeconds + 1e-9,
                  sample.coverage.isFinite, sample.coverage >= minimumCoverage - 1e-9,
                  sample.coverage <= 1 + 1e-9,
                  abs(sample.coverage - sample.voicedSeconds / sample.usableSeconds) <= 1e-9,
                  sample.frameCount >= minimumFrames else {
                throw CalibrationFailure.inconclusive("Unreliable or inconsistent sample statistics.")
            }
        }
        let values = samples.map { $0.medianHz }
        // Repeated/close vowels need no minimum interval. Reject contradictions
        // only when the labelled medians reverse beyond overlapping measured
        // half-spreads plus a 5-cent numerical floor (above measured synthetic
        // detector error). This tolerance concerns uncertain calibration labels,
        // not the unchanged exercise pitch-match thresholds.
        for lowIndex in 0..<2 {
            for highIndex in (lowIndex + 1)..<3 {
                let tolerance = 5 + (samples[lowIndex].spreadCents + samples[highIndex].spreadCents) / 2
                let reversal = PitchMath.cents(detected: values[lowIndex], expected: values[highIndex])
                guard reversal <= tolerance + 1e-9 else {
                    throw CalibrationFailure.inconclusive("The low/middle/high labels contradict the measured pitches beyond their uncertainty. Repeat the labelled comfortable vowels without strain; no minimum pitch separation is required.")
                }
            }
        }
        let lower = (values.min() ?? 0) * pow(2, marginCents / 1200)
        let upper = (values.max() ?? 0) * pow(2, -marginCents / 1200)
        guard lower.isFinite, upper.isFinite, lower < upper else {
            throw CalibrationFailure.inconclusive("These samples do not establish a usable range. Do not force your voice.")
        }
        // Equal weight to range center and measured comfortable middle, in cents.
        // This is a disclosed reference-pitch heuristic, not an exercise fit.
        let rangeCenter = exp2((log2(lower) + log2(upper)) / 2)
        let preferred = exp2((log2(rangeCenter) + log2(values[1])) / 2)
        let firstMidi = Int(ceil(69 + 12 * log2(lower / 440) - 1e-10))
        let lastMidi = Int(floor(69 + 12 * log2(upper / 440) + 1e-10))
        guard firstMidi <= lastMidi else {
            throw CalibrationFailure.inconclusive("No semitone-grid tonic fits these conservative boundaries.")
        }
        let candidates = (firstMidi...lastMidi).map { midi -> (frequency: Double, cost: Double) in
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let cost = abs(PitchMath.cents(detected: frequency, expected: preferred))
            return (frequency, cost)
        }
        let best = candidates.map { $0.cost }.min() ?? .infinity
        let near = candidates.filter { $0.cost <= best + 5 + 1e-9 }
        guard let choice = near.min(by: { $0.frequency < $1.frequency }) else {
            throw CalibrationFailure.inconclusive("No trial tonic is supported.")
        }
        let sampleText = values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
        var explanation = "Measured low/middle/high: \(sampleText) Hz. Boundaries use the measured extrema, inset by 50 cents at each edge. The starting Sa balances the logarithmic range center and comfortable middle equally, then uses a fitting semitone-grid reference. No exercise or swar ratio enters this calculation. Exercise range checks happen after confirmation without changing Sa. "
        if abs(PitchMath.cents(detected: values[1], expected: values[0])) < 100 {
            explanation += "Low and middle are similar; both remain valid measurements, with limited independent range evidence. "
        }
        if near.count > 1 {
            explanation += "The ranking is ambiguous within five cents; the lower fitting grid candidate is chosen consistently. "
        }
        explanation += "Three short vowels only approximate a comfortable range. This is a trial tonic to listen to and confirm, not a uniquely fixed personal Sa."
        return SaRecommendation(saHz: choice.frequency, lowerHz: lower, upperHz: upper,
                                measuredHz: values, selectionMethod: "voice_range_center_and_middle_v1",
                                rangeCenterHz: rangeCenter, preferredSaHz: preferred, explanation: explanation)
    }
}

/// Confirmation is tied to the exact proposal; audition is optional. New measurements or any
/// adjustment invalidate confirmation; practice cannot silently reuse it.
struct CalibrationSession {
    private(set) var recommendation: SaRecommendation?
    private(set) var confirmedSa: Double?
    private(set) var auditionedSa: Double?

    mutating func invalidate() {
        recommendation = nil
        confirmedSa = nil
        auditionedSa = nil
    }

    mutating func propose(_ value: SaRecommendation) {
        recommendation = value
        confirmedSa = nil
        auditionedSa = nil
    }

    mutating func referenceFinished(hz: Double, successful: Bool) {
        guard successful, let recommendation = recommendation,
              abs(hz - recommendation.saHz) < 1e-9 else { auditionedSa = nil; return }
        auditionedSa = hz
    }

    var canConfirm: Bool {
        guard let proposal = recommendation else { return false }
        return proposal.supports(proposal.saHz)
    }

    mutating func confirm() throws {
        guard canConfirm, let proposal = recommendation else {
            throw CalibrationFailure.inconclusive("Record a valid comfortable range before confirming Sa.")
        }
        confirmedSa = proposal.saHz
    }

    mutating func adjust(to frequency: Double) throws {
        guard var proposal = recommendation, proposal.supports(frequency) else {
            throw CalibrationFailure.inconclusive("That Sa is outside the measured comfortable boundaries.")
        }
        proposal.saHz = frequency
        proposal.explanation += " Manually adjusted within the same measured boundaries; confirm again. Listening is optional."
        propose(proposal)
    }
}
