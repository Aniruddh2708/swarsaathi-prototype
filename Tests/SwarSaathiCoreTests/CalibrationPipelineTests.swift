import Foundation
import XCTest
@testable import SwarSaathiCore

/// Synthetic PCM through the same worker and raw YIN path used by the microphone.
/// These tests establish numerical and policy behavior, not accuracy on real singers.
final class CalibrationPipelineTests: XCTestCase {
    private let duration = 3.2

    private func vowel(_ hz: Double, rate: Double, vibratoCents: Double = 20) -> [Float] {
        var phase = 0.0
        var seed: UInt64 = 27082026
        return (0..<Int(duration * rate)).map { index in
            let time = Double(index) / rate
            let frequency = hz * pow(2, vibratoCents * sin(2 * .pi * 5 * time) / 1200)
            phase += 2 * .pi * frequency / rate
            seed = seed &* 6364136223846793005 &+ 1
            let noise = (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.012
            let envelope = min(1, min(time / 0.04, (duration - time) / 0.04))
            return Float(envelope * (0.22 * sin(phase) + 0.10 * sin(2 * phase)
                                    + 0.06 * sin(3 * phase)) + noise + 0.03)
        }
    }

    private func measured(_ hz: Double, rate: Double) throws -> CalibrationSample {
        let pcm = vowel(hz, rate: rate)
        let worker = AudioProcessingRun(generation: 1, sampleRate: rate)
        var observations: [CalibrationObservation] = []
        pcm.withUnsafeBufferPointer { pointer in
            for offset in stride(from: 0, to: pcm.count, by: 1024) {
                let count = min(1024, pcm.count - offset)
                XCTAssertTrue(worker.enqueue(pointer.baseAddress! + offset, count: count,
                                             time: Double(offset) / rate))
                XCTAssertTrue(worker.processOne())
                observations.append(contentsOf: worker.delivery.drain().map {
                    CalibrationObservation(time: $0.time, frequency: $0.rawFrequency,
                                           confidence: $0.confidence)
                })
            }
        }
        worker.stop()
        XCTAssertEqual(worker.diagnostics.droppedSamples, 0)
        XCTAssertEqual(worker.diagnostics.deliveryDroppedFrames, 0)
        XCTAssertEqual(worker.diagnostics.discontinuities, 0)
        return try CalibrationAnalyzer.summarize(observations, recordingStart: 0,
                                                 recordingEnd: duration)
    }

    private func idealSample(_ hz: Double) throws -> CalibrationSample {
        let observations = stride(from: 0.0, through: duration, by: 0.02).map {
            CalibrationObservation(time: $0, frequency: hz, confidence: 0.99)
        }
        return try CalibrationAnalyzer.summarize(observations, recordingStart: 0,
                                                 recordingEnd: duration)
    }

    func testMeasuredHarmonicVowelsRecommendTheSameFittingTonicAsKnownPitches() throws {
        let ranges = [[82.41, 110.0, 164.82], [130.0, 195.0, 310.0],
                      [221.90, 223.57, 321.32], [260.0, 390.0, 620.0]]
        var errors: [Double] = []
        var coverages: [Double] = []
        var matchingRecommendations = 0
        for rate in [44100.0, 48000.0] {
            for expected in ranges {
                let samples = try expected.map { try measured($0, rate: rate) }
                for (sample, frequency) in zip(samples, expected) {
                    let error = abs(PitchMath.cents(detected: sample.medianHz, expected: frequency))
                    errors.append(error)
                    coverages.append(sample.coverage)
                    XCTAssertLessThan(error, 3, "Median of synthetic vowel at \(frequency) Hz / \(rate) Hz")
                    XCTAssertGreaterThan(sample.coverage, 0.95)
                }
                let actual = try CalibrationAnalyzer.recommend(samples: samples)
                let ideal = try CalibrationAnalyzer.recommend(samples: expected.map { try idealSample($0) })
                XCTAssertEqual(actual.saHz, ideal.saHz, accuracy: 1e-9)
                if abs(actual.saHz - ideal.saHz) < 1e-9 { matchingRecommendations += 1 }
                XCTAssertTrue(actual.supports(actual.saHz))
                for target in Alankaar.fiveNote.targets(sa: actual.saHz, tuning: .justShuddha) {
                    XCTAssertGreaterThanOrEqual(target.frequency, actual.lowerHz)
                    XCTAssertLessThanOrEqual(target.frequency, actual.upperHz)
                }
            }
        }
        print("SYNTHETIC_CALIBRATION_PIPELINE vowels=\(errors.count) sample_rates=44100,48000 vibrato_peak_cents=20 harmonics=3 additive_noise=true max_median_error_cents=\(errors.max()!) median_error_cents=\(PitchMath.median(errors)!) minimum_coverage=\(coverages.min()!) matching_tonic_recommendations=\(matchingRecommendations)/8 real_singing=false")
    }

    func testMeasuredStableVowelsStillRejectReversedLabelsAndInsufficientRange() throws {
        let low = try measured(130, rate: 48000)
        let middle = try measured(195, rate: 48000)
        let high = try measured(310, rate: 48000)
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: [high, middle, low]))
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: [low, high, middle]))
        XCTAssertThrowsError(try CalibrationAnalyzer.recommend(samples: [middle, middle, middle]))
        XCTAssertTrue(try CalibrationAnalyzer.recommend(samples: [low, middle, high], exercise: .standard)
            .supports(CalibrationAnalyzer.recommend(samples: [low, middle, high], exercise: .standard).saHz))
    }

    func testSmallOutliersDoNotReplaceTheMeasuredMedianOrPermitPersistentInstability() throws {
        let stable = stride(from: 0.0, through: duration, by: 0.02).enumerated().map { index, time in
            CalibrationObservation(time: time, frequency: index % 25 == 0 ? 440 : 220,
                                   confidence: 0.99)
        }
        let sample = try CalibrationAnalyzer.summarize(stable, recordingStart: 0, recordingEnd: duration)
        XCTAssertEqual(sample.medianHz, 220, accuracy: 1e-9)
        XCTAssertGreaterThan(sample.coverage, 0.99)
        let unstable = stable.enumerated().map { index, row in
            CalibrationObservation(time: row.time, frequency: index % 3 == 0 ? 440 : 220,
                                   confidence: row.confidence)
        }
        XCTAssertThrowsError(try CalibrationAnalyzer.summarize(unstable, recordingStart: 0,
                                                               recordingEnd: duration))
    }
}
