import Foundation
import SwiftUI
import UIKit
import QuartzCore

struct GraphPoint {
    let t: Double
    let hz: Double?
    let targetHz: Double
}

struct LadderLine {
    let name: String
    let hz: Double
}

struct NoteResult: Identifiable {
    let index: Int
    let swar: String
    let expectedHz: Double
    let detectedHz: Double?
    let signedCents: Double?
    let autoCompleted: Bool
    var id: Int { index }
}

struct PracticeSummary {
    let total: Int
    let attempted: Int
    let onTarget: Int
    let needsImprovement: Int
    let avgAbsCents: Double
    let accuracyPercent: Double
}

enum FeedbackKind { case neutral, perfect, onTarget, high, low }

final class PracticeViewModel: ObservableObject {
    enum Phase { case idle, running, finished }

    let sa: Double
    let targets: [NoteTarget]
    var thresholds = AccuracyThresholds()
    var holdRequired: Double = 0.6          // seconds on target before auto-advance
    private let lockout: Double = 0.3       // ignore frames right after advancing

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentIndex = 0
    @Published private(set) var detectedHz: Double?
    @Published private(set) var cents: Double?
    @Published private(set) var feedback = "Press Start Practice, then sing Sa."
    @Published private(set) var feedbackKind: FeedbackKind = .neutral
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var graphPoints: [GraphPoint] = []
    @Published private(set) var results: [NoteResult?]
    @Published private(set) var level: Double = 0
    @Published var errorMessage: String?
    @Published var banner: String?
    @Published var permissionDenied = false

    private let engine: PitchEngine
    private var hold = 0.0
    private var lastFrameTime: Double?
    private var lastVoicedTime = 0.0
    private var noteStartTime = 0.0
    private var silentFrames = 0
    private var armed = true
    private var allSamples: [Double] = []
    private var onTargetSamples: [Double] = []

    init(sa: Double, engine: PitchEngine) {
        self.sa = sa
        self.engine = engine
        let t = Alankaar.standard.targets(sa: sa, tuning: .justShuddha)
        self.targets = t
        self.results = Array(repeating: nil, count: t.count)
    }

    var currentTarget: NoteTarget { targets[min(currentIndex, targets.count - 1)] }
    var ladder: [LadderLine] { targets.prefix(8).map { LadderLine(name: $0.label, hz: $0.frequency) } }

    var summary: PracticeSummary {
        let done = results.compactMap { $0 }.filter { $0.detectedHz != nil }
        let absList = done.compactMap { $0.signedCents }.map { abs($0) }
        let onTarget = absList.filter { $0 <= thresholds.onTargetCents }.count
        let avg = absList.isEmpty ? 0 : absList.reduce(0, +) / Double(absList.count)
        let pct = done.isEmpty ? 0 : Double(onTarget) / Double(done.count) * 100
        return PracticeSummary(total: targets.count, attempted: done.count, onTarget: onTarget,
                               needsImprovement: done.count - onTarget,
                               avgAbsCents: avg, accuracyPercent: pct)
    }

    // MARK: Session control

