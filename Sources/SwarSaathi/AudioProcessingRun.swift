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
    private var stopping = false
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
    private var smoother = PitchSmoother()

    init(generation: UInt64, sampleRate: Double, config: PitchConfig = PitchConfig(),
         capacity: Int = 8, maxSamples: Int = 8192) {
        self.generation = generation; self.sampleRate = sampleRate; self.config = config
        detector = YINPitchDetector(sampleRate: sampleRate, config: config)
        mailbox = BoundedAudioMailbox(capacity: capacity, maxSamples: maxSamples)
        mailbox.reset(generation: generation)
        pending.reserveCapacity(config.frameSize + maxSamples)
        timings.reserveCapacity(512)
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
                _ = processOne()
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
                 usedTimestampFallback: Bool = false) -> Bool {
        stateLock.lock()
        let reject = stopping
        if usedTimestampFallback { timestampFallbackPackets += 1 }
        stateLock.unlock()
        guard !reject else { return false }
        let accepted = mailbox.enqueue(samples, count: count, time: time,
                                       sampleRate: sampleRate, generation: generation)
        if accepted { signal.signal() }
        return accepted
    }

    /// Deterministic entry point shared by worker and pipeline regression tests.
    /// Must have only one consumer and must not run alongside start().
    @discardableResult
    func processOne() -> Bool {
        mailbox.consumeNext { samples, time, rate, packetGeneration in
            guard !isStopping, configurationError == nil, packetGeneration == generation, rate == sampleRate else { return }
            // Do not splice audio across missing packets or clock jumps.
            if let expected = expectedPacketTime, abs(time - expected) > 2 / sampleRate {
                pending.removeAll(keepingCapacity: true)
                smoother.reset()
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
                                        rawFrequency: frame.rawFrequency)
                _ = delivery.enqueue(output)
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
    func stop() -> Bool {
        stateLock.lock()
        let wasStarted = started, wasEnded = ended
        stopping = true
        stateLock.unlock()
        if wasStarted && !wasEnded {
            signal.signal()
            return finished.wait(timeout: .now() + 2) == .success
        }
        return true
    }

    var diagnostics: PitchEngineDiagnostics {
        let audio = mailbox.metrics, frames = delivery.metrics
        stateLock.lock(); defer { stateLock.unlock() }
        let sorted = timings.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        return PitchEngineDiagnostics(generation: generation, detectorConfig: config, sampleRate: sampleRate,
            frameSize: config.frameSize, hopSize: config.hopSize, processedFrames: processedFrames,
            droppedPackets: audio.droppedPackets, droppedSamples: audio.droppedSamples,
            mailboxHighWaterMark: audio.highWaterMark, discontinuities: discontinuities,
            deliveryDroppedFrames: frames.droppedFrames, timestampFallbackPackets: timestampFallbackPackets,
            processingMedianMs: percentile(0.5), processingP95Ms: percentile(0.95),
            workerStopped: ended || !started)
    }
}
