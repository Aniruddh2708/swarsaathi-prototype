#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Owns only its reference player. Capture is stopped by the calling view model
/// before playback, and output is stopped before starting microphone analysis.
final class ReferencePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let synthesisQueue = OperationQueue()
    private var request = UUID()
    private var ownsSession = false

    override init() {
        super.init()
        synthesisQueue.maxConcurrentOperationCount = 1
        synthesisQueue.qualityOfService = .userInitiated
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            self?.stop()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: value),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            self?.stop()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        synthesisQueue.cancelAllOperations()
        player?.stop()
    }

    func play(timeline: PracticeTimeline, onError: @escaping (Error) -> Void,
              completion: @escaping (Bool) -> Void) {
        stop()
        self.completion = completion
        let ticket = request
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled,
                  let wav = ReferenceSynthesis.wav(timeline: timeline, shouldContinue: { !operation.isCancelled }) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == ticket else { return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    self.ownsSession = true
                    let player = try AVAudioPlayer(data: wav)
                    player.delegate = self
                    guard player.prepareToPlay(), player.play() else {
                        throw NSError(domain: "SwarSaathi.Reference", code: 1)
                    }
                    self.player = player
                } catch {
                    self.stop()
                    onError(error)
                }
            }
        }
        synthesisQueue.addOperation(operation)
    }

    func playSa(hz: Double, onError: @escaping (Error) -> Void, completion: @escaping (Bool) -> Void) {
        let note = NoteTarget(index: 0, label: "Sa", ratio: 1, frequency: hz)
        play(timeline: PracticeTimeline(targets: [note], bpm: 40), onError: onError, completion: completion)
    }

    private func endPlayback(completed: Bool) {
        request = UUID()
        synthesisQueue.cancelAllOperations()
        player?.delegate = nil
        player?.stop()
        player = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
        let callback = completion; completion = nil
        callback?(completed)
    }

    func stop() { endPlayback(completed: false) }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        endPlayback(completed: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        endPlayback(completed: false)
    }
}
#endif
