import XCTest
@testable import SwarSaathiCore

final class AudioProcessingRunTests: XCTestCase {
    private let rate = 48000.0
    private func packet(_ hz: Double?, offset: Int = 0, count: Int = 1024) -> [Float] {
        (0..<count).map { i in
            hz.map { Float(0.25 * sin(2 * .pi * $0 * Double(i + offset) / rate)) } ?? 0
        }
    }
    private func put(_ samples: [Float], into run: AudioProcessingRun, at time: Double) -> Bool {
        samples.withUnsafeBufferPointer { run.enqueue($0.baseAddress!, count: $0.count, time: time) }
    }

    func testActualWorkerPipelineUsesAudioCenterTimeAndRawPitch() throws {
        let run = AudioProcessingRun(generation: 1, sampleRate: rate)
        for i in 0..<4 {
            XCTAssertTrue(put(packet(220, offset: i * 1024), into: run, at: 10 + Double(i * 1024) / rate))
            XCTAssertTrue(run.processOne())
        }
        let frames = run.delivery.drain()
        XCTAssertEqual(frames.count, 3)
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.time, 10 + Double((i + 1) * 1024) / rate, accuracy: 0.00000001)
            XCTAssertLessThan(abs(PitchMath.cents(detected: try XCTUnwrap(frame.rawFrequency), expected: 220)), 10)
        }
        XCTAssertEqual(run.diagnostics.processedFrames, 3)
        XCTAssertTrue(run.stop())
    }

    func testSilenceAndOctaveAreNeverCopiedFromAnExpectedTarget() throws {
        let run = AudioProcessingRun(generation: 2, sampleRate: rate)
        var offset = 0
        for hz in [220.0, 440.0, 0.0] {
            let samples = packet(hz == 0 ? nil : hz, offset: offset, count: 4096)
            XCTAssertTrue(put(samples, into: run, at: Double(offset) / rate))
            run.processOne()
            offset += 4096
        }
        let frames = run.delivery.drain()
        let raw = frames.compactMap(\.rawFrequency)
        XCTAssertTrue(raw.contains { abs(PitchMath.cents(detected: $0, expected: 440)) < 10 })
        XCTAssertNil(frames.last?.rawFrequency)
        XCTAssertNil(frames.last?.frequency)
        run.stop()
    }

    func testDroppedPacketBreaksWindowRatherThanSplicingAudio() throws {
        let run = AudioProcessingRun(generation: 3, sampleRate: rate, capacity: 1)
        XCTAssertTrue(put(packet(220), into: run, at: 0))
        XCTAssertFalse(put(packet(220, offset: 1024), into: run, at: 1024 / rate))
        run.processOne()
        XCTAssertTrue(put(packet(440, offset: 2048), into: run, at: 2048 / rate))
        run.processOne()
        XCTAssertTrue(run.delivery.drain().isEmpty, "Two noncontiguous half windows cannot form a pitch frame")
        XCTAssertEqual(run.diagnostics.discontinuities, 1)
        XCTAssertEqual(run.diagnostics.droppedSamples, 1024)
        XCTAssertTrue(put(packet(440, offset: 3072), into: run, at: 3072 / rate))
        run.processOne()
        let frame = try XCTUnwrap(run.delivery.drain().first)
        XCTAssertEqual(frame.time, 3072 / rate, accuracy: 0.0000001)
        XCTAssertLessThan(abs(PitchMath.cents(detected: try XCTUnwrap(frame.rawFrequency), expected: 440)), 10)
        run.stop()
    }

    func testRealWorkerStopAndNewGenerationCannotShareOldFrames() throws {
        let old = AudioProcessingRun(generation: 4, sampleRate: rate)
        old.start()
        XCTAssertTrue(put(packet(220, count: 4096), into: old, at: 10))
        let deadline = Date().addingTimeInterval(2)
        while old.diagnostics.processedFrames == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertGreaterThan(old.diagnostics.processedFrames, 0)
        XCTAssertTrue(old.stop())
        XCTAssertTrue(old.diagnostics.workerStopped)
        XCTAssertFalse(put(packet(220), into: old, at: 11))
        let new = AudioProcessingRun(generation: 5, sampleRate: rate)
        new.start()
        XCTAssertTrue(put(packet(nil, count: 4096), into: new, at: 20))
        let nextDeadline = Date().addingTimeInterval(2)
        while new.diagnostics.processedFrames < 3 && Date() < nextDeadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(new.stop())
        let frames = new.delivery.drain()
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.time >= 20 && $0.rawFrequency == nil && $0.frequency == nil })
        XCTAssertEqual(new.diagnostics.generation, 5)
    }
}
