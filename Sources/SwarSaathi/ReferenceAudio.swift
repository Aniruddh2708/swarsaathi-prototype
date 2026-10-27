#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Owns only its reference player. Capture is stopped by the calling view model
/// before playback, and output is stopped before starting microphone analysis.
final class ReferencePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    var isPlaying: Bool { player?.isPlaying ?? false }

    override init() {
        super.init()
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
        player?.stop()
    }

    func play(timeline: PracticeTimeline, completion: @escaping (Bool) -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let newPlayer = try AVAudioPlayer(data: ReferenceSynthesis.wav(timeline: timeline))
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        guard newPlayer.play() else { throw NSError(domain: "SwarSaathi.Reference", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reference playback could not start. Check the output device."]) }
        self.completion = completion
        self.player = newPlayer
    }

    func playSa(hz: Double, completion: @escaping (Bool) -> Void) throws {
        let note = NoteTarget(index: 0, label: "Sa", ratio: 1, frequency: hz)
        try play(timeline: PracticeTimeline(targets: [note], bpm: 40), completion: completion)
    }

    func stop() {
        player?.stop(); player?.delegate = nil; player = nil
        let callback = completion; completion = nil
        callback?(false)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        let callback = completion; completion = nil
        callback?(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        self.player = nil
        let callback = completion; completion = nil
        callback?(false)
    }
}
#endif
