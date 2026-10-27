import XCTest
@testable import SwarSaathiCore

final class CalibrationTests: XCTestCase {
    private func rows(_ hz: Double?, duration: Double = 3.2, hop: Double = 0.024,
                      confidence: Double = 0.99) -> [CalibrationObservation] {
        stride(from: 0.0, through: duration, by: hop).map {
            CalibrationObservation(time: $0, frequency: hz, confidence: confidence)
        }
    }

    private func sample(_ hz: Double) throws -> CalibrationSample {
        try CalibrationAnalyzer.summarize(rows(hz), recordingStart: 0, recordingEnd: 3.2)
    }

    func testStableSampleUsesRawMedianAndCoverage() throws {
        let result = try sample(221.9)
        XCTAssertEqual(result.medianHz, 221.9, accuracy: 1e-9)
        XCTAssertGreaterThan(result.coverage, 0.98)
        XCTAssertGreaterThan(result.voicedSeconds, 2.5)
        XCTAssertEqual(result.stabilityCents, 0, accuracy: 1e-9)
    }

    func testSilenceAndInsufficientFramesAreRejected() {
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(nil, confidence: 0)))
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(Array(rows(220).prefix(12))))
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(220, duration: 1.1)))
    }

    func testLowConfidenceInvalidFrequencyAndSparseEvidenceStayMissing() {
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(220, confidence: 0.5)))
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(.nan)))
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(.infinity)))
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(rows(220, duration: 5, hop: 0.2)))
        let one = CalibrationObservation(time: 1, frequency: 220, confidence: 0.99)
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(Array(repeating: one, count: 200)))
    }

    func testMissingVoiceCannotBeFilteredOutOfCoverage() {
        let patchy = rows(220).enumerated().map { index, row in
            CalibrationObservation(time: row.time, frequency: index % 2 == 0 ? row.frequency : nil,
                                   confidence: index % 2 == 0 ? 0.99 : 0)
        }
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(patchy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("70%"))
        }
    }

    func testAbsentEndsAreIncludedByExplicitRecordingClock() {
        let short = rows(220, duration: 1.5)
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(short, recordingStart: 0, recordingEnd: 3.2))
    }

    func testUnstablePitchAndOctaveAlternationAreRejected() {
        let unstable = rows(220).enumerated().map { i, row in
            CalibrationObservation(time: row.time, frequency: i % 2 == 0 ? 220 : 440, confidence: 0.99)
        }
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(unstable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("moved"))
        }
    }

    func testBeginningAndEndAreTrimmedWithoutPrefilteringAllOtherErrors() throws {
        let transients = rows(220).map { row in
            CalibrationObservation(time: row.time,
                                   frequency: row.time < 0.3 || row.time > 2.9 ? 440 : 220,
                                   confidence: 0.99)
        }
        let result = try CalibrationAnalyzer.summarize(transients, recordingStart: 0, recordingEnd: 3.2)
        XCTAssertEqual(result.medianHz, 220, accuracy: 1e-9)
        XCTAssertEqual(result.spreadCents, 0, accuracy: 1e-9)
    }

    func testRecommendationFitsOriginalFiveNoteRatiosAndIsNotMiddle() throws {
        let samples = try [130.0, 195.0, 310.0].map { try sample($0) }
        let result = try CalibrationAnalyzer.recommend(samples: samples)
        XCTAssertNotEqual(result.saHz, samples[1].medianHz)
        let grid = 69 + 12 * log2(result.saHz / 440)
        XCTAssertEqual(grid, grid.rounded(), accuracy: 1e-9)
        let targets = Alankaar.fiveNote.targets(sa: result.saHz, tuning: .justShuddha)
        XCTAssertEqual(targets.map { $0.label }, ["Sa", "Re", "Ga", "Re", "Sa"])
        XCTAssertEqual(targets[2].frequency / result.saHz, 1.25, accuracy: 1e-12)
        for note in targets {
            XCTAssertGreaterThanOrEqual(note.frequency, result.lowerHz)
            XCTAssertLessThanOrEqual(note.frequency, result.upperHz)
        }
    }

    func testCloseAndRepeatedLowMiddleMeasurementsAreAllowed() throws {
        let samples = try [221.90, 223.57, 321.32].map { try sample($0) }
        let result = try CalibrationAnalyzer.recommend(samples: samples)
        XCTAssertEqual(result.saHz, 233.081880759, accuracy: 1e-6)
        XCTAssertEqual(result.measuredHz, [221.90, 223.57, 321.32])
        XCTAssertTrue(result.explanation.contains("similar"))
        let same = try CalibrationAnalyzer.recommend(samples: [samples[0], samples[0], samples[2]])
        XCTAssertTrue(same.supports(same.saHz))
    }

    func testContradictoryLowMiddleHighLabelsAreRejected() throws {
        let reversed = try [310.0, 195.0, 130.0].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: reversed))
        let middleAboveHigh = try [130.0, 320.0, 310.0].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: middleAboveHigh))
        let middleBelowLow = try [195.0, 130.0, 310.0].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: middleBelowLow))
    }

    func testOverlappingMeasuredUncertaintyDoesNotForcePitchSeparation() throws {
        func uncertain(_ hz: Double) throws -> CalibrationSample {
            let observations = rows(hz).enumerated().map { i, row in
                CalibrationObservation(time: row.time,
                                       frequency: hz * pow(2, (i % 2 == 0 ? -10.0 : 10) / 1200),
                                       confidence: 0.99)
            }
            return try CalibrationAnalyzer.summarize(observations, recordingStart: 0, recordingEnd: 3.2)
        }
        let low = try uncertain(195 * pow(2, 15.0 / 1200))
        let middle = try uncertain(195)
        let high = try sample(310)
        XCTAssertGreaterThan(low.medianHz, middle.medianHz)
        XCTAssertGreaterThan(low.spreadCents, 19)
        let result = try CalibrationAnalyzer.recommend(samples: [low, middle, high])
        XCTAssertTrue(result.supports(result.saHz))
    }

    func testUnsupportedRangeAndInvalidSampleStatisticsAreRejected() throws {
        let narrow = try [220.0, 240.0, 250.0].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: narrow))
        let close = try [221.90, 223.57, 321.32].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: close, exercise: .standard))
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: Array(close.prefix(2))))
        let invalid = CalibrationSample(medianHz: 220, stabilityCents: 0, spreadCents: 0,
                                        voicedSeconds: 0.5, usableSeconds: 2, coverage: 0.25, frameCount: 20)
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: [invalid, close[1], close[2]]))
    }

    func testContradictoryCoverageStatisticsAreRejected() throws {
        let other = try [195.0, 310.0].map { try sample($0) }
        let inconsistent = CalibrationSample(medianHz: 130, stabilityCents: 0, spreadCents: 0,
                                             voicedSeconds: 1, usableSeconds: 100,
                                             coverage: 0.99, frameCount: 200)
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: [inconsistent] + other))
    }

    func testDifferentRangesTransposeAndResultsAreRepeatable() throws {
        let lower = try [130.0, 195.0, 310.0].map { try sample($0) }
        let higher = try [260.0, 390.0, 620.0].map { try sample($0) }
        let first = try CalibrationAnalyzer.recommend(samples: lower)
        XCTAssertEqual(first, try CalibrationAnalyzer.recommend(samples: lower))
        XCTAssertEqual(try CalibrationAnalyzer.recommend(samples: higher).saHz / first.saHz, 2, accuracy: 1e-9)
    }

    func testConfirmationIsExplicitButReferencePlaybackIsOptional() throws {
        let result = try CalibrationAnalyzer.recommend(samples: [130, 195, 310].map { try sample($0) })
        var state = CalibrationSession()
        XCTAssertFalse(state.canConfirm)
        XCTAssertThrowsError(try state.confirm())
        state.propose(result)
        XCTAssertNil(state.confirmedSa, "A valid proposal must still require the singer's explicit confirmation")
        XCTAssertTrue(state.canConfirm, "Listening must not secretly disable Confirm")
        try state.confirm()
        XCTAssertEqual(state.confirmedSa, result.saHz)
        state.propose(result)
        state.referenceFinished(hz: result.saHz, successful: false)
        XCTAssertTrue(state.canConfirm, "Interrupted optional playback must not lock confirmation")
        state.referenceFinished(hz: result.saHz * 2, successful: true)
        XCTAssertNil(state.auditionedSa)
        XCTAssertTrue(state.canConfirm)
        try state.confirm()
        XCTAssertEqual(state.confirmedSa, result.saHz)
    }

    func testAdjustmentsAndNewSamplesInvalidateConfirmation() throws {
        let result = try CalibrationAnalyzer.recommend(samples: [130, 195, 310].map { try sample($0) })
        var state = CalibrationSession()
        state.propose(result)
        state.referenceFinished(hz: result.saHz, successful: true)
        try state.confirm()
        try state.adjust(to: result.saHz + 1)
        XCTAssertNil(state.confirmedSa)
        XCTAssertTrue(state.canConfirm, "Adjustment needs manual confirmation, not mandatory playback")
        XCTAssertThrowsError(try state.adjust(to: result.upperHz))
        XCTAssertEqual(state.recommendation?.saHz, result.saHz + 1)
        state.invalidate()
        XCTAssertNil(state.recommendation)
        XCTAssertNil(state.confirmedSa)
    }
}
