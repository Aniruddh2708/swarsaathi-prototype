import Foundation
import AVFoundation
import QuartzCore

enum PitchEngineError: LocalizedError {
    case session(String)
    case noInput
    case badFormat
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .session(let m): return "Couldn't configure the audio session: \(m)"
        case .noInput: return "No microphone is available right now."
        case .badFormat: return "The microphone returned an invalid audio format. Try again."
        case .engine(let m): return "Couldn't start the microphone: \(m)"
        }
    }
}

enum EngineStatus {
    case interrupted
    case failed(String)
}

struct CaptureRoute: Codable {
    let inputTypes: [String]
    let sampleRate: Double
    let channels: Int
    let reportedInputLatencyMs: Double
    let ioBufferDurationMs: Double
}

/// Preserves AVAudioEngine/session ownership; one bounded worker per recording.
/// Lifecycle and callbacks are confined to the main thread.
final class PitchEngine {
    var onFrame: ((PitchFrame) -> Void)?       // main thread
    var onStatus: ((EngineStatus) -> Void)?    // main thread

    private var engine = AVAudioEngine()
    private var engineObserver: NSObjectProtocol?
    private var activeInputIDs: [String] = []
    private var activeRun: AudioProcessingRun?
    private var lastRun: AudioProcessingRun?
    private var generation: UInt64 = 0
    private var deliveryTimer: Timer?
    private var tapInstalled = false
    private(set) var captureRoute: CaptureRoute?

