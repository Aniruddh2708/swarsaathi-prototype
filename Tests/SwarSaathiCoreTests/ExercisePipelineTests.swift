import XCTest
@testable import SwarSaathiCore

/// Synthetic integration only. This never stands in for hardware singing.
final class ExercisePipelineTests: XCTestCase {
    private func analyze(_ input: [Float], timeline: PracticeTimeline) -> (PracticeSummary, [PracticeObservation]) {
        let rate = 44100.0
        let run = AudioProcessingRun(generation: 99, sampleRate: rate)
        var observations: [PracticeObservation] = []
        input.withUnsafeBufferPointer { pointer in
            for offset in stride(from: 0, to: input.count, by: 1024) {
                let count = min(1024, input.count - offset)
                XCTAssertTrue(run.enqueue(pointer.baseAddress! + offset, count: count, time: Double(offset) / rate))
                run.processOne()
                observations.append(contentsOf: run.delivery.drain().map {
                    PracticeObservation(time: $0.time, frequency: $0.rawFrequency, confidence: $0.confidence)
                })
            }
        }
        run.stop()
        XCTAssertEqual(run.diagnostics.droppedSamples, 0)
        return (timeline.score(observations: observations).summary, observations)
    }

    func testReferenceWaveformThroughActualYINAndFullExerciseScoring() {
        let timeline = PracticeTimeline(targets: Alankaar.fiveNote.targets(sa: 220, tuning: .justShuddha), bpm: 72)
        let output = analyze(ReferenceSynthesis.samples(timeline: timeline), timeline: timeline)
        // Window transitions and missing acquisition edges are intentionally
        // retained. No success-frame filtering or target-derived observation.
        XCTAssertGreaterThan(output.0.accuracyPercent, 80)
        XCTAssertFalse(output.1.isEmpty)
        XCTAssertEqual(output.0.total, 5)
        print("SYNTHETIC_EXERCISE_PIPELINE bpm=72 notes=5 accuracy_percent=\(output.0.accuracyPercent) coverage_percent=\(output.0.reliableCoveragePercent) raw_observations=\(output.1.count) real_singing=false")
    }

    func testSilenceAndWrongOctaveThroughActualYINLowerFullScore() {
        let targets = Alankaar.fiveNote.targets(sa: 220, tuning: .justShuddha)
        let expected = PracticeTimeline(targets: targets, bpm: 72)
        let silence = [Float](repeating: 0, count: Int(expected.duration * 44100))
        XCTAssertEqual(analyze(silence, timeline: expected).0.accuracyPercent, 0)
        let wrong = PracticeTimeline(targets: Alankaar.fiveNote.targets(sa: 440, tuning: .justShuddha), bpm: 72)
        let output = analyze(ReferenceSynthesis.samples(timeline: wrong), timeline: expected)
        XCTAssertEqual(output.0.accuracyPercent, 0)
        XCTAssertGreaterThan(output.0.reliableCoveragePercent, 80)
    }
}
