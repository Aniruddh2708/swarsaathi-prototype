import Foundation
import Dispatch
import XCTest
@testable import SwarSaathiCore

final class PitchDetectorTests: XCTestCase {
    private func tone(_ hz: Double, rate: Double = 44100, count: Int = 2048,
                      amplitude: Double = 0.25, harmonics: Bool = false) -> [Float] {
        (0..<count).map { i in
            let phase = 2 * Double.pi * hz * Double(i) / rate
            return Float(amplitude * sin(phase) + (harmonics ? 0.10 * sin(2 * phase) + 0.05 * sin(3 * phase) : 0))
        }
    }

    private func estimate(_ samples: [Float], rate: Double = 44100,
                          config: PitchConfig = PitchConfig()) -> (frequency: Double, confidence: Double)? {
        let detector = YINPitchDetector(sampleRate: rate, config: config)
        return samples.withUnsafeBufferPointer { detector.detect($0.baseAddress!) }
    }

    func testCleanSyntheticFrequencyAccuracy() throws {
        var errors: [Double] = []
        for rate in [44100.0, 48000.0] {
            for size in [2048, 4096] {
                var config = PitchConfig()
                config.frameSize = size
                config.minFrequency = 65
                config.maxFrequency = 1100
                for hz in [75.0, 82.41, 110, 146.83, 196, 233.08, 329.63, 440, 659.25, 880, 1000] {
                    let result = try XCTUnwrap(estimate(tone(hz, rate: rate, count: size), rate: rate, config: config), "\(hz)Hz / \(rate)Hz / \(size)")
                    let error = abs(PitchMath.cents(detected: result.frequency, expected: hz))
                    errors.append(error)
                    XCTAssertLessThan(error, 10, "\(hz)Hz / \(rate)Hz / \(size)")
                    XCTAssertGreaterThan(result.confidence, 0.85)
                }
            }
        }
        print("DSP_CLEAN_METRICS cases=\(errors.count) max_absolute_cents=\(errors.max()!) median_absolute_cents=\(PitchMath.median(errors)!) synthetic_only=true")
    }

    func testDefaultLowerSearchBoundaryIsDetected() throws {
        let result = try XCTUnwrap(estimate(tone(70)))
        XCTAssertLessThan(abs(PitchMath.cents(detected: result.frequency, expected: 70)), 10)
    }

    func testHarmonicRichTones() throws {
        for hz in [82.41, 146.83, 233.08, 440, 880] {
            let result = try XCTUnwrap(estimate(tone(hz, harmonics: true)))
            XCTAssertLessThan(abs(PitchMath.cents(detected: result.frequency, expected: hz)), 10)
        }
    }

    func testSilenceDoesNotBecomePitch() {
        XCTAssertNil(estimate(Array(repeating: 0, count: 2048)))
    }

    func testRawOctaveTransitionRemainsAnOctave() throws {
        let low = try XCTUnwrap(estimate(tone(220)))
        let high = try XCTUnwrap(estimate(tone(440)))
        XCTAssertLessThan(abs(PitchMath.cents(detected: high.frequency, expected: low.frequency) - 1200), 1)
    }

    func testSmootherDoesNotBridgeUnvoicedFrame() {
        var smoother = PitchSmoother()
        for _ in 0..<5 { _ = smoother.process(220) }
        XCTAssertNil(smoother.process(nil), "A missing microphone pitch must break the graph trace immediately")
    }

