import XCTest
@testable import SwarSaathiCore

final class TransitionAllowanceTests: XCTestCase {
    private let timeline = PracticeTimeline(targets: Alankaar.fiveNote.targets(sa: 220, tuning: .justShuddha), bpm: 60)
    private func row(_ t: Double, _ hz: Double?) -> PracticeObservation {
        PracticeObservation(time: t, frequency: hz, confidence: hz == nil ? 0 : 0.99)
    }
    func testFastTempoDoesNotDoubleTheTransitionShare() {
        let fast = PracticeTimeline(targets: timeline.notes.map(\.target), bpm: 120)
        XCTAssertEqual(fast.transitionWindowSeconds, 0.05, accuracy: 1e-9)
        XCTAssertFalse(fast.matchesForPractice(row(0.58, 220)))
        XCTAssertTrue(fast.matchesForPractice(row(0.54, 220)))
    }

    func testReportsWithoutAPolicyReplayWithOriginalWindow() throws {
        let fast = PracticeTimeline(targets: timeline.notes.map(\.target), bpm: 120)
        let data = try JSONEncoder().encode(fast)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "transitionPolicy")
        let legacy = try JSONDecoder().decode(PracticeTimeline.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.transitionWindowSeconds, 0.1)
        XCTAssertTrue(legacy.matchesForPractice(row(0.58, 220)))
        XCTAssertFalse(fast.matchesForPractice(row(0.58, 220)))
    }

    func testExactScheduledStartAlwaysSelectsNewTarget() {
        for tempo in 40...120 {
            let track = PracticeTimeline(targets: Alankaar.standard.targets(sa: 220, tuning: .justShuddha), bpm: Double(tempo))
            for note in track.notes {
                XCTAssertEqual(track.note(at: note.start)?.target.index, note.target.index, "BPM \(tempo), index \(note.target.index)")
            }
        }
    }

    func testSmallEarlyLateChangesAndGlidesHaveExplicitAllowance() {
        XCTAssertTrue(timeline.matchesForPractice(row(0.94, 247.5)))
        XCTAssertTrue(timeline.matchesForPractice(row(1.06, 220)))
        XCTAssertTrue(timeline.matchesForPractice(row(1.01, sqrt(220 * 247.5))))
        XCTAssertFalse(timeline.matchesForPractice(row(1.15, 220)))
        XCTAssertFalse(timeline.matchesForPractice(row(0.85, 247.5)))
    }
    func testSilenceWrongOctaveAndSustainedWrongPitchNeverBecomeCorrect() {
        XCTAssertFalse(timeline.matchesForPractice(row(1.03, nil)))
        XCTAssertFalse(timeline.matchesForPractice(row(1.03, 440)))
        XCTAssertFalse(timeline.matchesForPractice(row(1.5, 247.5 * pow(2, 60.0 / 1200))))
        XCTAssertTrue(timeline.matchesForPractice(row(1.5, 247.5 * pow(2, 45.0 / 1200))))
        XCTAssertFalse(timeline.matchesForPractice(row(-0.03, 220)))
        XCTAssertFalse(timeline.matchesForPractice(row(5.03, 220)))
    }
    func testBufferRetainsStrictMetricAndMissingFullDenominator() {
        let rows = stride(from: 0.01, to: 5.0, by: 0.02).map { t -> PracticeObservation in
            let index = min(4, Int(max(0, t - 0.08)))
            return row(t, timeline.notes[index].target.frequency)
        }
        let report = timeline.score(observations: rows)
        XCTAssertEqual(report.summary.practiceMatchPercent, 100, accuracy: 1e-9)
        XCTAssertLessThan(report.summary.accuracyPercent, 100)
        XCTAssertGreaterThan(report.results.reduce(0) { $0 + $1.transitionAcceptedFrames }, 0)
        XCTAssertEqual(report.results.reduce(0) { $0 + $1.eligibleDuration }, 5)
        let firstOnly = timeline.score(observations: rows.filter { $0.time < 1 })
        XCTAssertEqual(firstOnly.summary.practiceMatchPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(timeline.score(observations: []).summary.practiceMatchPercent, 0)
    }
    func testMissingBoundarySamplesAreNotExcludedOrCredited() {
        let rows = stride(from: 0.01, to: 5.0, by: 0.02).map { t -> PracticeObservation in
            let edge = t.truncatingRemainder(dividingBy: 1)
            return row(t, edge < 0.1 || edge > 0.9 ? nil : timeline.notes[Int(t)].target.frequency)
        }
        let result = timeline.score(observations: rows)
        XCTAssertEqual(result.summary.practiceMatchPercent, result.summary.accuracyPercent)
        XCTAssertLessThan(result.summary.practiceMatchPercent, 85)
    }
    func testNormalWithinBandVibratoIsAlreadyAcceptedWithoutWiderThresholds() {
        let rows = stride(from: 0.01, to: 5.0, by: 0.02).map { t -> PracticeObservation in
            let hz = timeline.notes[Int(t)].target.frequency
            return row(t, hz * pow(2, 40 * sin(2 * .pi * 6 * t) / 1200))
        }
        let result = timeline.score(observations: rows)
        XCTAssertEqual(result.summary.practiceMatchPercent, 100)
        XCTAssertEqual(result.summary.accuracyPercent, 100)
        let wrong = rows.map { row($0.time, timeline.notes[Int($0.time)].target.frequency * 2) }
        XCTAssertEqual(timeline.score(observations: wrong).summary.practiceMatchPercent, 0)
    }
}
