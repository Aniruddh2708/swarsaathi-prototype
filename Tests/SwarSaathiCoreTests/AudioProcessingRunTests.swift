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

    func testContinuousPacketsSurviveTimestampJitter() {
        let run = AudioProcessingRun(generation: 9, sampleRate: rate)
        for i in 0..<47 {
            let time = 100 + Double(i * 1024) / rate + (i.isMultiple(of: 2) ? 0.0001 : -0.0001)
            XCTAssertTrue(put(packet(220, offset: i * 1024), into: run, at: time))
            run.processOne()
        }
        let frames = run.delivery.drain()
        print("JITTER frames=\(frames.count) resets=\(run.diagnostics.discontinuities)")
        XCTAssertEqual(frames.count, 46)
        XCTAssertEqual(frames.compactMap(\.rawFrequency).count, 46)
        XCTAssertEqual(run.diagnostics.discontinuities, 0)
    }

    func testLowerRateRoutesCanFillEveryScoringCell() {
        let timeline = PracticeTimeline(targets: [NoteTarget(index: 0, label: "Sa", ratio: 1, frequency: 220)], bpm: 60)
        for sampleRate in [8000.0, 16000, 24000, 44100, 48000, 96000] {
            let run = AudioProcessingRun(generation: 1, sampleRate: sampleRate)
            var observations: [PracticeObservation] = []
            // Include roll-in/out as on the device. Only centers inside the beat are scored.
            for offset in stride(from: 0, to: Int(sampleRate * 1.4), by: 512) {
                let data: [Float] = (0..<512).map { Float(0.25 * sin(2 * .pi * 220 * Double(offset + $0) / sampleRate)) }
                XCTAssertTrue(put(data, into: run, at: Double(offset) / sampleRate))
                run.processOne()
                observations += run.delivery.drain().map { PracticeObservation(time: $0.time - 0.2, frequency: $0.rawFrequency, confidence: $0.confidence) }
            }
            let result = timeline.score(observations: observations)
            print("ROUTE rate=\(sampleRate) strict=\(result.summary.accuracyPercent)")
            XCTAssertEqual(result.summary.accuracyPercent, 100, "Synthetic continuous pitch, rate \(sampleRate)")
        }
    }

    func testSampleClockSeparatesOneMissingSampleAndIgnoresArrivalJitter() {
        let run = AudioProcessingRun(generation: 1, sampleRate: rate)
        func submit(position: Int64, arrival: Double) {
            packet(220).withUnsafeBufferPointer { data in
                XCTAssertTrue(run.enqueue(data.baseAddress!, count: data.count, time: arrival,
                                          usedTimestampFallback: true, samplePosition: position))
            }
            run.processOne()
        }
        submit(position: 1000, arrival: 5)
        submit(position: 2025, arrival: 5.10)
        XCTAssertTrue(run.delivery.drain().isEmpty)
        submit(position: 3049, arrival: 5.20)
        let frames = run.delivery.drain()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.startsNewSegment, true)
        XCTAssertEqual(frames.first?.time ?? 0, 5 + 2049 / rate, accuracy: 1e-9)
        XCTAssertEqual(run.diagnostics.discontinuities, 1)
        XCTAssertEqual(run.diagnostics.timestampFallbackPackets, 3)
    }

    func testFinishingDrainsAllAdmittedPacketsAndClosesAdmission() {
        let run = AudioProcessingRun(generation: 7, sampleRate: rate)
        for index in 0..<8 {
            XCTAssertTrue(put(packet(220, offset: 1024 * index), into: run, at: Double(1024 * index) / rate))
        }
        XCTAssertTrue(run.hasAudioForFinalWindow(endingAt: 0.1))
        XCTAssertFalse(run.hasAudioForFinalWindow(endingAt: 0.2))
        run.start()
        XCTAssertTrue(run.stop(drainPending: true))
        let frames = run.delivery.drain()
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames.last?.time ?? 0, 7168 / rate, accuracy: 1e-8)
        XCTAssertFalse(put(packet(nil), into: run, at: 1))
        XCTAssertEqual(run.diagnostics.droppedSamples, 0)
        XCTAssertTrue(run.diagnostics.workerStopped)
        XCTAssertFalse(run.diagnostics.finalDrainTimedOut)
    }

    func testLossAndUnsupportedFormatAreReportedSeparatelyFromSilence() {
        let run = AudioProcessingRun(generation: 1, sampleRate: rate)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(put(packet(nil, count: 2048), into: run, at: now))
        run.processOne()
        let frames = run.delivery.drain()
        run.recordDelivery(frames, now: frames[0].time + 0.035)
        XCTAssertEqual(run.diagnostics.deliveryAgeP95Ms ?? 0, 35, accuracy: 0.001)
        XCTAssertNil(run.captureFault(now: now))
        XCTAssertNotNil(run.captureFault(now: now + 3))
        XCTAssertFalse(run.diagnostics.hasCaptureLoss)
        run.rejectFormat()
        XCTAssertTrue(run.diagnostics.hasCaptureLoss)
        XCTAssertEqual(run.diagnostics.invalidFormatPackets, 1)
        XCTAssertNotNil(run.captureFault(now: now))
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
