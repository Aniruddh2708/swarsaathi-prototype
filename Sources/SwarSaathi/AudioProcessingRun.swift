import Foundation
import Dispatch

/// Measured processing diagnostics, not a claim about microphone-to-screen delay.
struct PitchEngineDiagnostics: Codable {
    let generation: UInt64
    let detectorConfig: PitchConfig
    let sampleRate: Double
    let frameSize: Int
    let hopSize: Int
    let processedFrames: Int
    let droppedPackets: Int
    let droppedSamples: Int
    let mailboxHighWaterMark: Int
    let discontinuities: Int
    let deliveryDroppedFrames: Int
    let timestampFallbackPackets: Int
    let processingMedianMs: Double
    let processingP95Ms: Double
    let workerStopped: Bool
    var invalidFormatPackets: Int = 0
    var hostOnlyPackets: Int = 0
    var largestPacketSamples: Int = 0
    var uncertainTimingPackets: Int = 0
    var finalDrainTimedOut: Bool = false
    var deliveryAgeP95Ms: Double? = nil

    var hasCaptureLoss: Bool {
        droppedPackets > 0 || discontinuities > 0 || deliveryDroppedFrames > 0 ||
            invalidFormatPackets > 0 || finalDrainTimedOut
    }
}

/// One isolated capture generation. The tap only copies into the preallocated
/// mailbox and signals this worker; DSP and storage changes happen off the tap.
/// A stopped run is never reused, so old packets cannot enter a new recording.
final class AudioProcessingRun: @unchecked Sendable {
    let generation: UInt64
    let sampleRate: Double
    let config: PitchConfig
    let mailbox: BoundedAudioMailbox
    let delivery = BoundedFrameBuffer<PitchFrame>(capacity: 128)
    private let detector: YINPitchDetector
    private let signal = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var sealed = false
    private var stopping = false
    // Producer clock, protected by stateLock. Sample positions detect even a
    // one-sample gap. Host seconds align the first sample with the practice clock.
    private var nextTime: Double?
    private var nextPosition: Int64?
    private var awaitingHostAnchor = false
    private var previousPacketLost = false
    private var hostOnlyPackets = 0
    private var invalidFormatPackets = 0
    private var lastPacketArrival = ProcessInfo.processInfo.systemUptime
    private var largestPacketSamples = 0
    private var uncertainTimingPackets = 0
    private var drainTimedOut = false
    private var deliveryAges: [Double] = []
    private var deliveryAgeIndex = 0
    private var started = false
    private var ended = false
    private var processedFrames = 0
    private var discontinuities = 0
    private var timestampFallbackPackets = 0
    private var timings: [Double] = []

    // Worker-confined state. Never touched from the audio tap or the main queue.
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var expectedPacketTime: Double?
    private var markFrameGap = false
    private var lastAcceptedEnd: Double?
    private var smoother = PitchSmoother()

    init(generation: UInt64, sampleRate: Double, config requestedConfig: PitchConfig? = nil,
         capacity: Int = 8, maxSamples: Int = 8192) {
        let config = requestedConfig ?? PitchConfig.forCapture(sampleRate: sampleRate)
        self.generation = generation; self.sampleRate = sampleRate; self.config = config
        detector = YINPitchDetector(sampleRate: sampleRate, config: config)
        mailbox = BoundedAudioMailbox(capacity: capacity, maxSamples: maxSamples)
        mailbox.reset(generation: generation)
        pending.reserveCapacity(config.frameSize + maxSamples)
        timings.reserveCapacity(512)
        deliveryAges.reserveCapacity(512)
    }

    var configurationError: String? { detector.configurationError }

    /// Called once before installing the input tap.
    func start() {
        stateLock.lock()
        guard !started && !stopping else { stateLock.unlock(); return }
        started = true
        stateLock.unlock()
        let thread = Thread { [self] in
            while true {
                signal.wait()
                if isStopping { break }
                // One permit per accepted packet. No unbounded dispatch blocks.
                if !processOne() {
                    stateLock.lock(); let complete = sealed; stateLock.unlock()
                    if complete { break }
                }
            }
            stateLock.lock(); ended = true; stateLock.unlock()
            finished.signal()
        }
        thread.name = "SwarSaathi.YIN.\(generation)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Returns false on overflow/stop; dropped audio is counted, never fabricated.
    @discardableResult
    func enqueue(_ samples: UnsafePointer<Float>, count: Int, time: Double,
                 usedTimestampFallback: Bool = false, samplePosition: Int64? = nil) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !sealed else { return false }
        lastPacketArrival = ProcessInfo.processInfo.systemUptime
        if usedTimestampFallback { timestampFallbackPackets += 1 }
        if samplePosition == nil { hostOnlyPackets += 1 }
        largestPacketSamples = max(largestPacketSamples, count)
        let duration = Double(count) / sampleRate
        let positionDelta = samplePosition.flatMap { position in nextPosition.map { Double(position) - Double($0) } }
        var start = time
        var gap = previousPacketLost
        if let expected = nextTime, time.isFinite {
            let predicted = expected + (positionDelta ?? 0) / sampleRate
            // With a hardware position, callback-arrival jitter cannot break
            // contiguous audio. Without one, allow only small host jitter.
            let tolerance = min(positionDelta == nil ? 0.002 : 0.010, duration / 4)
            let trustPosition = usedTimestampFallback && positionDelta != nil
            if trustPosition || abs(time - predicted) <= tolerance {
                start = predicted
            } else {
                gap = true
            }
            if let delta = positionDelta, delta != 0 {
                gap = true
                // On a hardware counter restart, resume at this packet's host anchor.
                if delta < 0 { start = time }
            }
            if awaitingHostAnchor && !usedTimestampFallback {
                if abs(time - predicted) > 2 / sampleRate { gap = true }
                start = time
            }
        } else {
            awaitingHostAnchor = usedTimestampFallback
        }
        if !usedTimestampFallback { awaitingHostAnchor = false }
        if awaitingHostAnchor || (samplePosition == nil && (usedTimestampFallback || abs(start - time) > 2 / sampleRate)) {
            uncertainTimingPackets += 1
        }
        nextTime = start + duration
        nextPosition = samplePosition.map { $0 &+ Int64(count) }
        let accepted = mailbox.enqueue(samples, count: count, time: start,
            sampleRate: sampleRate, generation: generation, startsNewSegment: gap)
        if accepted { lastAcceptedEnd = nextTime }
        previousPacketLost = !accepted
        if accepted { signal.signal() }
        return accepted
    }

