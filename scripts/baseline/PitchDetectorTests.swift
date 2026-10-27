import Foundation
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
}
