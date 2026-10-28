import XCTest
@testable import SwarSaathiCore

/// Hand-counted synthetic observations audit the reported percentages. These
/// fixtures are independent of microphone capture and make no device claim.
final class ScoreAuditTests: XCTestCase {
    private let timeline = PracticeTimeline(
        targets: Alankaar.fiveNote.targets(sa: 220, tuning: .justShuddha), bpm: 60)
    private let frequencies = [220.0, 247.5, 275.0, 247.5, 220.0]

    private func mixedObservations() -> [PracticeObservation] {
        // Five one-second notes, 25 explicit 40 ms cells each.
        // Sa: 25 correct.
        // Re: 2 late Sa, 15 correct, 3 wrong octaves, 5 absent.
        // Ga: 25 wrong octaves.
        // Re: 2 late Ga, 10 correct, 13 absent.
        // Sa: 20 correct, 5 low-confidence observations (count as missing).
        var rows: [PracticeObservation] = []
        for note in 0..<5 {
            for cell in 0..<25 {
                let time = Double(note) + 0.02 + 0.04 * Double(cell)
                let frequency: Double?
                var confidence = 0.99
                switch note {
                case 0: frequency = frequencies[0]
                case 1:
                    if cell < 2 { frequency = frequencies[0] }
                    else if cell < 17 { frequency = frequencies[1] }
                    else if cell < 20 { frequency = frequencies[1] * 2 }
                    else { continue }
                case 2: frequency = frequencies[2] * 2
                case 3:
                    if cell < 2 { frequency = frequencies[2] }
                    else if cell < 12 { frequency = frequencies[3] }
                    else { continue }
                default:
                    frequency = frequencies[4]
                    if cell >= 20 { confidence = 0.84 }
                }
                rows.append(PracticeObservation(time: time, frequency: frequency, confidence: confidence))
            }
        }
        return rows
    }

    func testHandCountedPercentagesIncludeEveryExpectedCell() {
        let report = timeline.score(observations: mixedObservations())
        XCTAssertEqual(report.results.map(\.expectedFrames), [25, 25, 25, 25, 25])
        XCTAssertEqual(report.results.map(\.correctFrames), [25, 15, 0, 10, 20])
        XCTAssertEqual(report.results.map(\.transitionAcceptedFrames), [0, 2, 0, 2, 0])
        XCTAssertEqual(report.results.map(\.voicedFrames), [25, 20, 25, 12, 20])
        XCTAssertEqual(report.results.map(\.accuracyPercent), [100, 60, 0, 40, 80])
        XCTAssertEqual(report.results.map(\.practiceMatchPercent), [100, 68, 0, 48, 80])
        // 70 strictly correct + 4 explicitly allowed transition cells / 125.
        XCTAssertEqual(report.summary.accuracyPercent, 56, accuracy: 1e-9)
        XCTAssertEqual(report.summary.practiceMatchPercent, 59.2, accuracy: 1e-9)
        XCTAssertEqual(report.summary.reliableCoveragePercent, 81.6, accuracy: 1e-9)
        XCTAssertEqual(report.results.reduce(0) { $0 + $1.missingDuration }, 0.92, accuracy: 1e-9)
        // One-decimal labels round only the display, not the stored score.
        XCTAssertEqual(String(format: "%.1f%%", report.summary.practiceMatchPercent), "59.2%")
        print("SCORE AUDIT: 125 expected cells; 70 strict + 4 transition; 102 reliable; strict 56%, practice 59.2%, voice coverage 81.6%")
    }

    func testNearestObservationIsUsedEvenWhenSilentOrWrong() {
        // Each pair is in one cell. The closer observation must win regardless
        // of frequency, confidence or input array order.
        let rows = [
            PracticeObservation(time: 0.001, frequency: 220, confidence: 0.99),
            PracticeObservation(time: 0.02, frequency: nil, confidence: 0),
            PracticeObservation(time: 0.041, frequency: 220, confidence: 0.99),
            PracticeObservation(time: 0.06, frequency: 440, confidence: 0.99),
            PracticeObservation(time: 0.081, frequency: 220, confidence: 0.99),
            PracticeObservation(time: 0.10, frequency: 220, confidence: 0.84)
        ]
        for input in [rows, Array(rows.reversed())] {
            let result = timeline.score(observations: input)
            XCTAssertEqual(result.summary.accuracyPercent, 0)
            XCTAssertEqual(result.summary.practiceMatchPercent, 0)
            XCTAssertEqual(result.results[0].voicedFrames, 1)
            XCTAssertEqual(result.results.reduce(0) { $0 + $1.expectedFrames }, 125)
        }
    }

    func testCountInTailAndDuplicatesCannotImproveTheHandCountedScore() {
        let rows = mixedObservations()
        let extras = [
            PracticeObservation(time: -0.02, frequency: 220, confidence: 0.99),
            PracticeObservation(time: 5, frequency: 220, confidence: 0.99),
            PracticeObservation(time: 5.02, frequency: 220, confidence: 0.99)
        ]
        let result = timeline.score(observations: rows + rows + extras)
        XCTAssertEqual(result.summary.accuracyPercent, 56, accuracy: 1e-9)
        XCTAssertEqual(result.summary.practiceMatchPercent, 59.2, accuracy: 1e-9)
        XCTAssertEqual(result.summary.reliableCoveragePercent, 81.6, accuracy: 1e-9)
    }

    func testExportedRawEvidenceReplaysToExactlyTheDisplayedScores() throws {
        struct Snapshot: Codable {
            let timeline: PracticeTimeline
            let observations: [PracticeObservation]
            let thresholds: AccuracyThresholds
            let summary: PracticeSummary
            let results: [NoteResult]
        }
        let rows = mixedObservations()
        let scored = timeline.score(observations: rows)
        let snapshot = Snapshot(timeline: timeline, observations: rows, thresholds: AccuracyThresholds(),
                                summary: scored.summary, results: scored.results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(Snapshot.self, from: encoder.encode(snapshot))
        let replay = restored.timeline.score(observations: restored.observations, thresholds: restored.thresholds)
        XCTAssertEqual(try encoder.encode(replay.summary), try encoder.encode(restored.summary))
        XCTAssertEqual(try encoder.encode(replay.results), try encoder.encode(restored.results))
        XCTAssertEqual(restored.observations.count, rows.count)
    }

    func testTemposDoNotAlterTheFullExerciseMeaningOfOneMissingNote() {
        // Independently known sustained tones with the entire middle note
        // missing must be 80%, regardless of how each beat is subdivided.
        for bpm in [40.0, 60, 72, 76, 90, 120] {
            let track = PracticeTimeline(targets: Alankaar.fiveNote.targets(sa: 220, tuning: .justShuddha), bpm: bpm)
            let beat = 60 / bpm
            let rows = stride(from: 0.005, to: 5 * beat, by: 0.01).compactMap { time -> PracticeObservation? in
                let note = min(4, Int(time / beat))
                if note == 2 { return nil }
                return PracticeObservation(time: time, frequency: frequencies[note], confidence: 0.99)
            }
            let report = track.score(observations: rows)
            XCTAssertEqual(report.summary.accuracyPercent, 80, accuracy: 1e-9, "\(bpm) BPM")
            XCTAssertEqual(report.summary.practiceMatchPercent, 80, accuracy: 1e-9, "\(bpm) BPM")
            XCTAssertEqual(report.summary.reliableCoveragePercent, 80, accuracy: 1e-9, "\(bpm) BPM")
            XCTAssertEqual(report.results[2].practiceMatchPercent, 0)
        }
    }
}
