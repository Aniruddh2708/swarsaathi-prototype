import XCTest
@testable import SwarSaathiCore

/// Explicit synthetic/independently simulated observations. No hardware claim.
final class PracticeTimelineTests: XCTestCase {
    private let sa = 220.0
    private let fixtureRatios = [1.0, 1.125, 1.25, 1.125, 1.0]

    private func timeline(bpm: Double = 72, sa: Double = 220) -> PracticeTimeline {
        PracticeTimeline(targets: Alankaar.fiveNote.targets(sa: sa, tuning: .justShuddha), bpm: bpm)
    }

    private func track(bpm: Double = 72, sa: Double = 220, hop: Double = 0.02,
                       centsOffset: Double = 0, missing: Set<Int> = [], silent: Bool = false) -> [PracticeObservation] {
        let beat = 60 / bpm
        return stride(from: hop / 2, to: 5 * beat, by: hop).map { time in
            let index = min(4, Int(time / beat))
            let voiced = !silent && !missing.contains(index)
            let frequency = sa * fixtureRatios[index] * pow(2, centsOffset / 1200)
            return PracticeObservation(time: time, frequency: voiced ? frequency : nil, confidence: voiced ? 0.99 : 0)
        }
    }

    func testFiveNoteDefinitionAndFixedTimelineAreIndependentOfObservations() {
        let timeline = timeline(bpm: 60)
        XCTAssertEqual(timeline.notes.map { $0.target.label }, ["Sa", "Re", "Ga", "Re", "Sa"])
        XCTAssertEqual(timeline.duration, 5)
        XCTAssertNil(timeline.note(at: -0.01))
        XCTAssertEqual(timeline.note(at: 0)?.target.index, 0)
        XCTAssertEqual(timeline.note(at: 1)?.target.index, 1)
        XCTAssertEqual(timeline.note(at: 3.5)?.target.index, 3)
        XCTAssertNil(timeline.note(at: 5))
        XCTAssertNil(timeline.note(at: .nan))
        // Wrong or missing voice does not enter the target-selection API.
        XCTAssertEqual(timeline.note(at: 4)?.target.label, "Sa")
    }

    func testPerfectIndependentTrackScoresFullExercise() {
        let report = timeline().score(observations: track())
        XCTAssertEqual(report.summary.accuracyPercent, 100, accuracy: 1e-9)
        XCTAssertEqual(report.summary.attempted, 5)
        XCTAssertEqual(report.summary.onTarget, 5)
        XCTAssertEqual(report.results.count, 5)
        XCTAssertTrue(report.results.allSatisfy { $0.correctFrames == $0.expectedFrames })
    }

    func testWrongSharpFlatAndOctaveObservationsLoseScoreWithoutThresholdChanges() {
        for error in [-1200.0, -200, -60, 60, 200, 1200] {
            let report = timeline().score(observations: track(centsOffset: error))
            XCTAssertEqual(report.summary.accuracyPercent, 0, accuracy: 1e-9, "offset \(error)")
            XCTAssertGreaterThan(report.summary.reliableCoveragePercent, 99)
            XCTAssertTrue(report.results.allSatisfy { $0.medianAbsoluteCents! > 50 })
        }
        XCTAssertEqual(timeline().score(observations: track(centsOffset: 50)).summary.accuracyPercent, 100, accuracy: 1e-9)
    }

