import Foundation

struct GraphPoint {
    let t: Double
    let hz: Double?
    let targetHz: Double
}

struct LadderLine {
    let name: String
    let hz: Double
}

struct NoteResult: Identifiable, Codable {
    let index: Int
    let swar: String
    let expectedHz: Double
    let detectedHz: Double?
    let signedCents: Double?
    // Retained for source compatibility; completion no longer depends on singing.
    let autoCompleted: Bool
    let eligibleDuration: Double
    let voicedDuration: Double
    let correctDuration: Double
    let missingDuration: Double
    let medianAbsoluteCents: Double?
    let accuracyPercent: Double
    let expectedFrames: Int
    let voicedFrames: Int
    let correctFrames: Int
    var id: Int { index }
}

struct PracticeSummary: Codable {
    let total: Int
    let attempted: Int
    let onTarget: Int
    let needsImprovement: Int
    let avgAbsCents: Double?
    let accuracyPercent: Double
    let reliableCoveragePercent: Double
    let limitations: [String]
}

enum FeedbackKind { case neutral, perfect, onTarget, high, low }

/// A raw detector observation. Time is seconds relative to the practice start,
/// excluding count-in. Never populate this from reference or expected pitches.
struct PracticeObservation: Codable {
    let time: Double
    let frequency: Double?
    let confidence: Double

    var isReliable: Bool {
        guard let f = frequency else { return false }
        return f.isFinite && f > 0 && confidence.isFinite && confidence >= 0.85 && confidence <= 1
    }
}

struct TimedPracticeNote: Codable {
    let target: NoteTarget
    let start: Double
    let end: Double

    var eligible: ClosedRange<Double> {
        // The full scheduled note remains in the accuracy denominator,
        // including silent/incorrect transitions at either edge.
        start...end
    }
}

/// One beat per note at a fixed guided tempo. Apple callers use a monotonic
/// clock (CACurrentMediaTime); this pure model accepts elapsed seconds directly.
struct PracticeTimeline: Codable {
    let notes: [TimedPracticeNote]
    let bpm: Double
    var duration: Double { notes.last?.end ?? 0 }

    init(targets: [NoteTarget], bpm: Double = 72) {
        precondition(!targets.isEmpty && targets.allSatisfy { $0.frequency.isFinite && $0.frequency > 0 })
        precondition(bpm.isFinite && (40...120).contains(bpm))
        self.bpm = bpm
        let beat = 60 / bpm
        self.notes = targets.enumerated().map { index, target in
            TimedPracticeNote(target: target, start: Double(index) * beat, end: Double(index + 1) * beat)
        }
    }

    func note(at elapsed: Double) -> TimedPracticeNote? {
        guard elapsed.isFinite && elapsed >= 0 && elapsed < duration else { return nil }
        let index = min(Int(elapsed * bpm / 60), notes.count - 1)
        return notes[index]
    }

