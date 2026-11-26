import Foundation
import XCTest
@testable import SwarSaathiCore

final class FocusResearchTests: XCTestCase {
    private let sa = 220.0
    private func key(_ v: SwarVariant, _ o: Int = 0) -> SwarKey { SwarKey(variant: v, octave: o) }
    private struct ReportFixture: Encodable {
        struct Route: Encodable { let inputTypes = ["MicrophoneBuiltIn"]; let sampleRate = 48000.0; let channels = 1 }
        let schemaVersion = 3
        let createdUTC = "2026-11-25T08:00:00Z"
        let source = "AVAudioEngine microphone raw YIN observations"
        let saHz = 220.0
        let timeline: PracticeTimeline
        let observations: [PracticeObservation]
        let thresholds = AccuracyThresholds()
        let route = Route()
        let capture: PitchEngineDiagnostics
        let incomplete: Bool
        let reason: String? = nil
    }
    private func report(labels: [String], shift: Double = 0, wrongRe: Bool = false,
                        silence: Bool = false, octave: Bool = false, damaged: Bool = false,
                        incomplete: Bool = false, neighbor: Bool = false) throws -> Data {
        let timeline = PracticeTimeline(targets:Alankaar(name:"fixture",labels:labels).targets(sa:sa,tuning:.justShuddha),bpm:60)
        let observations = (0..<Int(timeline.duration*25)).map { i -> PracticeObservation in
            let t = (Double(i)+0.5)/25
            let hz = timeline.note(at:t-shift)?.target.frequency
            let isRe = timeline.note(at:t-shift)?.target.label == "Re"
            var result = hz
            if isRe {
                if silence { result = nil }
                else if octave { result = hz.map { $0*2 } }
                else if neighbor { result = sa }
                else if wrongRe { result = hz.map { $0*pow(2,70.0/1200) } }
            }
            return PracticeObservation(time:t,frequency:result,confidence:result == nil ? 0 : 0.99)
        }
        let capture = PitchEngineDiagnostics(generation:1,detectorConfig:PitchConfig(),sampleRate:48000,frameSize:2048,
            hopSize:1024,processedFrames:observations.count,droppedPackets:damaged ? 1 : 0,droppedSamples:0,
            mailboxHighWaterMark:1,discontinuities:0,deliveryDroppedFrames:0,timestampFallbackPackets:0,
            processingMedianMs:0.1,processingP95Ms:0.2,workerStopped:true)
        return try JSONEncoder().encode(ReportFixture(timeline:timeline,observations:observations,capture:capture,incomplete:incomplete))
    }
    private func provenance(_ id: String, verified: Bool = true) -> FocusReportProvenance {
        FocusReportProvenance(sessionID:id,calibrationID:"fixture-calibration",sourceRevision:"452056910f22561862ccada6f3e9588061bc0bee",verifiedRecordOnly:verified)
    }
    func testSchema3ExtractorUsesRawObservationsAndRejectsDamage() throws {
        let extractor = FocusEvidenceExtractor()
        let data = try report(labels:["Sa","Re","Ga","Re","Sa"],wrongRe:true)
        let history = try extractor.extract(data:data,provenance:provenance("s1"))
        let re = history.attempts.filter { $0.key == key(.shuddhaRe) }
        XCTAssertEqual(re.count,2)
        XCTAssertTrue(re.allSatisfy { $0.attribution == .pitchEvidence && $0.matchingCells == 0 })
        XCTAssertThrowsError(try extractor.extract(data:report(labels:["Sa","Re"],damaged:true),provenance:provenance("s2")))
        XCTAssertThrowsError(try extractor.extract(data:report(labels:["Sa","Re"],incomplete:true),provenance:provenance("s2")))
        XCTAssertThrowsError(try extractor.extract(data:data,provenance:provenance("s2",verified:false)))
    }
    func testMissingNeighborAndOctaveAreNotWeaknessEvidence() throws {
        let extractor = FocusEvidenceExtractor()
        for (data,attribution) in [(try report(labels:["Sa","Re","Sa"],silence:true),FocusAttribution.missingOrUnclear),
                                   (try report(labels:["Sa","Re","Sa"],octave:true),.octaveAmbiguous),
                                   (try report(labels:["Sa","Re","Sa"],neighbor:true),.timingAmbiguous)] {
            let result = try extractor.extract(data:data,provenance:provenance("s"))
            XCTAssertEqual(result.attempts[1].attribution,attribution)
        }
    }
    func testConsistentTimingShiftIsAmbiguousWithoutChangingExistingScore() throws {
        let data = try report(labels:["Sa","Re","Ga","Ma","Pa"],shift:0.18)
        let report = try JSONDecoder().decode(FocusPracticeReport.self,from:data)
        let before = report.timeline.score(observations:report.observations,thresholds:report.thresholds)
        let history = try FocusEvidenceExtractor().extract(data:data,provenance:provenance("s"))
        XCTAssertTrue(history.attempts.contains { $0.attribution == .timingAmbiguous })
        let after = report.timeline.score(observations:report.observations,thresholds:report.thresholds)
        XCTAssertEqual(before.summary.practiceMatchPercent,after.summary.practiceMatchPercent)
    }
    func testRecommendationFromExtractedHistoryAndFixtureGate() throws {
        let extractor = FocusEvidenceExtractor(), engine = FocusRecommendationEngine()
        let sequences = [["Sa","Re","Sa","Re","Sa","Re","Sa","Re","Sa"],
                         ["Sa","Re","Ga","Re","Sa","Re","Ga","Re","Sa"]]
        let sessions = try (0..<3).map { i in
            try extractor.extract(data:report(labels:sequences[i%2],wrongRe:true),provenance:provenance("s\(i)"))
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-11-26T08:00:00Z"))
        let evidence = engine.assess(history:sessions,context:sessions[0].context,now:now)
        let re = try XCTUnwrap(evidence.first { $0.key == key(.shuddhaRe) })
        XCTAssertEqual(re.count,12); XCTAssertEqual(re.sessions,3); XCTAssertEqual(re.patterns,2); XCTAssertEqual(re.percent,0)
        XCTAssertTrue(engine.assess(history:Array(sessions.prefix(2)),context:sessions[0].context,now:now).isEmpty)
        XCTAssertTrue(engine.assess(history:sessions+[sessions[0]],context:sessions[0].context,now:now).isEmpty)
        let pattern = FocusPattern(id:"test-only",version:1,review:.testFixture,tuningID:TuningProfile.baseline.id,
            notes:[key(.sa),key(.shuddhaRe),key(.sa),key(.shuddhaRe),key(.sa)],minBPM:40,maxBPM:80,difficulty:1)
        if case .noSafePattern = engine.recommend(evidence:evidence,library:[pattern],sa:sa,lower:200,upper:300,bpm:60,maxDifficulty:1) {} else { XCTFail("fixture leaked into normal recommendation") }
        if case .selected(let chosen, let covered) = engine.recommend(evidence:evidence,library:[pattern],sa:sa,lower:200,upper:300,bpm:60,maxDifficulty:1,allowTestFixtures:true) {
            XCTAssertEqual(chosen.id,"test-only"); XCTAssertEqual(covered,[key(.shuddhaRe)])
        } else { XCTFail("expected fixture selection") }
        if case .noSafePattern = engine.recommend(evidence:evidence,library:[pattern],sa:sa,lower:200,upper:230,bpm:60,maxDifficulty:1,allowTestFixtures:true) {} else { XCTFail("range ignored") }
    }
}
