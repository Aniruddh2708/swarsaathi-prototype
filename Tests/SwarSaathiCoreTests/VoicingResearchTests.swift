import Foundation
import XCTest
@testable import SwarSaathiCore

final class VoicingResearchTests: XCTestCase {
    private let rate = 44100.0
    private let config = PitchConfig()
    private func tone(_ hz: Double, _ amplitude: Double, offset: Int = 0) -> [Float] {
        (0..<config.frameSize).map { i in Float(amplitude*sin(2*Double.pi*hz*Double(i+offset)/rate)) }
    }
    func testBaselineAcceptedPitchIsIdenticalForEveryMode() {
        for mode in VoicingExperiment.allCases {
            let control = YINPitchDetector(sampleRate:rate,config:config)
            let experiment = ExperimentalVoicing(sampleRate:rate,config:config,mode:mode)
            let samples = tone(220,0.1)
            let a = control.analyze(samples,time:0)
            let b = experiment.analyze(samples,time:0)
            XCTAssertEqual(a.rawFrequency,b.rawFrequency)
            XCTAssertEqual(a.confidence,b.confidence)
            XCTAssertEqual(a.level,b.level)
            XCTAssertEqual(experiment.stage,.baselineAccepted)
        }
    }
    func testQuietPeriodicRecoveryRequiresConsecutiveEvidence() {
        for mode in VoicingExperiment.allCases {
            let experiment = ExperimentalVoicing(sampleRate:rate,config:config,mode:mode)
            let hop = Double(config.hopSize)/rate
            let silent = [Float](repeating:0,count:config.frameSize)
            for i in 0..<24 { XCTAssertNil(experiment.analyze(silent,time:Double(i)*hop).rawFrequency) }
            let a = experiment.analyze(tone(220,0.008),time:24*hop)
            XCTAssertNil(a.rawFrequency)
            XCTAssertEqual(experiment.stage,.awaitingAgreement)
            let b = experiment.analyze(tone(220,0.008,offset:1024),time:25*hop)
            XCTAssertNotNil(b.rawFrequency)
            XCTAssertEqual(experiment.stage,.recovered)
            XCTAssertEqual(b.rawFrequency ?? 0,220,accuracy:1)
            XCTAssertLessThanOrEqual(experiment.appliedGain,2)
            XCTAssertLessThan(b.level,0.008)
            XCTAssertNil(experiment.analyze(silent,time:26*hop).rawFrequency)
        }
    }
    func testAdaptiveBootstrapAndNoiseContrastBlockRecovery() {
        for mode in [VoicingExperiment.adaptiveGate,.boundedNormalization] {
            let e = ExperimentalVoicing(sampleRate:rate,config:config,mode:mode)
            let hop = Double(config.hopSize)/rate
            let low = tone(220,0.008)
            XCTAssertNil(e.analyze(low,time:0).rawFrequency)
            XCTAssertEqual(e.stage,.noiseContrast)
            for i in 1...24 { _ = e.analyze(low,time:Double(i)*hop) }
            XCTAssertEqual(e.stage,.noiseContrast)
            XCTAssertNil(e.analyze(low,time:25*hop).rawFrequency)
        }
    }
    func testRecoveryDoesNotBridgeGapOrInvalidInput() {
        let e = ExperimentalVoicing(sampleRate:rate,config:config,mode:.levelAware)
        let low = tone(220,0.008), hop = Double(config.hopSize)/rate
        XCTAssertNil(e.analyze(low,time:0).rawFrequency)
        XCTAssertNil(e.analyze(low,time:3*hop).rawFrequency)
        XCTAssertNil(e.analyze([],time:4*hop).rawFrequency)
        XCTAssertNil(e.analyze(low,time:5*hop).rawFrequency)
    }
    func testSilenceNoiseAndLowHumNegativeControls() {
        var rng: UInt64 = 17
        let noise = (0..<config.frameSize).map { _ -> Float in
            rng = rng &* 6364136223846793005 &+ 1
            return Float(Double(rng >> 32)/Double(UInt32.max)*2-1)*0.009
        }
        let fixtures = [[Float](repeating:0,count:config.frameSize),noise,tone(50,0.008),tone(60,0.008)]
        for mode in VoicingExperiment.allCases {
            for samples in fixtures {
                let e = ExperimentalVoicing(sampleRate:rate,config:config,mode:mode)
                for i in 0..<30 {
                    XCTAssertNil(e.analyze(samples,time:Double(i)*1024/rate).rawFrequency, "\(mode) control")
                }
            }
        }
    }
    func testReferencePlaybackIsNotDistinguishableFromPeriodicVoice() {
        // Known generated reference, not singer. A microphone-only estimator
        // cannot establish source identity; document the negative control failure.
        for mode in VoicingExperiment.allCases {
            let e = ExperimentalVoicing(sampleRate:rate,config:config,mode:mode)
            XCTAssertNotNil(e.analyze(tone(275,0.08),time:0).rawFrequency)
        }
    }
    func testAllSignedOctaveMultiplesAndNonOctaveErrors() {
        for offset in [-3,-2,-1,1,2,3] {
            let reference = offset < 0 ? 880.0 : 110.0
            let detected = reference*pow(2,Double(offset))
            XCTAssertEqual(DevelopmentOctaveError.offset(detected:detected,reference:reference),offset)
        }
        XCTAssertNil(DevelopmentOctaveError.offset(detected:220,reference:220))
        XCTAssertNil(DevelopmentOctaveError.offset(detected:330,reference:220))
        XCTAssertNil(DevelopmentOctaveError.offset(detected:0,reference:220))
    }
    func testTwoVersusThreeTimingTransitionsWithoutPolicyChange() {
        let extractor = FocusEvidenceExtractor()
        for labels in [["Sa","Re"],["Sa","Re","Ga"],["Sa","Re","Ga","Ma"]] {
            let timeline = PracticeTimeline(targets:Alankaar(name:"comparison",labels:labels).targets(sa:220,tuning:.justShuddha),bpm:60)
            func observations(shift: Double) -> [PracticeObservation] {
                (0..<Int(timeline.duration*100)).map { i in
                    let t = (Double(i)+0.5)/100
                    let hz = timeline.note(at:t-shift)?.target.frequency
                    return PracticeObservation(time:t,frequency:hz,confidence:hz == nil ? 0 : 0.99)
                }
            }
            let shifted = observations(shift:0.18)
            let two = extractor.hasConsistentTimingShift(shifted,timeline:timeline,minimumTransitions:2)
            let three = extractor.hasConsistentTimingShift(shifted,timeline:timeline,minimumTransitions:3)
            XCTAssertEqual(two,labels.count >= 3)
            XCTAssertEqual(three,labels.count >= 4)
            XCTAssertEqual(extractor.hasConsistentTimingShift(shifted,timeline:timeline),two)
            XCTAssertFalse(extractor.hasConsistentTimingShift(observations(shift:0),timeline:timeline,minimumTransitions:2))
        }
    }
}
