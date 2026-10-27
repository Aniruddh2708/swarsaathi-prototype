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
    case resumed
    case failed(String)
}

/// Preserves AVAudioEngine/session ownership; one bounded worker per recording.
/// Lifecycle and callbacks are confined to the main thread.
final class PitchEngine {
    var onFrame: ((PitchFrame) -> Void)?       // main thread
    var onStatus: ((EngineStatus) -> Void)?    // main thread

    private let engine = AVAudioEngine()
    private var config = PitchConfig()
    private var activeRun: AudioProcessingRun?
    private var lastRun: AudioProcessingRun?
    private var generation: UInt64 = 0
    private var deliveryTimer: Timer?
    private var tapInstalled = false

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
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason != .categoryChange else { return }
            self?.handleConfigurationChange()
        })
    }

    deinit {
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
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw PitchEngineError.session(error.localizedDescription)
        }
        guard session.isInputAvailable else { throw PitchEngineError.noInput }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PitchEngineError.badFormat }

        generation &+= 1
        let run = AudioProcessingRun(generation: generation, sampleRate: format.sampleRate, config: config)
        if let error = run.configurationError { throw PitchEngineError.engine(error) }
        activeRun = run
        lastRun = run
        run.start()
        // Let the input node negotiate its native tap format. An explicitly
        // cached output format can be stale after a Bluetooth/Simulator route
        // change and installTap raises an NSException (not a Swift Error).
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            // Never interpret a new route's samples using the old YIN rate.
            // Route/configuration notifications terminate this recording.
            guard buffer.format.sampleRate == run.sampleRate else { return }
            guard let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            // AVAudioTime host timestamps and CACurrentMediaTime use the same
            // monotonic host clock. Timestamp the captured window, not DSP end.
            let fallback = !when.isHostTimeValid
            let time = fallback ? CACurrentMediaTime() - Double(n) / format.sampleRate
                                : AVAudioTime.seconds(forHostTime: when.hostTime)
            run.enqueue(channels[0], count: n, time: time, usedTimestampFallback: fallback)
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
            for frame in run.delivery.drain() {
                guard self.activeRun === run else { break }
                self.onFrame?(frame)
            }
        }
        deliveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSLog("Capture start generation %llu, %.0f Hz, window %d, hop %d, route %@",
              generation, format.sampleRate, config.frameSize, config.hopSize,
              session.currentRoute.inputs.map { $0.portName }.joined(separator: ", "))
    }

    private func stopEngineOnly() {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        let run = activeRun
        activeRun = nil // Invalidates all deliveries before stopping capture.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
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
        switch type {
        case .began:
            if wantsRunning {
                stopEngineOnly()
                onStatus?(.interrupted)
            }
        case .ended:
            if wantsRunning { restart() }
        @unknown default:
            break
        }
    }

    private func handleConfigurationChange() {
        // Route change (headphones, Bluetooth) or media services reset.
        guard wantsRunning else { return }
        wantsRunning = false
        stopEngineOnly()
        onStatus?(.interrupted)
    }

    private func restart() {
        do {
            try startEngine()
            onStatus?(.resumed)
        } catch {
            wantsRunning = false
            onStatus?(.failed(error.localizedDescription))
        }
    }

}