    /// Full-exercise denominator. Every scheduled note is split into equal cells
    /// no longer than 40 ms (native analysis hop is ~21–23 ms). Each observation
    /// belongs to its timestamp's ONE cell; absent/unvoiced cells score zero.
    /// Where multiple frames occupy a cell, choose the closest to its midpoint,
    /// without preferring successful/voiced detections. Equal note weighting
    /// keeps long notes from dominating. No note edges are silently omitted.
    func score(observations: [PracticeObservation], thresholds: AccuracyThresholds = AccuracyThresholds())
        -> (summary: PracticeSummary, results: [NoteResult]) {
        var unique: [Double: PracticeObservation] = [:]
        for o in observations where o.time.isFinite {
            if unique[o.time] == nil { unique[o.time] = o }
        }
        let ordered = unique.values.sorted { $0.time < $1.time }
        var mismatch = false
        let results: [NoteResult] = notes.map { note in
            let start = note.eligible.lowerBound, end = note.eligible.upperBound
            let duration = end - start
            let count = max(1, Int(ceil(duration / 0.04 - 1e-10)))
            let width = duration / Double(count)
            var selected: [Int: PracticeObservation] = [:]
            for o in ordered where o.time >= start && o.time < end {
                let cell = min(count - 1, Int((o.time - start) / width))
                let center = start + (Double(cell) + 0.5) * width
                if let previous = selected[cell], abs(previous.time - center) <= abs(o.time - center) { continue }
                selected[cell] = o
            }
            let voiced = selected.values.filter { $0.isReliable }
            let errors = voiced.map { PitchMath.cents(detected: $0.frequency!, expected: note.target.frequency) }
            let correct = errors.filter { abs($0) <= thresholds.onTargetCents + 1e-9 }.count
            if !errors.isEmpty && Double(errors.filter { abs($0) > thresholds.onTargetCents }.count) / Double(errors.count) >= 0.1 { mismatch = true }
            let detected = PitchMath.median(voiced.compactMap { $0.frequency })
            let voicedDuration = duration * (Double(voiced.count) / Double(count))
            let correctDuration = duration * (Double(correct) / Double(count))
            return NoteResult(index: note.target.index, swar: note.target.label,
                              expectedHz: note.target.frequency, detectedHz: detected,
                              signedCents: detected.map { PitchMath.cents(detected: $0, expected: note.target.frequency) },
                              autoCompleted: false, eligibleDuration: duration,
                              voicedDuration: voicedDuration,
                              correctDuration: correctDuration,
                              missingDuration: duration - voicedDuration,
                              medianAbsoluteCents: PitchMath.median(errors.map { abs($0) }),
                              accuracyPercent: 100 * Double(correct) / Double(count),
                              expectedFrames: count, voicedFrames: voiced.count, correctFrames: correct)
        }
        let totalEligible = results.reduce(0) { $0 + $1.eligibleDuration }
        let totalVoiced = results.reduce(0) { $0 + $1.voicedDuration }
        let attempted = results.filter { $0.voicedDuration >= 0.5 * $0.eligibleDuration }.count
        let onTarget = results.filter { $0.accuracyPercent >= 80 }.count
        let absolute = results.compactMap { $0.medianAbsoluteCents }
        var limitations = [
            "Fixed guided tempo; timing drift and pitch error cannot be uniquely distinguished.",
            "Illustrative Shuddha ratios; experimental 25/50-cent thresholds are not a validated Hindustani assessment.",
            "The percentage is singing pitch-match coverage for the full expected exercise, not detector confidence."
        ]
        if totalVoiced < 0.8 * totalEligible { limitations.append("Incomplete reliable voice coverage: silence, rejected pitch or dropped acquisition decreases the score.") }
        if mismatch { limitations.append("Pitch or timing mismatch detected; alignment confidence is limited.") }
        return (PracticeSummary(total: notes.count, attempted: attempted, onTarget: onTarget,
                                needsImprovement: notes.count - onTarget,
                                avgAbsCents: absolute.isEmpty ? nil : absolute.reduce(0, +) / Double(absolute.count),
                                accuracyPercent: results.reduce(0) { $0 + $1.accuracyPercent } / Double(notes.count),
                                reliableCoveragePercent: totalEligible > 0 ? 100 * totalVoiced / totalEligible : 0,
                                limitations: limitations), results)
    }
}

/// Pure synthesis from the same timeline consumed by graph and scorer.
enum ReferenceSynthesis {
    static func samples(timeline: PracticeTimeline, sampleRate: Double = 44100) -> [Float] {
        precondition(sampleRate.isFinite && sampleRate >= 8000)
        var output = [Float](repeating: 0, count: Int((timeline.duration * sampleRate).rounded()))
        for note in timeline.notes {
            precondition(note.target.frequency < sampleRate / 2)
            let first = Int((note.start * sampleRate).rounded())
            let last = min(output.count, Int((note.end * sampleRate).rounded()))
            let fade = min(Int(0.01 * sampleRate), (last - first) / 2)
            for i in first..<last {
                let envelope = fade > 1 ? max(0, min(1, Double(i - first) / Double(fade - 1), Double(last - 1 - i) / Double(fade - 1))) : 1
                output[i] = Float(0.2 * envelope * sin(2 * .pi * note.target.frequency * Double(i - first) / sampleRate))
            }
        }
        return output
    }

    static func wav(timeline: PracticeTimeline, sampleRate: Int = 44100) -> Data {
        let samples = samples(timeline: timeline, sampleRate: Double(sampleRate))
        var output = Data()
        func ascii(_ text: String) { output.append(text.data(using: .ascii)!) }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { output.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { output.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + samples.count * 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: Int16((max(-1, min(1, sample)) * 32767).rounded()))) }
        return output
    }
}
