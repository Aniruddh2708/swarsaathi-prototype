import Foundation
import AVFoundation
import Accelerate
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

/// Owns AVAudioEngine, runs YIN on a background queue, and delivers `PitchFrame`s on the main queue.
final class PitchEngine {
    var onFrame: ((PitchFrame) -> Void)?       // main thread
    var onStatus: ((EngineStatus) -> Void)?    // main thread

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "swarsaathi.audio.processing", qos: .userInitiated)
    private var config = PitchConfig()

    // Confined to `queue`
    private var detector: YINPitchDetector?
    private var smoother = PitchSmoother()
    private var pending: [Float] = []

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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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
        wantsRunning = true
        do {
            try startEngine()
        } catch {
            wantsRunning = false
            throw error
        }
    }

    func stop() {
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
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PitchEngineError.badFormat }

        let det = YINPitchDetector(sampleRate: format.sampleRate, config: config)
        queue.sync {
            self.detector = det
            self.pending.removeAll(keepingCapacity: true)
            self.smoother.reset()
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: n))
            self.queue.async { self.process(samples) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw PitchEngineError.engine(error.localizedDescription)
        }
    }

    private func stopEngineOnly() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        stopEngineOnly()
        restart()
    }

    private func restart() {
        do {
            try startEngine()
            onStatus?(.resumed)
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    // MARK: Processing (background queue)

    private func process(_ samples: [Float]) {
        guard let detector = detector else { return }
        pending.append(contentsOf: samples)

        while pending.count >= config.frameSize {
            let frame = Array(pending.prefix(config.frameSize))
            pending.removeFirst(config.hopSize)
            let count = vDSP_Length(frame.count)

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, count)

            var raw: Double?
            var confidence = 0.0
            if rms >= config.silenceRMS {
                var mean: Float = 0
                vDSP_meanv(frame, 1, &mean, count)
                var negMean = -mean
                var centered = [Float](repeating: 0, count: frame.count)
                vDSP_vsadd(frame, 1, &negMean, &centered, 1, count)
                let result = centered.withUnsafeBufferPointer { detector.detect($0.baseAddress!) }
                if let r = result, r.frequency >= config.minFrequency, r.frequency <= config.maxFrequency {
                    raw = r.frequency
                    confidence = r.confidence
                }
            }

            let smoothed = smoother.process(raw)
            let out = PitchFrame(time: CACurrentMediaTime(), frequency: smoothed,
                                 confidence: confidence, level: Double(rms))
            DispatchQueue.main.async { [weak self] in self?.onFrame?(out) }
        }
    }
}