    func start() {
        errorMessage = nil
        banner = nil
        engine.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.permissionDenied = true
                self.errorMessage = "Microphone access is turned off. Please allow it in Settings so Swar Saathi can hear you sing."
                return
            }
            self.permissionDenied = false
            self.begin()
        }
    }

    private func begin() {
        resetSession()
        engine.onFrame = { [weak self] frame in self?.handle(frame) }
        engine.onStatus = { [weak self] status in self?.handle(status) }
        do {
            try engine.start()
            phase = .running
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    private func resetSession() {
        currentIndex = 0
        results = Array(repeating: nil, count: targets.count)
        graphPoints = []
        detectedHz = nil
        cents = nil
        feedback = "Listening..."
        feedbackKind = .neutral
        let now = CACurrentMediaTime()
        lastVoicedTime = now
        lastFrameTime = nil
        resetNoteState(time: now)
        armed = true
    }

    private func resetNoteState(time: Double) {
        hold = 0
        holdProgress = 0
        silentFrames = 0
        allSamples.removeAll()
        onTargetSamples.removeAll()
        noteStartTime = time
    }

    /// Stop button: ends the session and shows the summary if anything was sung.
    func finishEarly() {
        if results.contains(where: { $0 != nil }) { finish() } else { shutdown() }
    }

    private func finish() {
        engine.stop()
        phase = .finished
        level = 0
        detectedHz = nil
        cents = nil
        feedback = "Well done! Here is your summary."
        feedbackKind = .neutral
    }

    /// Called when leaving the screen.
    func shutdown() {
        engine.stop()
        if phase == .running { phase = .idle }
        level = 0
    }

    /// Manual fallback: move to the next note.
    func skipNote() {
        guard phase == .running else { return }
        advance(auto: false, time: CACurrentMediaTime())
    }

    // MARK: Engine callbacks

    private func handle(_ status: EngineStatus) {
        switch status {
        case .interrupted: banner = "Audio was interrupted (call or another app). Practice resumes automatically."
        case .resumed: banner = nil
        case .failed(let m): errorMessage = m
        }
    }

    private func handle(_ frame: PitchFrame) {
        guard phase == .running, currentIndex < targets.count else { return }
        level = min(1, (frame.level / 0.15).squareRoot())
        let target = targets[currentIndex]

        var dt = 0.023
        if let last = lastFrameTime { dt = min(max(frame.time - last, 0), 0.2) }
        lastFrameTime = frame.time

        graphPoints.append(GraphPoint(t: frame.time, hz: frame.frequency, targetHz: target.frequency))
        if let first = graphPoints.first, frame.time - first.t > 16 {
            graphPoints.removeAll { frame.time - $0.t > 16 }
        }

        if let f = frame.frequency {
            silentFrames = 0
            lastVoicedTime = frame.time
            detectedHz = f
            let c = PitchMath.cents(detected: f, expected: target.frequency)
            cents = c
            allSamples.append(f)

            switch thresholds.classify(c) {
            case .veryAccurate, .onTarget:
                if armed && frame.time - noteStartTime >= lockout {
                    hold += dt
                    onTargetSamples.append(f)
                }
                if thresholds.classify(c) == .veryAccurate {
                    feedback = hold >= holdRequired * 0.5 ? "Perfect! You are on pitch." : "Perfect! Hold the note."
                    feedbackKind = .perfect
                } else {
                    feedback = "On target. Hold the note."
                    feedbackKind = .onTarget
                }
            case .needsAdjustment:
                armed = true
                hold = max(0, hold - dt * 2)
                if hold == 0 { onTargetSamples.removeAll() }
                if c > 0 {
                    feedback = "A little higher than the note. Come down slightly."
                    feedbackKind = .high
                } else {
                    feedback = "A little lower than the note. Raise your pitch."
                    feedbackKind = .low
                }
            }
            holdProgress = min(hold / holdRequired, 1)
            if hold >= holdRequired { advance(auto: true, time: frame.time) }
        } else {
            // Silence / unvoiced audio is never treated as a wrong note.
            silentFrames += 1
            if silentFrames >= 2 { armed = true }
            if silentFrames > 4 {
                detectedHz = nil
                cents = nil
                hold = 0
                holdProgress = 0
                onTargetSamples.removeAll()
            }
            feedbackKind = .neutral
            feedback = frame.time - lastVoicedTime > 2.5 ? "No clear voice detected." : "Listening..."
        }
    }

    private func advance(auto: Bool, time: Double) {
        let target = targets[currentIndex]
        let samples = auto ? (onTargetSamples.isEmpty ? allSamples : onTargetSamples)
                           : Array(allSamples.suffix(10))
        if let med = PitchMath.median(samples) {
            results[currentIndex] = NoteResult(index: currentIndex, swar: target.label,
                                               expectedHz: target.frequency, detectedHz: med,
                                               signedCents: PitchMath.cents(detected: med, expected: target.frequency),
                                               autoCompleted: auto)
        } else {
            results[currentIndex] = NoteResult(index: currentIndex, swar: target.label,
                                               expectedHz: target.frequency, detectedHz: nil,
                                               signedCents: nil, autoCompleted: auto)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        currentIndex += 1
        resetNoteState(time: time)
        if currentIndex >= targets.count {
            finish()
            return
        }
        // Repeated pitch (Sa' Sa'): require a short break or movement before counting again.
        armed = targets[currentIndex].frequency != target.frequency
        detectedHz = nil
        cents = nil
        feedbackKind = .neutral
        feedback = "Next: \(targets[currentIndex].label)"
    }
}
