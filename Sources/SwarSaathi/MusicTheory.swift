import Foundation

// MARK: - Tuning system (configurable ratios)

struct Swar: Hashable {
    let label: String
    let ratio: Double
}

struct TuningSystem {
    let name: String
    let swars: [Swar]   // Sa ... Ni, Sa' (upper)

    func ratio(for label: String) -> Double? {
        swars.first { $0.label == label }?.ratio
    }

    /// Expected Frequency = Sa Frequency x Swar Ratio
    func frequency(sa: Double, label: String) -> Double? {
        ratio(for: label).map { sa * $0 }
    }

    /// Illustrative Shuddha swaras (just-intonation style ratios from the brief).
    /// Swap or edit these to experiment with other tuning systems / komal-tivra variants.
    static let justShuddha = TuningSystem(name: "Illustrative Shuddha Swaras", swars: [
        Swar(label: "Sa", ratio: 1.0),
        Swar(label: "Re", ratio: 1.125),
        Swar(label: "Ga", ratio: 1.25),
        Swar(label: "Ma", ratio: 4.0 / 3.0),
        Swar(label: "Pa", ratio: 1.5),
        Swar(label: "Dha", ratio: 5.0 / 3.0),
        Swar(label: "Ni", ratio: 1.875),
        Swar(label: "Sa'", ratio: 2.0)
    ])
}

// MARK: - Alankaar

struct NoteTarget: Identifiable, Codable {
    let index: Int
    let label: String
    let ratio: Double
    let frequency: Double
    var id: Int { index }
}

struct Alankaar {
    let name: String
    let labels: [String]

    func targets(sa: Double, tuning: TuningSystem) -> [NoteTarget] {
        labels.enumerated().compactMap { (i, label) in
            guard let r = tuning.ratio(for: label) else { return nil }
            return NoteTarget(index: i, label: label, ratio: r, frequency: sa * r)
        }
    }

    /// Sa Re Ga Ma | Pa Dha Ni Sa'   /   Sa' Ni Dha Pa | Ma Ga Re Sa
    static let standard = Alankaar(name: "Basic Ascent & Descent", labels: [
        "Sa", "Re", "Ga", "Ma", "Pa", "Dha", "Ni", "Sa'",
        "Sa'", "Ni", "Dha", "Pa", "Ma", "Ga", "Re", "Sa"
    ])

    static let fiveNote = Alankaar(name: "Sa Re Ga Re Sa", labels: ["Sa", "Re", "Ga", "Re", "Sa"])
    static let demoExercises = [fiveNote, standard]
}

// MARK: - Accuracy thresholds (experimental, configurable)

enum Accuracy {
    case veryAccurate, onTarget, needsAdjustment
}

struct AccuracyThresholds: Codable {
    var veryAccurateCents: Double = 25
    var onTargetCents: Double = 50

    func classify(_ cents: Double) -> Accuracy {
        let a = abs(cents)
        if a <= veryAccurateCents { return .veryAccurate }
        if a <= onTargetCents { return .onTarget }
        return .needsAdjustment
    }
}

// MARK: - Math helpers

enum PitchMath {
    /// Cents Difference = 1200 x log2(Detected / Expected)
    static func cents(detected: Double, expected: Double) -> Double {
        1200 * log2(detected / expected)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Nearest equal-tempered note (A4 = 440 Hz) as a reference only.
    static func nearestNote(_ hz: Double) -> (name: String, centsOff: Double) {
        let midiExact = 69 + 12 * log2(hz / 440)
        let midi = Int(midiExact.rounded())
        let name = names[((midi % 12) + 12) % 12] + String(midi / 12 - 1)
        return (name, (midiExact - Double(midi)) * 100)
    }

    static func noteText(_ hz: Double) -> String {
        let n = nearestNote(hz)
        return "\(n.name) \(String(format: "%+.0f", n.centsOff))¢"
    }
}
