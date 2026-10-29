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

    func testRecommendationBalancesMeasuredRangeAndMiddleWithoutExerciseRatios() throws {
        let samples = try [130.0, 195.0, 310.0].map { try sample($0) }
        let result = try CalibrationAnalyzer.recommend(samples: samples)
        // This voice-only reference is G3. The old five-note fit returned F3.
        XCTAssertEqual(result.saHz, 195.997717991, accuracy: 1e-6)
        XCTAssertNotEqual(result.saHz, samples[1].medianHz)
        XCTAssertEqual(result.rangeCenterHz, sqrt(130 * 310), accuracy: 1e-9)
        XCTAssertEqual(result.preferredSaHz, sqrt(sqrt(130 * 310) * 195), accuracy: 1e-9)
        XCTAssertEqual(result.selectionMethod, "voice_range_center_and_middle_v1")
        XCTAssertTrue(result.supports(result.saHz))
        let grid = 69 + 12 * log2(result.saHz / 440)
        XCTAssertEqual(grid, grid.rounded(), accuracy: 1e-9)
    }

    func testCloseAndRepeatedLowMiddleMeasurementsAreAllowed() throws {
        let samples = try [221.90, 223.57, 321.32].map { try sample($0) }
        let result = try CalibrationAnalyzer.recommend(samples: samples)
        XCTAssertTrue(result.supports(result.saHz))
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
        let narrow = try [220.0, 221.0, 222.0].map { try sample($0) }
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: narrow))
        let close = try [221.90, 223.57, 321.32].map { try sample($0) }
        let measured = try CalibrationAnalyzer.recommend(samples: close)
        XCTAssertFalse(Alankaar.standard.fits(sa: measured.saHz, lowerHz: measured.lowerHz, upperHz: measured.upperHz))
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
        XCTAssertThrowsError(try state.adjust(to: result.upperHz * 1.01))
        XCTAssertEqual(state.recommendation?.saHz, result.saHz + 1)
        state.invalidate()
        XCTAssertNil(state.recommendation)
        XCTAssertNil(state.confirmedSa)
    }
    func testTonicDoesNotChangeWhenExerciseChanges() throws {
        let samples = try [130.0, 195.0, 310.0].map { try sample($0) }
        let proposal = try CalibrationAnalyzer.recommend(samples: samples)
        var session = CalibrationSession()
        session.propose(proposal)
        try session.confirm()
        XCTAssertTrue(Alankaar.fiveNote.fits(sa: session.confirmedSa!, lowerHz: proposal.lowerHz, upperHz: proposal.upperHz))
        XCTAssertFalse(Alankaar.standard.fits(sa: session.confirmedSa!, lowerHz: proposal.lowerHz, upperHz: proposal.upperHz))
        XCTAssertEqual(session.recommendation, proposal)
        XCTAssertEqual(session.confirmedSa, proposal.saHz)
        XCTAssertEqual(try CalibrationAnalyzer.recommend(samples: samples), proposal)
    }

    func testUsableVoiceRangeDoesNotNeedToContainTheFiveNoteExercise() throws {
        let samples = try [220.0, 240.0, 260.0].map { try sample($0) }
        let result = try CalibrationAnalyzer.recommend(samples: samples)
        XCTAssertTrue(result.supports(result.saHz))
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: result.saHz, lowerHz: result.lowerHz, upperHz: result.upperHz))
        var session = CalibrationSession()
        session.propose(result)
        try session.confirm()
        XCTAssertEqual(session.confirmedSa, result.saHz)
    }

    func testManualSaCanBeConfirmedEvenIfGaWouldExceedTheRange() throws {
        var session = CalibrationSession()
        session.propose(try CalibrationAnalyzer.recommend(samples: [130.0, 195.0, 310.0].map { try sample($0) }))
        try session.adjust(to: 280)
        try session.confirm()
        XCTAssertEqual(session.confirmedSa, 280)
    }

    func testLowHighAndMiddleEachContributeToTheVoiceOnlyProposal() throws {
        let baseline = try CalibrationAnalyzer.recommend(samples: [130.0, 195.0, 310.0].map { try sample($0) })
        let changedLow = try CalibrationAnalyzer.recommend(samples: [160.0, 195.0, 310.0].map { try sample($0) })
        let changedMiddle = try CalibrationAnalyzer.recommend(samples: [130.0, 240.0, 310.0].map { try sample($0) })
        let changedHigh = try CalibrationAnalyzer.recommend(samples: [130.0, 195.0, 440.0].map { try sample($0) })
        for changed in [changedLow, changedMiddle, changedHigh] {
            XCTAssertNotEqual(changed.saHz, baseline.saHz)
            XCTAssertTrue(changed.supports(changed.saHz))
        }
    }

    func testVoiceOnlyRecommendationAndManualConfirmationRoundTrip() throws {
        let proposal = try CalibrationAnalyzer.recommend(samples: [130.0, 195.0, 310.0].map { try sample($0) })
        let encoder = JSONEncoder()
        let data = try encoder.encode(proposal)
        XCTAssertEqual(try JSONDecoder().decode(SaRecommendation.self, from: data), proposal)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("minimumRatio"))
        XCTAssertFalse(text.contains("maximumRatio"))
        var session = CalibrationSession()
        session.propose(proposal)
        try session.adjust(to: proposal.upperHz)
        try session.confirm()
        XCTAssertEqual(session.confirmedSa, proposal.upperHz)
    }

}
