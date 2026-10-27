import XCTest
@testable import SwarSaathiCore

final class CalibrationCaptureTests: XCTestCase {
    private func rows(until end: Double, voiceStarts: Double = 0,
                      frequency: (Double) -> Double = { _ in 220 }) -> [CalibrationObservation] {
        stride(from: 0.0, through: end, by: 0.024).map { time in
            CalibrationObservation(time: time,
                frequency: time < voiceStarts ? nil : frequency(time),
                confidence: time < voiceStarts ? 0 : 0.99)
        }
    }

    func testEarlyInconclusiveEvidenceKeepsRecordingInsteadOfRejecting() {
        let decision = CalibrationCapture.evaluate(rows(until: 3.2, voiceStarts: 1.4), start: 0, now: 3.2)
        guard case .collecting = decision else {
            return XCTFail("A slow onset at the first checkpoint must keep recording, not stop with an error")
        }
    }

    func testAdditionalVoiceCanResolveTheSameFullRecording() throws {
        let all = rows(until: 6, voiceStarts: 1.4)
        guard case .accepted(let sample) = CalibrationCapture.evaluate(all, start: 0, now: 6) else {
            return XCTFail("Additional stable voice should resolve a delayed onset")
        }
        XCTAssertEqual(sample.medianHz, 220, accuracy: 1e-9)
        XCTAssertLessThan(sample.coverage, 0.85, "The earlier silence must remain in coverage")
        XCTAssertEqual(sample.usableSeconds, 5.4, accuracy: 1e-9)
    }

    func testNormalVariationAcceptedAfterMinimumDuration() {
        let observations = rows(until: 3.2) { 220 * pow(2, 30 * sin(2 * .pi * 5 * $0) / 1200) }
        guard case .accepted(let sample) = CalibrationCapture.evaluate(observations, start: 0, now: 3.2) else {
            return XCTFail("A steady center with modest variation should be usable")
        }
        XCTAssertEqual(sample.medianHz, 220, accuracy: 1)
        XCTAssertLessThan(sample.spreadCents, CalibrationAnalyzer.maximumSpreadCents)
        guard case .collecting = CalibrationCapture.evaluate(observations, start: 0, now: 2) else {
            return XCTFail("Never accept a fleeting stable pitch before the minimum duration")
        }
    }

    func testLargePersistentFluctuationsRejectAtBoundedDeadline() {
        let all = rows(until: 8) { Int($0 * 20) % 2 == 0 ? 220 : 440 }
        guard case .rejected = CalibrationCapture.evaluate(all, start: 0, now: 8) else {
            return XCTFail("Persistent octave alternation must be rejected at the deadline")
        }
    }

    func testSilenceStopsAtDeadlineAndManualStopDoesNotWait() {
        let silent = rows(until: 8, voiceStarts: 20)
        guard case .rejected = CalibrationCapture.evaluate(silent, start: 0, now: 8) else {
            return XCTFail("Recording must not run indefinitely in silence")
        }
        guard case .rejected = CalibrationCapture.evaluate(Array(silent.prefix(130)), start: 0, now: 3.2, manualStop: true) else {
            return XCTFail("An explicit stop must finish even if more evidence would help")
        }
    }
}