    func testSilentMissingAndEarlyStopRemainInDenominator() {
        let timeline = timeline()
        let silent = timeline.score(observations: track(silent: true))
        XCTAssertEqual(silent.summary.accuracyPercent, 0)
        XCTAssertEqual(silent.summary.attempted, 0)
        XCTAssertEqual(silent.summary.needsImprovement, 5)
        XCTAssertTrue(silent.results.allSatisfy { $0.missingDuration == $0.eligibleDuration })
        XCTAssertEqual(timeline.score(observations: track(missing: [2])).summary.accuracyPercent, 80, accuracy: 1e-9)
        let firstOnly = track().filter { $0.time < 60 / 72 }
        XCTAssertEqual(timeline.score(observations: firstOnly).summary.accuracyPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(timeline.score(observations: []).summary.accuracyPercent, 0)
    }

    func testNoObservedVoiceDoesNotInventAZeroCentError() throws {
        let report = timeline().score(observations: [])
        XCTAssertNil(report.summary.avgAbsCents)
        let silent = timeline().score(observations: track(silent: true))
        XCTAssertNil(silent.summary.avgAbsCents)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.summary)) as! [String: Any]
        XCTAssertNil(json["avgAbsCents"], "No observed pitch error must be omitted, not reported as a perfect zero")
    }

    func testOriginalSuccessFilteredSummaryInflationRegression() {
        // Exact original reducer: completed/detected notes only in denominator.
        let completedDetectedErrors = [0.0]
        let originalPercentage = Double(completedDetectedErrors.filter { abs($0) <= 50 }.count) / Double(completedDetectedErrors.count) * 100
        XCTAssertEqual(originalPercentage, 100)
        let corrected = timeline().score(observations: track().filter { $0.time < 60 / 72 })
        XCTAssertEqual(corrected.summary.accuracyPercent, 20, accuracy: 1e-9)
        print("REGRESSION original filtered formula=100%; full five-note denominator=20% for one correct note + four missing")
    }

    func testDuplicateSparseInvalidAndLowQualityFramesDoNotFillSilence() {
        let single = PracticeObservation(time: 0.2, frequency: sa, confidence: 0.99)
        let timeline = timeline()
        let original = timeline.score(observations: [single]).summary.accuracyPercent
        XCTAssertEqual(timeline.score(observations: Array(repeating: single, count: 1000)).summary.accuracyPercent, original)
        XCTAssertLessThan(original, 2)
        let invalid = [
            PracticeObservation(time: 0.2, frequency: .nan, confidence: 0.99),
            PracticeObservation(time: 0.3, frequency: sa, confidence: 0.84),
            PracticeObservation(time: 0.4, frequency: sa, confidence: .infinity),
            PracticeObservation(time: .nan, frequency: sa, confidence: 1)]
        XCTAssertEqual(timeline.score(observations: invalid).summary.accuracyPercent, 0)
    }

    func testConflictingDuplicatesNeverPreferSuccessfulObservation() {
        let wrong = PracticeObservation(time: 0.2, frequency: sa * 2, confidence: 0.99)
        let right = PracticeObservation(time: 0.2, frequency: sa, confidence: 0.99)
        XCTAssertEqual(timeline().score(observations: [wrong, right]).summary.accuracyPercent, 0)
    }

    func testSilentNoteEdgesRemainInFullExerciseDenominator() {
        let timeline = timeline(bpm: 120)
        let edgesSilent = track(bpm: 120).map { row in
            let withinNote = row.time.truncatingRemainder(dividingBy: 0.5)
            let voiced = withinNote >= 0.1 && withinNote < 0.4
            return PracticeObservation(time: row.time, frequency: voiced ? row.frequency : nil,
                                       confidence: voiced ? row.confidence : 0)
        }
        let report = timeline.score(observations: edgesSilent)
        XCTAssertEqual(report.results.reduce(0) { $0 + $1.eligibleDuration }, timeline.duration, accuracy: 1e-9)
        XCTAssertLessThan(report.summary.accuracyPercent, 75)
        XCTAssertGreaterThan(report.summary.accuracyPercent, 45)
    }

    func testSparseNonuniformEvidenceCannotFillMissingDurations() {
        let timeline = timeline(bpm: 60)
        let sparse = [0.2, 0.201, 0.202, 0.203, 1.1, 1.101, 2.4].map { time in
            let noteIndex = Int(time)
            return PracticeObservation(time: time, frequency: sa * fixtureRatios[noteIndex], confidence: 0.99)
        }
        let result = timeline.score(observations: sparse)
        XCTAssertLessThan(result.summary.accuracyPercent, 4)
        XCTAssertGreaterThan(result.results.reduce(0) { $0 + $1.missingDuration }, 4.8)
    }

    func testNativeHopCoverageAcrossSampleRatesAndTempos() {
        for rate in [44100.0, 48000] {
            for bpm in [40.0, 72, 120] {
                let report = timeline(bpm: bpm).score(observations: track(bpm: bpm, hop: 1024 / rate))
                XCTAssertGreaterThan(report.summary.accuracyPercent, 99, "\(rate) Hz, \(bpm) BPM")
                let silent = timeline(bpm: bpm).score(observations: track(bpm: bpm, hop: 1024 / rate, silent: true))
                XCTAssertEqual(silent.summary.accuracyPercent, 0)
            }
        }
    }

    func testTimingDriftLosesScoreWithoutDroppingNoteEdges() {
        let track = self.track()
        let slight = track.map { PracticeObservation(time: $0.time + 0.08, frequency: $0.frequency, confidence: $0.confidence) }
        let late = track.map { PracticeObservation(time: $0.time + 0.3, frequency: $0.frequency, confidence: $0.confidence) }
        let slightScore = timeline().score(observations: slight).summary.accuracyPercent
        XCTAssertLessThan(slightScore, 100)
        XCTAssertGreaterThan(slightScore, 80)
        let result = timeline().score(observations: late)
        XCTAssertLessThan(result.summary.accuracyPercent, slightScore)
        XCTAssertTrue(result.summary.limitations.contains { $0.contains("alignment") })
        for note in timeline(bpm: 120).notes {
            XCTAssertEqual(note.eligible.lowerBound, note.start)
            XCTAssertEqual(note.eligible.upperBound, note.end)
        }
    }

    func testShiftedSaChangesBothTargetsAndReferenceWithoutModifyingObservations() {
        let lower = timeline(sa: 196), upper = timeline(sa: 392)
        for (a, b) in zip(lower.notes, upper.notes) { XCTAssertEqual(b.target.frequency / a.target.frequency, 2) }
        let originalObservations = track(sa: 196)
        XCTAssertEqual(lower.score(observations: originalObservations).summary.accuracyPercent, 100, accuracy: 1e-9)
        XCTAssertEqual(upper.score(observations: originalObservations).summary.accuracyPercent, 0)
    }

    func testReferenceSynthUsesTimelineFrequenciesDurationsAndCleanFades() {
        let timeline = timeline(bpm: 60), rate = 44100.0
        let samples = ReferenceSynthesis.samples(timeline: timeline, sampleRate: rate)
        XCTAssertEqual(samples.count, 5 * 44100)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples.last!, 0)
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max()!, 0.200001)
        // Independent waveform expectation well inside the second note.
        let j = 44100 + 1000
        let expected = 0.2 * sin(2 * .pi * (220 * 1.125) * 1000 / rate)
        XCTAssertEqual(Double(samples[j]), expected, accuracy: 1e-7)
        let wav = ReferenceSynthesis.wav(timeline: timeline)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
    }

    func testJSONReportEncodesRawObservationAndEveryExpectedNote() throws {
        let report = timeline().score(observations: track(missing: [1]))
        let encoded = try JSONEncoder().encode(report.results)
        let decoded = try JSONDecoder().decode([NoteResult].self, from: encoded)
        XCTAssertEqual(decoded.count, 5)
        XCTAssertEqual(decoded[1].accuracyPercent, 0)
        XCTAssertEqual(decoded[1].correctFrames, 0)
        XCTAssertGreaterThan(decoded[1].expectedFrames, 0)
    }
}
