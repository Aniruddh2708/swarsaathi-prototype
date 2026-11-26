import Foundation
import XCTest
@testable import SwarSaathiCore

final class PlaybackResearchTests: XCTestCase {
    func testCalibratedCancellationPreservesSameFrequencyVoice() throws {
        var state:UInt64=3
        let r=(0..<512).map { _ -> Float in
            state=state &* 6364136223846793005 &+ 1
            return Float(Double(state>>32)/Double(UInt32.max)*2-1)*0.1
        }
        let m=(0..<r.count).map{$0>=7 ? r[$0-7]*0.5:0}
        let model=try XCTUnwrap(ReferenceEchoModel.fit(reference:r,microphone:m,maxDelay:20))
        XCTAssertEqual(model.delay,7); XCTAssertEqual(model.gain,0.5,accuracy:1e-8)
        let ref=(0..<512).map{Float(0.1*sin(Double($0)*0.1))}
        let voice=ref.map{$0*0.3}
        let mixed=(0..<ref.count).map{voice[$0]+($0>=7 ? ref[$0-7]*0.5:0)}
        let out=try XCTUnwrap(model.subtract(reference:ref,microphone:mixed))
        for i in voice.indices { XCTAssertEqual(out[i],voice[i],accuracy:1e-7) }
    }
    func testInvalidCalibrationAbstains() {
        let zero=[Float](repeating:0,count:512)
        XCTAssertNil(ReferenceEchoModel.fit(reference:zero,microphone:zero,maxDelay:20))
        XCTAssertNil(ReferenceEchoModel.fit(reference:zero,microphone:[],maxDelay:20))
    }
    func testChangedEchoPathLeavesResidual() throws {
        let r=(0..<512).map{Float(sin(Double($0)*0.1))}
        let model=ReferenceEchoModel(delay:7,gain:0.5,calibrationCorrelation:1)
        let m=(0..<r.count).map{$0>=7 ? r[$0-7]*0.7:0}
        let out=try XCTUnwrap(model.subtract(reference:r,microphone:m))
        XCTAssertGreaterThan(out.map{abs($0)}.max() ?? 0,0.1)
    }
    func testAttributionGeometryAndPeriodicity() throws {
        XCTAssertEqual(AttributionResearch.nearestWindow(time:1024.0/44100,rate:44100,frame:2048,hop:1024),0)
        XCTAssertEqual(try XCTUnwrap(AttributionResearch.boundaryDistance(time:0.12,boundaries:[0.1,0.4])),0.02,accuracy:1e-10)
        XCTAssertNil(AttributionResearch.boundaryDistance(time:0,boundaries:[]))
        let wave=(0..<512).map{Float(sin(2*Double.pi*Double($0)/32))}
        XCTAssertEqual(try XCTUnwrap(AttributionResearch.correlation(samples:wave,start:0,count:512,lag:32)),1,accuracy:1e-6)
        XCTAssertNil(AttributionResearch.correlation(samples:[Float](repeating:0,count:512),start:0,count:512,lag:32))
    }
}