    var diagnostics: PitchEngineDiagnostics {
        (activeRun ?? lastRun ?? AudioProcessingRun(generation: 0, sampleRate: 44100)).diagnostics
    }

    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] n in
            self?.handleInterruption(n)
        })
        observeEngine()
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.interrupt(.interrupted)
            self.engine = AVAudioEngine()
            self.observeEngine()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason != .categoryChange else { return }
            self?.handleConfigurationChange()
        })
    }

    private func observeEngine() {
        let center = NotificationCenter.default
        if let engineObserver { center.removeObserver(engineObserver) }
        engineObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                           queue: .main) { [weak self, weak observed = engine] _ in
            guard let self, self.engine === observed else { return }
            self.handleConfigurationChange()
        }
    }

    deinit {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        deliveryTimer?.invalidate()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        activeRun?.stop()
    }

    // MARK: Permission

    /// Completion is always called on the main queue.
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: completion(true); return
            case .denied: completion(false); return
            default: break
            }
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted: completion(true); return
            case .denied: completion(false); return
            default: break
            }
            session.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: Start / stop

    func start() throws {
        precondition(Thread.isMainThread)
        wantsRunning = true
        do {
            try startEngine()
        } catch {
            wantsRunning = false
            stopEngineOnly()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        wantsRunning = false
        stopEngineOnly()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            throw PitchEngineError.session(error.localizedDescription)
        }
        guard session.isInputAvailable else { throw PitchEngineError.noInput }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PitchEngineError.badFormat }

        generation &+= 1
        let run = AudioProcessingRun(generation: generation, sampleRate: format.sampleRate)
        if let error = run.configurationError { throw PitchEngineError.engine(error) }
        activeInputIDs = session.currentRoute.inputs.map(\.uid)
        captureRoute = CaptureRoute(inputTypes: session.currentRoute.inputs.map { $0.portType.rawValue },
            sampleRate: format.sampleRate, channels: Int(format.channelCount),
            reportedInputLatencyMs: session.inputLatency * 1000, ioBufferDurationMs: session.ioBufferDuration * 1000)
        activeRun = run
        lastRun = run
        run.start()
        // Let the input node negotiate its native tap format. An explicitly
        // cached output format can be stale after a Bluetooth/Simulator route
        // change and installTap raises an NSException (not a Swift Error).
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            // Never interpret a new route's samples using the old YIN rate.
            // Route/configuration notifications terminate this recording.
            guard buffer.format.sampleRate == run.sampleRate,
                  buffer.format.channelCount > 0,
                  !buffer.format.isInterleaved || buffer.format.channelCount == 1,
                  let channels = buffer.floatChannelData else { run.rejectFormat(); return }
            guard buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            // AVAudioTime host timestamps and CACurrentMediaTime use the same
            // monotonic host clock. Timestamp the captured window, not DSP end.
            let fallback = !when.isHostTimeValid
            let time = fallback ? CACurrentMediaTime() - Double(n) / format.sampleRate
                                : AVAudioTime.seconds(forHostTime: when.hostTime)
            run.enqueue(channels[0], count: n, time: time, usedTimestampFallback: fallback,
                        samplePosition: when.isSampleTimeValid && when.sampleRate == run.sampleRate ? when.sampleTime : nil)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngineOnly()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw PitchEngineError.engine(error.localizedDescription)
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self, weak run] _ in
            guard let self = self, let run = run, self.activeRun === run else { return }
            if let fault = run.captureFault(now: ProcessInfo.processInfo.systemUptime) {
                self.interrupt(.failed(fault))
                return
            }
            let frames = run.delivery.drain()
            run.recordDelivery(frames, now: CACurrentMediaTime())
            for frame in frames {
                guard self.activeRun === run else { break }
                self.onFrame?(frame)
            }
        }
        deliveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSLog("Capture start generation %llu, %.0f Hz, window %d, hop %d, route %@",
              generation, format.sampleRate, run.config.frameSize, run.config.hopSize,
              session.currentRoute.inputs.map { $0.portName }.joined(separator: ", "))
    }

    private func detachCapture() -> AudioProcessingRun? {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        let run = activeRun
        activeRun = nil // Invalidates all deliveries before stopping capture.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        return run
    }

    func hasAudioForFinalWindow(endingAt end: Double) -> Bool {
        activeRun?.hasAudioForFinalWindow(endingAt: end) ?? false
    }

    // Freeze admission before draining. The main thread stays available while
    // the isolated worker finishes the bounded queue for this attempt.
    func finishCapture(_ completion: @escaping ([PitchFrame], PitchEngineDiagnostics) -> Void) {
        wantsRunning = false
        let run = detachCapture()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let run else { completion([], diagnostics); return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = run.stop(drainPending: true)
            let frames = run.delivery.drain()
            DispatchQueue.main.async {
                run.recordDelivery(frames, now: CACurrentMediaTime())
                completion(frames, run.diagnostics)
            }
        }
    }

    private func stopEngineOnly() {
        let run = detachCapture()
        if let run = run {
            let joined = run.stop()
            let stats = run.diagnostics
            NSLog("Capture stop generation %llu: frames %d, drops %d samples, discontinuities %d, delivery drops %d, DSP median %.3f / p95 %.3f ms, joined %@",
                  stats.generation, stats.processedFrames, stats.droppedSamples, stats.discontinuities,
                  stats.deliveryDroppedFrames, stats.processingMedianMs, stats.processingP95Ms,
                  joined ? "yes" : "NO")
        }
    }

    // MARK: Interruptions

    private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { interrupt(.interrupted) }
    }

    private func handleConfigurationChange() {
        guard let run = activeRun, wantsRunning else { return }
        let session = AVAudioSession.sharedInstance()
        let sameInput = session.currentRoute.inputs.map(\.uid) == activeInputIDs
        let current = engine.inputNode.inputFormat(forBus: 0)
        if engine.isRunning && sameInput && current.sampleRate == run.sampleRate &&
            Int(current.channelCount) == captureRoute?.channels { return }
        interrupt(.interrupted)
    }

    private func interrupt(_ status: EngineStatus) {
        guard wantsRunning, let run = activeRun else { return }
        wantsRunning = false
        onStatus?(status)
        if activeRun === run { stop() }
    }
}
