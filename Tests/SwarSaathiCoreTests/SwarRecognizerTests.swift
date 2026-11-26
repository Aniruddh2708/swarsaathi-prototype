import Foundation
import XCTest
@testable import SwarSaathiCore

final class SwarRecognizerTests: XCTestCase {
    private func key(_ v: SwarVariant, _ o: Int = 0) -> SwarKey { SwarKey(variant: v, octave: o) }
    func testIndependentRecognitionAcrossSupportedOctaves() {
        for tonic in [80.0, 130, 220, 440, 900] {
            let r = SwarRecognizer(confirmedSa: tonic)
            for variant in TuningProfile.baseline.ratios.keys {
                for octave in -5...5 {
                    let k = key(variant, octave)
                    guard let hz = TuningProfile.baseline.frequency(k, sa: tonic), (70...1000).contains(hz) else { continue }
                    XCTAssertEqual(r.recognize(rawFrequency: hz, confidence: 0.99).key, k)
                }
            }
        }
    }
    func testVariantsRequireExplicitProfileAndAmbiguityIsRejected() {
        let r = SwarRecognizer(confirmedSa: 220)
        XCTAssertNil(r.recognize(rawFrequency: 220*pow(2,3.0/12),confidence:0.99).key)
        // Artificial equal-tempered fixture, NOT a tuning decision.
        let ratios = Dictionary(uniqueKeysWithValues: SwarVariant.allCases.map { ($0,pow(2,Double($0.rawValue)/12)) })
        let profile = TuningProfile(id:"test-only",ratios:ratios)
        let fixture = SwarRecognizer(confirmedSa: 220,tuning:profile)
        for variant in SwarVariant.allCases {
            XCTAssertEqual(fixture.recognize(rawFrequency:profile.frequency(key(variant),sa:220),confidence:0.99).key,key(variant))
        }
        XCTAssertEqual(fixture.recognize(rawFrequency:220*pow(2,0.5/12),confidence:0.99).status,.ambiguous)
    }
    func testRejectedInputsAndWrongExerciseNoteRemainIndependent() {
        let r = SwarRecognizer(confirmedSa: 220)
        XCTAssertEqual(r.recognize(rawFrequency:nil,confidence:0).status,.unvoiced)
        XCTAssertEqual(r.recognize(rawFrequency:275,confidence:0.7).status,.unreliable)
        XCTAssertEqual(r.recognize(rawFrequency:1200,confidence:0.99).status,.outsideRange)
        XCTAssertEqual(r.recognize(rawFrequency:247.5,confidence:0.99).key,key(.shuddhaRe))
        XCTAssertEqual(r.recognize(rawFrequency:440,confidence:0.99).key,key(.sa,1))
        XCTAssertEqual(SwarRecognizer(confirmedSa:.nan).recognize(rawFrequency:220,confidence:0.99).status,.invalidConfiguration)
    }
    func testDetectorDiagnosticResetsWithoutChangingPitch() {
        let d = YINPitchDetector(sampleRate:48000,config:PitchConfig())
        XCTAssertNil(d.analyze([Float](repeating:0,count:2048)).rawFrequency)
        XCTAssertEqual(d.lastAnalysisRejection,.belowRMS)
        let tone = (0..<2048).map { Float(0.1*sin(2*Double.pi*220*Double($0)/48000)) }
        XCTAssertNotNil(d.analyze(tone).rawFrequency); XCTAssertNil(d.lastAnalysisRejection)
        XCTAssertNil(d.analyze([]).rawFrequency); XCTAssertEqual(d.lastAnalysisRejection,.invalidInput)
    }
}
