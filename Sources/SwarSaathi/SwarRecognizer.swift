import Foundation

/// Canonical variant identities, not equal-tempered frequency calculations.
enum SwarVariant: Int, Codable, CaseIterable, Comparable {
    case sa = 0, komalRe, shuddhaRe, komalGa, shuddhaGa, shuddhaMa, tivraMa, pa, komalDha, shuddhaDha, komalNi, shuddhaNi
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
struct SwarKey: Codable, Hashable, Comparable {
    let variant: SwarVariant
    let octave: Int
    static func < (a: Self, b: Self) -> Bool {
        a.octave == b.octave ? a.variant < b.variant : a.octave < b.octave
    }
    static func legacyLabel(_ label: String) -> Self? {
        let mapping: [String: SwarVariant] = ["Sa": .sa, "Re": .shuddhaRe, "Ga": .shuddhaGa,
            "Ma": .shuddhaMa, "Pa": .pa, "Dha": .shuddhaDha, "Ni": .shuddhaNi, "Sa'": .sa]
        guard let variant = mapping[label] else { return nil }
        return Self(variant: variant, octave: label == "Sa'" ? 1 : 0)
    }
}
struct TuningProfile {
    let id: String
    let ratios: [SwarVariant: Double]
    static let baseline: Self = {
        var ratios: [SwarVariant: Double] = [:]
        for swar in TuningSystem.justShuddha.swars where swar.ratio < 2 {
            if let key = SwarKey.legacyLabel(swar.label) { ratios[key.variant] = swar.ratio }
        }
        return Self(id: "illustrative-just-shuddha-v1", ratios: ratios)
    }()
    var isValid: Bool {
        let ordered = ratios.sorted { $0.key < $1.key }.map(\.value)
        return !id.isEmpty && ratios[.sa] == 1 &&
            ordered.allSatisfy { $0.isFinite && $0 >= 1 && $0 < 2 } &&
            zip(ordered, ordered.dropFirst()).allSatisfy { $0.0 < $0.1 }
    }
    func frequency(_ key: SwarKey, sa: Double) -> Double? {
        guard isValid, sa.isFinite, sa > 0, let ratio = ratios[key.variant] else { return nil }
        let hz = sa * ratio * pow(2, Double(key.octave))
        return hz.isFinite && hz > 0 ? hz : nil
    }
}
enum RecognitionStatus: String, Codable { case recognized, unvoiced, unreliable, outsideRange, noMatch, ambiguous, invalidConfiguration }
struct SwarRecognition: Codable {
    let status: RecognitionStatus
    let key: SwarKey?
    let signedCents: Double?
}
/// Independent mapping: no exercise target or exercise-specific candidate list.
/// Experimental acceptance bands are not a validated musical assessment.
struct SwarRecognizer {
    static let policyVersion = "independent-swar-v1-provisional"
    let tuning: TuningProfile
    let confirmedSa: Double
    let toleranceCents: Double
    init(confirmedSa: Double, tuning: TuningProfile = .baseline, toleranceCents: Double = 50) {
        self.confirmedSa = confirmedSa; self.tuning = tuning; self.toleranceCents = toleranceCents
    }
    func recognize(rawFrequency: Double?, confidence: Double) -> SwarRecognition {
        func reject(_ status: RecognitionStatus) -> SwarRecognition {
            SwarRecognition(status: status, key: nil, signedCents: nil)
        }
        guard tuning.isValid, (70...1000).contains(confirmedSa),
              toleranceCents.isFinite, toleranceCents > 0, toleranceCents <= 100 else { return reject(.invalidConfiguration) }
        guard let hz = rawFrequency else { return reject(.unvoiced) }
        guard hz.isFinite, confidence.isFinite, (0.85...1).contains(confidence) else { return reject(.unreliable) }
        guard (70...1000).contains(hz) else { return reject(.outsideRange) }
        var matches: [(SwarKey, Double)] = []
        // Both tonic and F0 are 70...1000 Hz: +/- 5 octaves covers every candidate.
        for octave in -5...5 {
            for variant in tuning.ratios.keys {
                let key = SwarKey(variant: variant, octave: octave)
                guard let target = tuning.frequency(key, sa: confirmedSa), (70...1000).contains(target) else { continue }
                let cents = PitchMath.cents(detected: hz, expected: target)
                if abs(cents) <= toleranceCents + 1e-9 { matches.append((key, cents)) }
            }
        }
        guard let match = matches.first else { return reject(.noMatch) }
        guard matches.count == 1 else { return reject(.ambiguous) }
        return SwarRecognition(status: .recognized, key: match.0, signedCents: match.1)
    }
}