    func hasAudioForFinalWindow(endingAt end: Double) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        // One extra hop covers the last possible analysis-window alignment.
        return (lastAcceptedEnd ?? -.infinity) >= end + Double(config.frameSize / 2 + config.hopSize) / sampleRate
    }

    func rejectFormat() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !sealed else { return }
        invalidFormatPackets += 1
        previousPacketLost = true
    }

    func captureFault(now: Double) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        if invalidFormatPackets > 0 { return "The microphone format changed. Reconnect and retry." }
        if now - lastPacketArrival > 2 { return "The microphone stopped sending audio. Check the input and retry." }
        return nil
    }

    func recordDelivery(_ frames: [PitchFrame], now: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        for frame in frames {
            let age = 1000 * (now - frame.time)
            guard age.isFinite, age >= 0 else { continue }
            if deliveryAges.count < 512 { deliveryAges.append(age) }
            else {
                deliveryAges[deliveryAgeIndex] = age
                deliveryAgeIndex = (deliveryAgeIndex + 1) % 512
            }
        }
    }

    /// Deterministic entry point shared by worker and pipeline regression tests.
    /// Must have only one consumer and must not run alongside start().
    @discardableResult
    func processOne() -> Bool {
        mailbox.consumePacket { samples, time, rate, packetGeneration, startsNewSegment in
            guard !isStopping, configurationError == nil, packetGeneration == generation, rate == sampleRate else { return }
            // Do not splice audio across missing packets or clock jumps.
            if let expected = expectedPacketTime, startsNewSegment || abs(time - expected) > 2 / sampleRate {
                pending.removeAll(keepingCapacity: true)
                smoother.reset()
                markFrameGap = true
                stateLock.lock(); discontinuities += 1; stateLock.unlock()
            }
            if pending.isEmpty { pendingStart = time }
            expectedPacketTime = time + Double(samples.count) / rate
            pending.append(contentsOf: samples)
            while pending.count >= config.frameSize && !isStopping {
                let began = DispatchTime.now().uptimeNanoseconds
                let center = pendingStart + Double(config.frameSize) / (2 * sampleRate)
                let frame = pending.withUnsafeBufferPointer {
                    detector.analyze($0.baseAddress!, count: config.frameSize, time: center)
                }
                let output = PitchFrame(time: frame.time, frequency: smoother.process(frame.rawFrequency),
                                        confidence: frame.confidence, level: frame.level,
                                        rawFrequency: frame.rawFrequency, startsNewSegment: markFrameGap)
                markFrameGap = !delivery.enqueue(output)
                pending.removeFirst(config.hopSize)
                pendingStart += Double(config.hopSize) / sampleRate
                let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                stateLock.lock()
                processedFrames += 1
                if timings.count == 512 { timings.removeFirst() }
                timings.append(ms)
                stateLock.unlock()
            }
        }
    }

    private var isStopping: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopping
    }

    /// The adapter removes its tap first. Joining is bounded; an overdue worker
    /// retains its own memory and can never deliver into another generation.
    @discardableResult
    func stop(drainPending: Bool = false) -> Bool {
        stateLock.lock()
        let wasStarted = started, wasEnded = ended
        sealed = true
        stopping = !drainPending
        stateLock.unlock()
        if wasStarted && !wasEnded {
            signal.signal()
            if finished.wait(timeout: .now() + 2) == .success { return true }
            stateLock.lock(); drainTimedOut = true; stopping = true; stateLock.unlock()
            return false
        }
        if drainPending && !wasStarted { while processOne() {} }
        return true
    }

    var diagnostics: PitchEngineDiagnostics {
        let audio = mailbox.metrics, frames = delivery.metrics
        stateLock.lock(); defer { stateLock.unlock() }
        let sorted = timings.sorted()
        let ages = deliveryAges.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        return PitchEngineDiagnostics(generation: generation, detectorConfig: config, sampleRate: sampleRate,
            frameSize: config.frameSize, hopSize: config.hopSize, processedFrames: processedFrames,
            droppedPackets: audio.droppedPackets, droppedSamples: audio.droppedSamples,
            mailboxHighWaterMark: audio.highWaterMark, discontinuities: discontinuities,
            deliveryDroppedFrames: frames.droppedFrames, timestampFallbackPackets: timestampFallbackPackets,
            processingMedianMs: percentile(0.5), processingP95Ms: percentile(0.95),
            workerStopped: ended || !started, invalidFormatPackets: invalidFormatPackets,
            hostOnlyPackets: hostOnlyPackets, largestPacketSamples: largestPacketSamples,
            uncertainTimingPackets: uncertainTimingPackets, finalDrainTimedOut: drainTimedOut,
            deliveryAgeP95Ms: ages.isEmpty ? nil : ages[Int(Double(ages.count - 1) * 0.95)])
    }
}
