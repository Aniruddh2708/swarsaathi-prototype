import XCTest
@testable import SwarSaathiCore

final class AudioPipelineTests: XCTestCase {
    private final class ConcurrentState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var received: [Int] = []

        func finishProducer() { lock.lock(); done = true; lock.unlock() }
        var producerFinished: Bool {
            lock.lock(); defer { lock.unlock() }; return done
        }
        func append(_ value: Int) { lock.lock(); received.append(value); lock.unlock() }
        var values: [Int] {
            lock.lock(); defer { lock.unlock() }; return received
        }
    }

    @discardableResult
    private func enqueue(_ values: [Float], to mailbox: BoundedAudioMailbox,
                         time: Double = 1, rate: Double = 44100, generation: UInt64 = 0) -> Bool {
        values.withUnsafeBufferPointer {
            mailbox.enqueue($0.baseAddress!, count: $0.count, time: time,
                            sampleRate: rate, generation: generation)
        }
    }

    func testCopiesSamplesAndMetadataWithoutRetainingProducerStorage() {
        let box = BoundedAudioMailbox(capacity: 2, maxSamples: 4)
        var values: [Float] = [1, 2, 3, 4]
        XCTAssertTrue(enqueue(values, to: box, time: 42.25, rate: 48000))
        values[0] = 99
        XCTAssertTrue(box.consumeNext { samples, time, rate, generation in
            XCTAssertEqual(Array(samples), [1, 2, 3, 4])
            XCTAssertEqual(time, 42.25)
            XCTAssertEqual(rate, 48000)
            XCTAssertEqual(generation, 0)
        })
        XCTAssertFalse(box.consumeNext { _, _, _, _ in XCTFail("Empty mailbox delivered data") })
        XCTAssertEqual(box.metrics.acceptedPackets, 1)
        XCTAssertEqual(box.metrics.consumedPackets, 1)
        XCTAssertEqual(box.metrics.pendingPackets, 0)
        XCTAssertEqual(box.metrics.leasedPackets, 0)
    }

    func testCapacityAndFIFOWithWraparound() {
        let box = BoundedAudioMailbox(capacity: 2, maxSamples: 2)
        XCTAssertTrue(enqueue([1, 1], to: box))
        XCTAssertTrue(enqueue([2, 2], to: box))
        XCTAssertFalse(enqueue([3, 3], to: box))
        XCTAssertEqual(box.metrics.droppedPackets, 1)
        XCTAssertEqual(box.metrics.droppedSamples, 2)
        XCTAssertEqual(box.metrics.overflowPackets, 1)
        XCTAssertTrue(box.consumeNext { samples, _, _, _ in XCTAssertEqual(samples[0], 1) })
        XCTAssertTrue(enqueue([4, 4], to: box))
        XCTAssertTrue(box.consumeNext { samples, _, _, _ in XCTAssertEqual(samples[0], 2) })
        XCTAssertTrue(box.consumeNext { samples, _, _, _ in XCTAssertEqual(samples[0], 4) })
        XCTAssertEqual(box.metrics.highWaterMark, 2)
    }

    func testRejectsOversizeInvalidAndStalePacketsWithExactCounters() {
        let box = BoundedAudioMailbox(capacity: 2, maxSamples: 2)
        box.reset(generation: 7)
        XCTAssertFalse(enqueue([1, 2, 3], to: box, generation: 7))
        XCTAssertFalse(enqueue([1], to: box, time: .nan, generation: 7))
        XCTAssertFalse(enqueue([1], to: box, rate: 0, generation: 7))
        XCTAssertFalse(enqueue([1, 2], to: box, generation: 6))
        let m = box.metrics
        XCTAssertEqual(m.oversizePackets, 1)
        XCTAssertEqual(m.invalidPackets, 2)
        XCTAssertEqual(m.stalePackets, 1)
        XCTAssertEqual(m.droppedPackets, 4)
        XCTAssertEqual(m.droppedSamples, 7)
        XCTAssertEqual(m.acceptedPackets, 0)
    }

    func testLeasedSlotIsNotOverwrittenAndBodyRunsOutsideLock() {
        let box = BoundedAudioMailbox(capacity: 1, maxSamples: 2)
        XCTAssertTrue(enqueue([11, 12], to: box))
        XCTAssertTrue(box.consumeNext { samples, _, _, _ in
            // Reentrant metadata and enqueue would deadlock if DSP held lock.
            XCTAssertEqual(box.metrics.leasedPackets, 1)
            XCTAssertFalse(enqueue([99, 99], to: box))
            XCTAssertEqual(Array(samples), [11, 12])
        })
        XCTAssertTrue(enqueue([21, 22], to: box))
        XCTAssertEqual(box.metrics.overflowPackets, 1)
    }

    func testResetInvalidatesPendingGenerationButProtectsBorrowedMemory() {
        let box = BoundedAudioMailbox(capacity: 2, maxSamples: 2)
        XCTAssertTrue(enqueue([1, 2], to: box))
        XCTAssertTrue(enqueue([3, 4], to: box))
        XCTAssertTrue(box.consumeNext { old, _, _, generation in
            XCTAssertEqual(generation, 0)
            box.reset(generation: 9)
            XCTAssertEqual(box.metrics.discardedOnReset, 1)
            XCTAssertTrue(enqueue([5, 6], to: box, generation: 9))
            XCTAssertFalse(enqueue([7, 8], to: box, generation: 9))
            XCTAssertEqual(Array(old), [1, 2])
        })
        XCTAssertTrue(box.consumeNext { samples, _, _, generation in
            XCTAssertEqual(generation, 9)
            XCTAssertEqual(Array(samples), [5, 6])
        })
        XCTAssertEqual(box.metrics.leasedPackets, 0)
        XCTAssertFalse(box.consumeNext { _, _, _, _ in XCTFail("Reset packet escaped") })
    }

    func testConcurrentProducerConsumerKeepsPacketsIntactAndAccountsForLoss() {
        let box = BoundedAudioMailbox(capacity: 8, maxSamples: 32)
        let group = DispatchGroup()
        let state = ConcurrentState()
        group.enter()
        DispatchQueue.global().async {
            for index in 0..<2000 {
                let values = [Float](repeating: Float(index), count: 32)
                values.withUnsafeBufferPointer {
                    _ = box.enqueue($0.baseAddress!, count: 32, time: Double(index), sampleRate: 48000, generation: 0)
                }
            }
            state.finishProducer()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            while true {
                let consumed = box.consumeNext { samples, time, _, _ in
                    let value = Float(time)
                    XCTAssertTrue(samples.allSatisfy { $0 == value })
                    state.append(Int(time))
                }
                let finished = state.producerFinished
                if finished && !consumed && box.metrics.pendingPackets == 0 { break }
                if !consumed { Thread.sleep(forTimeInterval: 0.0001) }
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let m = box.metrics
        XCTAssertEqual(m.acceptedPackets + m.droppedPackets, 2000)
        XCTAssertEqual(m.consumedPackets, m.acceptedPackets)
        XCTAssertLessThanOrEqual(m.highWaterMark, 8)
        let ordered = state.values
        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertEqual(Set(ordered).count, ordered.count)
    }

    func testFrameDeliveryBufferBoundsBatchesAndReset() {
        let frames = BoundedFrameBuffer<Int>(capacity: 2)
        XCTAssertTrue(frames.enqueue(10))
        XCTAssertTrue(frames.enqueue(20))
        XCTAssertFalse(frames.enqueue(30))
        XCTAssertEqual(frames.drain(), [10, 20])
        XCTAssertEqual(frames.drain(), [])
        XCTAssertEqual(frames.metrics.droppedFrames, 1)
        XCTAssertTrue(frames.enqueue(40))
        frames.reset()
        XCTAssertEqual(frames.metrics.discardedOnReset, 1)
        XCTAssertEqual(frames.drain(), [])
        XCTAssertTrue(frames.enqueue(50))
        XCTAssertEqual(frames.drain(), [50])
    }
}
