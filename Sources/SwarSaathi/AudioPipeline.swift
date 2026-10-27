import Foundation

struct AudioMailboxMetrics: Equatable {
    var acceptedPackets = 0
    var consumedPackets = 0
    var droppedPackets = 0
    var droppedSamples = 0
    var overflowPackets = 0
    var oversizePackets = 0
    var invalidPackets = 0
    var stalePackets = 0
    var pendingPackets = 0
    var leasedPackets = 0
    var highWaterMark = 0
    var discardedOnReset = 0
}

/// Preallocated, bounded handoff between the input tap and one or more workers.
///
/// No DSP, per-packet arrays or dispatch closures occur in enqueue. It copies at
/// most maxSamples Float values under a short NSLock section. This is a bounded
/// soft-real-time design, NOT a lock-free or hard-real-time guarantee. A producer
/// can wait briefly for metadata operations on another thread. Consumers never
/// hold the lock during their analysis callback.
///
/// The borrowed buffer is valid ONLY inside consumeNext's nonescaping callback.
/// A leased slot remains protected even if reset is called during that callback;
/// normal engine shutdown should still stop/join its worker before reset.
final class BoundedAudioMailbox: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var count = 0
        var firstSampleTime = 0.0
        var sampleRate = 0.0
        var generation: UInt64 = 0
        var occupied = false
        var leased = false

        init(maxSamples: Int) {
            samples = .allocate(capacity: maxSamples)
            capacity = maxSamples
            samples.initialize(repeating: 0, count: maxSamples)
        }
        private let capacity: Int
        deinit { samples.deinitialize(count: capacity); samples.deallocate() }
    }

    let capacity: Int
    let maxSamples: Int
    private let lock = NSLock()
    private let slots: [Slot]
    private var pending: [Int]
    private var head = 0
    private var tail = 0
    private var pendingCount = 0
    private var leasedCount = 0
    private var nextSlot = 0
    private var generation: UInt64 = 0
    private var counters = AudioMailboxMetrics()

    init(capacity: Int = 8, maxSamples: Int = 8192) {
        precondition(capacity > 0 && maxSamples > 0, "Audio handoff dimensions must be positive")
        self.capacity = capacity
        self.maxSamples = maxSamples
        self.slots = (0..<capacity).map { _ in Slot(maxSamples: maxSamples) }
        self.pending = [Int](repeating: 0, count: capacity)
    }

    var metrics: AudioMailboxMetrics {
        lock.lock(); defer { lock.unlock() }
        var result = counters
        result.pendingPackets = pendingCount
        result.leasedPackets = leasedCount
        return result
    }

    func reset(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let discarded = pendingCount
        for slot in slots where !slot.leased { slot.occupied = false }
        head = 0; tail = 0; pendingCount = 0; nextSlot = 0
        self.generation = generation
        counters = AudioMailboxMetrics()
        counters.highWaterMark = leasedCount
        counters.discardedOnReset = discarded
    }

    @discardableResult
    func enqueue(_ samples: UnsafePointer<Float>, count: Int, time: Double,
                 sampleRate: Double, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, time.isFinite, sampleRate.isFinite, sampleRate > 0 else {
            counters.invalidPackets += 1
            recordDrop(samples: count)
            return false
        }
        guard count <= maxSamples else {
            counters.oversizePackets += 1
            recordDrop(samples: count)
            return false
        }
        guard generation == self.generation else {
            counters.stalePackets += 1
            recordDrop(samples: count)
            return false
        }

        // Scan at most capacity entries. Leased slots are never overwritten.
        var free: Int?
        for offset in 0..<capacity {
            let index = (nextSlot + offset) % capacity
            if !slots[index].occupied { free = index; break }
        }
        guard let index = free else {
            counters.overflowPackets += 1
            recordDrop(samples: count)
            return false
        }
        let slot = slots[index]
        slot.samples.update(from: samples, count: count)
        slot.count = count
        slot.firstSampleTime = time
        slot.sampleRate = sampleRate
        slot.generation = generation
        slot.occupied = true
        pending[tail] = index
        tail = (tail + 1) % capacity
        pendingCount += 1
        nextSlot = (index + 1) % capacity
        counters.acceptedPackets += 1
        counters.highWaterMark = max(counters.highWaterMark, pendingCount + leasedCount)
        return true
    }

    @discardableResult
    func consumeNext(_ body: (UnsafeBufferPointer<Float>, Double, Double, UInt64) -> Void) -> Bool {
        lock.lock()
        guard pendingCount > 0 else { lock.unlock(); return false }
        let slot = slots[pending[head]]
        head = (head + 1) % capacity
        pendingCount -= 1
        leasedCount += 1
        slot.leased = true
        let count = slot.count
        let time = slot.firstSampleTime
        let rate = slot.sampleRate
        let packetGeneration = slot.generation
        counters.consumedPackets += 1
        lock.unlock()

        body(UnsafeBufferPointer(start: slot.samples, count: count), time, rate, packetGeneration)

        lock.lock()
        slot.leased = false
        slot.occupied = false
        leasedCount -= 1
        lock.unlock()
        return true
    }

    /// Called only while the metadata lock is held.
    private func recordDrop(samples: Int) {
        counters.droppedPackets += 1
        counters.droppedSamples += max(0, samples)
    }
}

struct FrameBufferMetrics: Equatable {
    var acceptedFrames = 0
    var droppedFrames = 0
    var pendingFrames = 0
    var highWaterMark = 0
    var discardedOnReset = 0
}

/// Bounded worker-to-main handoff; the main timer drains batches without one
/// unbounded DispatchQueue.main closure per audio observation. Element should
/// carry an engine generation; the main consumer checks it before delivery.
final class BoundedFrameBuffer<Element>: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var counters = FrameBufferMetrics()

    init(capacity: Int = 256) {
        precondition(capacity > 0, "Frame handoff capacity must be positive")
        self.capacity = capacity
        self.storage = [Element?](repeating: nil, count: capacity)
    }

    @discardableResult
    func enqueue(_ element: Element) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < capacity else { counters.droppedFrames += 1; return false }
        storage[tail] = element
        tail = (tail + 1) % capacity
        count += 1
        counters.acceptedFrames += 1
        counters.highWaterMark = max(counters.highWaterMark, count)
        return true
    }

    func drain() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        var result: [Element] = []
        result.reserveCapacity(count)
        while count > 0 {
            if let element = storage[head] { result.append(element) }
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        return result
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        let discarded = count
        for index in storage.indices { storage[index] = nil }
        head = 0; tail = 0; count = 0
        counters = FrameBufferMetrics()
        counters.discardedOnReset = discarded
    }

    var metrics: FrameBufferMetrics {
        lock.lock(); defer { lock.unlock() }
        var result = counters
        result.pendingFrames = count
        return result
    }
}