    func testDifferenceMatchesSimpleConstantWindowReference() throws {
        var state: UInt64 = 42
        let samples: [Float] = (0..<2048).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 40) / Double(1 << 24) * 0.5 + 0.3)
        }
        let detector = YINPitchDetector(sampleRate: 44100, config: PitchConfig())
        let actual = try XCTUnwrap(detector.differenceValues(samples))
        var maximumError = 0.0
        for lag in actual.indices {
            var expected = 0.0
            for j in 0..<detector.differenceWindowSize {
                let delta = Double(samples[j]) - Double(samples[j + lag])
                expected += delta * delta
            }
            maximumError = max(maximumError, abs(Double(actual[lag]) - expected))
        }
        XCTAssertLessThan(maximumError, 0.002, "Float-vDSP/scalar cancellation allowance, not a cents tolerance")
        print("DSP_DIFFERENCE_METRICS max_absolute_float_difference=\(maximumError)")
    }

    func testSharedPreprocessingRemovesDCAndAppliesActualSilenceGate() throws {
        let detector = YINPitchDetector(sampleRate: 44100, config: PitchConfig())
        let input = tone(220).map { $0 + 0.4 }
        let result = detector.analyze(input, time: 12.5)
        let frequency = try XCTUnwrap(result.rawFrequency)
        XCTAssertLessThan(abs(PitchMath.cents(detected: frequency, expected: 220)), 10)
        XCTAssertEqual(result.time, 12.5)
        XCTAssertEqual(result.frequency, result.rawFrequency)
        XCTAssertEqual(result.level, 0.25 / sqrt(2), accuracy: 0.003)
        XCTAssertNil(detector.analyze(Array(repeating: 0.4, count: 2048)).rawFrequency)
        XCTAssertNil(detector.analyze(tone(220, amplitude: 0.0003).map { $0 + 0.4 }).rawFrequency)
        XCTAssertNil(detector.analyze(Array(repeating: 0, count: 2048)).rawFrequency)
    }

    func testModerateNoiseRetainsKnownFundamental() throws {
        var state: UInt64 = 89
        for hz in [82.41, 196, 440, 880] {
            let samples = tone(hz).map { value -> Float in
                state = state &* 6364136223846793005 &+ 1
                return value + Float((Double(state >> 40) / Double(1 << 24) - 0.5) * 0.04)
            }
            let detector = YINPitchDetector(sampleRate: 44100, config: PitchConfig())
            let result = detector.analyze(samples)
            let actual = try XCTUnwrap(result.rawFrequency)
            XCTAssertLessThan(abs(PitchMath.cents(detected: actual, expected: hz)), 10)
        }
    }

    func testInvalidAndUndersizedBuffersAreRejectedWithoutUnsafeReads() {
        let detector = YINPitchDetector(sampleRate: 44100, config: PitchConfig())
        XCTAssertEqual(detector.requiredSampleCount, 2048)
        XCTAssertNil(detector.analyze([]).rawFrequency)
        XCTAssertNil(detector.analyze(tone(220, count: 2047)).rawFrequency)
        XCTAssertNil(detector.analyze(Array(repeating: .nan, count: 2048)).rawFrequency)
        XCTAssertNil(detector.analyze(Array(repeating: .infinity, count: 2048)).rawFrequency)
        XCTAssertNil(detector.analyze(tone(220), time: .nan).rawFrequency)
        let short = [Float](repeating: 0, count: 16)
        short.withUnsafeBufferPointer { pointer in
            XCTAssertNil(detector.detect(pointer.baseAddress!, count: short.count))
        }
    }

    func testInvalidConfigurationIsInertInsteadOfReadingBeyondFrame() {
        var invalid = [PitchConfig]()
        var c = PitchConfig(); c.frameSize = 256; invalid.append(c)
        c = PitchConfig(); c.minFrequency = 0; invalid.append(c)
        c = PitchConfig(); c.minFrequency = 20; c.frameSize = 1024; invalid.append(c)
        c = PitchConfig(); c.maxFrequency = .nan; invalid.append(c)
        c = PitchConfig(); c.hopSize = 4096; invalid.append(c)
        c = PitchConfig(); c.minConfidence = 1; invalid.append(c)
        for config in invalid {
            let detector = YINPitchDetector(sampleRate: 44100, config: config)
            XCTAssertNotNil(detector.configurationError)
            XCTAssertEqual(detector.requiredSampleCount, 0)
            XCTAssertNil(detector.analyze([0]).rawFrequency)
        }
        for rate in [Double.nan, .infinity, 0, -1] {
            let detector = YINPitchDetector(sampleRate: rate, config: PitchConfig())
            XCTAssertNotNil(detector.configurationError)
            XCTAssertNil(detector.analyze([0]).rawFrequency)
        }
    }

    func testRawPitchRemainsIndependentFromDisplaySmoothing() throws {
        let detector = YINPitchDetector(sampleRate: 44100, config: PitchConfig())
        var smoother = PitchSmoother()
        for _ in 0..<5 { _ = smoother.process(detector.analyze(tone(220)).rawFrequency) }
        let high = detector.analyze(tone(440))
        let raw = try XCTUnwrap(high.rawFrequency)
        XCTAssertLessThan(abs(PitchMath.cents(detected: raw, expected: 440)), 10)
        let display = try XCTUnwrap(smoother.process(raw))
        XCTAssertGreaterThan(abs(PitchMath.cents(detected: raw, expected: display)), 1000)
        XCTAssertNil(smoother.process(nil))
        XCTAssertNil(smoother.process(.nan))
    }

    func testDetectorOnlySyntheticComputeTiming() throws {
        let config = PitchConfig(), rate = 44100.0
        let detector = YINPitchDetector(sampleRate: rate, config: config)
        let samples = tone(220)
        for _ in 0..<20 { _ = detector.analyze(samples) }
        var milliseconds: [Double] = []
        for _ in 0..<500 {
            let began = DispatchTime.now().uptimeNanoseconds
            let result = detector.analyze(samples)
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            XCTAssertNotNil(result.rawFrequency)
        }
        milliseconds.sort()
        #if canImport(Accelerate)
        let implementation = "Apple_Accelerate"
        #else
        let implementation = "Linux_scalar_equivalent"
        #endif
        print("DSP_BENCHMARK implementation=\(implementation) calls=500 window_samples=\(config.frameSize) sample_rate=\(rate) median_ms=\(milliseconds[250]) p95_ms=\(milliseconds[475]) sample_window_ms=\(Double(config.frameSize) / rate * 1000) minimum_center_buffer_ms=\(Double(config.frameSize) / rate * 500) synthetic_only=true end_to_end_latency_measured=false")
    }
}
