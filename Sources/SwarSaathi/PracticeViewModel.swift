import Foundation
import SwiftUI
import UIKit
import QuartzCore

final class PracticeViewModel: ObservableObject {
    enum Phase { case idle, running, finishing, finished }

    let sa: Double
    let lowerHz: Double?
    let upperHz: Double?
    let exercises: [Alankaar]
    var thresholds = AccuracyThresholds()
    @Published private(set) var targets: [NoteTarget]
    @Published var selectedExerciseIndex = 0 { didSet { configurationChanged() } }
    @Published var bpm: Double = 72 { didSet { configurationChanged() } }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentIndex = 0
    @Published private(set) var detectedHz: Double?
    @Published private(set) var cents: Double?
    @Published private(set) var feedback = "Start when you’re ready."
    @Published private(set) var feedbackKind: FeedbackKind = .neutral
    // Source-compatible name; now guided note progress, never a success gate.
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var graphPoints: [GraphPoint] = []
    @Published private(set) var results: [NoteResult?]
    @Published private(set) var level: Double = 0
    @Published private(set) var sessionStart: Double?
    @Published private(set) var referenceComplete = false
    @Published private(set) var referencePlaying = false
    @Published private(set) var isStarting = false
    @Published private(set) var auditURL: URL?
    @Published var errorMessage: String?
    @Published var banner: String?
    @Published var permissionDenied = false

    private let engine: PitchEngine
    private let reference = ReferencePlayer()
    private var timer: Timer?
    private var requestGeneration = 0
    private var observations: [PracticeObservation] = []
    private var lastVoicedTime: Double = 0
    private var lastScoredEnd = 0.0
    private var countInBeat: Int?
    @Published private(set) var captureWarning: String?
    private(set) var timeline: PracticeTimeline
    private(set) var timingWasEstimated = false
    private(set) var finishedSummary: PracticeSummary?
    private var incompleteReason: String?

    init(sa: Double, engine: PitchEngine, lowerHz: Double? = nil, upperHz: Double? = nil) {
        self.sa = sa
        self.engine = engine
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        // Keep every exercise visible. Availability is checked for the fixed Sa.
        self.exercises = Alankaar.demoExercises
        let initial = (self.exercises.first ?? Alankaar.fiveNote).targets(sa: sa, tuning: .justShuddha)
        self.timeline = PracticeTimeline(targets: initial, bpm: 72)
        self.targets = initial
        self.results = Array(repeating: nil, count: initial.count)
    }

    deinit { timer?.invalidate() }
    var currentTarget: NoteTarget { targets[min(currentIndex, targets.count - 1)] }
    var ladder: [LadderLine] {
        var seen: Set<String> = []
        return targets.filter { seen.insert($0.label).inserted }
            .map { LadderLine(name: $0.label, hz: $0.frequency) }.sorted { $0.hz < $1.hz }
    }

    var exerciseFitsRange: Bool {
        guard exercises.indices.contains(selectedExerciseIndex) else { return false }
        return exercises[selectedExerciseIndex].fits(sa: sa, lowerHz: lowerHz, upperHz: upperHz)
    }
    var rangeMessage: String? {
        guard !exerciseFitsRange else { return nil }
        guard exercises.indices.contains(selectedExerciseIndex), let lowerHz, let upperHz else {
            return "Choose an exercise within your recorded range."
        }
        return exercises[selectedExerciseIndex].rangeHint(sa: sa, lowerHz: lowerHz, upperHz: upperHz)
    }
    var canStart: Bool { !isStarting && phase == .idle && exerciseFitsRange }

    private func configurationChanged() {
        guard phase != .running && phase != .finishing else { return }
        reference.stop()
        referencePlaying = false
        referenceComplete = false
        guard exercises.indices.contains(selectedExerciseIndex) else { return }
        targets = exercises[selectedExerciseIndex].targets(sa: sa, tuning: .justShuddha)
        timeline = PracticeTimeline(targets: targets, bpm: min(120, max(40, bpm.isFinite ? bpm : 72)))
        resetSession()
        phase = .idle
        errorMessage = nil
        banner = nil
        feedback = "Ready to start."
    }

    func playReference() {
        guard phase == .idle && !isStarting else { return }
        guard exerciseFitsRange else {
            errorMessage = rangeMessage
            return
        }
        engine.stop()
        referenceComplete = false
        referencePlaying = true
        errorMessage = nil
        reference.play(timeline: timeline, onError: { [weak self] error in
            NSLog("Practice reference failed: %@", error.localizedDescription)
            self?.errorMessage = "Couldn’t play the melody. Check your sound output and try again."
        }) { [weak self] completed in
            guard let self = self else { return }
            self.referencePlaying = false
            self.referenceComplete = completed
            self.feedback = completed ? "Ready. Sing after the count-in." : "Ready to start."
        }
    }

    func stopReference() {
        reference.stop()
        referencePlaying = false
        referenceComplete = false
    }

    func start() {
        guard canStart else {
            errorMessage = rangeMessage ?? "Choose an exercise before starting."
            return
        }
        // Starting is an explicit choice; optional playback ends before permission/capture.
        reference.stop()
        referencePlaying = false
        requestGeneration += 1
        let generation = requestGeneration
        errorMessage = nil
        banner = nil
        isStarting = true
        engine.requestPermission { [weak self] granted in
            guard let self = self, self.requestGeneration == generation, self.isStarting else { return }
            self.isStarting = false
            guard granted else {
                self.permissionDenied = true
                self.errorMessage = "Microphone access is turned off. Allow it in Settings."
                return
            }
            self.permissionDenied = false
            self.begin()
        }
    }

    private func begin() {
        reference.stop()
        referencePlaying = false
        referenceComplete = false
        resetSession()
        engine.onFrame = { [weak self] frame in self?.handle(frame) }
        engine.onStatus = { [weak self] status in self?.handle(status) }
        do {
            try engine.start()
            sessionStart = CACurrentMediaTime() + 3 * 60 / timeline.bpm
            lastVoicedTime = sessionStart!
            phase = .running
            let newTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
            tick()
        } catch {
            engine.stop()
            NSLog("Practice microphone start failed: %@", error.localizedDescription)
            errorMessage = "Couldn’t start the microphone. Check its connection and try again."
            phase = .idle
        }
    }

    private func resetSession() {
        timer?.invalidate(); timer = nil
        currentIndex = 0
        results = Array(repeating: nil, count: targets.count)
        graphPoints.removeAll(keepingCapacity: true)
        observations.removeAll(keepingCapacity: true)
        detectedHz = nil; cents = nil; holdProgress = 0; level = 0
        sessionStart = nil
        lastScoredEnd = 0
        countInBeat = nil
        captureWarning = nil
        timingWasEstimated = false
        finishedSummary = nil
        incompleteReason = nil
        auditURL = nil
        feedbackKind = .neutral
        feedback = "Count-in…"
    }

    /// Timer advancement uses only monotonic time, never success/hold/detected F0.
    private func tick() {
        guard phase == .running, let start = sessionStart else { return }
        let now = CACurrentMediaTime(), elapsed = now - start
        let track = timeline
        if elapsed < 0 {
            let beat = min(3, Int(ceil(-elapsed * track.bpm / 60)))
            if countInBeat != beat {
                countInBeat = beat
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                feedback = "Get ready · \(beat)"
            }
            return
        }
        if countInBeat != nil {
            countInBeat = nil
            feedback = "Sing now"
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if let note = track.note(at: elapsed) {
            if currentIndex != note.target.index { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            currentIndex = note.target.index
            holdProgress = min(1, max(0, (elapsed - note.start) / (note.end - note.start)))
        }
        if now - lastVoicedTime > 0.25 {
            detectedHz = nil; cents = nil
            feedback = "Keep singing with the guide."
            feedbackKind = .neutral
        }
        let completedEnd = track.notes.last { $0.end <= elapsed }?.end ?? 0
        if completedEnd > lastScoredEnd {
            let scored = track.score(observations: observations, thresholds: thresholds)
            results = scored.results.map { result in
                elapsed >= track.notes[result.index].end ? result : nil
            }
            lastScoredEnd = completedEnd
        }
        if elapsed >= track.duration {
            let covered = engine.hasAudioForFinalWindow(endingAt: start + track.duration)
            if covered || elapsed >= track.duration + 1 {
                finish(incomplete: !covered, reason: covered ? nil : "Final microphone window did not arrive.",
                       userMessage: covered ? nil : "The microphone missed the end. Please try again.",
                       captureFault: !covered)
            }
        }
    }

    func finishEarly() {
        if phase == .running { finish(incomplete: true, reason: "Stopped before the full exercise completed.") }
        else { shutdown() }
    }

    private func finish(incomplete: Bool, reason: String? = nil, userMessage: String? = nil, captureFault: Bool = false) {
        guard phase == .running else { return }
        phase = .finishing
        requestGeneration += 1
        let generation = requestGeneration
        timer?.invalidate(); timer = nil
        reference.stop()
        let route = engine.captureRoute
        let cutoff = CACurrentMediaTime()
        engine.finishCapture { [self] frames, diagnostics in
            guard generation == requestGeneration, phase == .finishing else { return }
            for frame in frames where frame.time <= cutoff { handle(frame) }
            let scored = timeline.score(observations: observations, thresholds: thresholds)
            finishedSummary = scored.summary
            results = scored.results.map { Optional($0) }
            timingWasEstimated = diagnostics.uncertainTimingPackets > 0
            let damaged = diagnostics.hasCaptureLoss || captureFault
            captureWarning = damaged ? "Recording had a microphone or timing gap. Try again for a reliable score." : nil
            incompleteReason = reason ?? (damaged ? "Capture diagnostics indicate data loss." : nil)
            banner = incomplete ? (userMessage ?? "Stopped early. Unfinished notes count as missing.") : nil
            level = 0; detectedHz = nil; cents = nil; holdProgress = 1
            feedback = incomplete ? "Practice stopped." : "Practice complete."
            feedbackKind = .neutral
            writeAudit(incomplete: incomplete || damaged, summary: scored.summary, results: scored.results,
                       diagnostics: diagnostics, route: route)
            phase = .finished
        }
    }

    func prepareAgain() {
        shutdown()
        resetSession()
        phase = .idle
        referenceComplete = false
        errorMessage = nil
        banner = nil
        feedback = "Ready for another try."
    }

    func shutdown() {
        if phase == .finishing { return }
        if phase == .running {
            finish(incomplete: true, reason: "Practice screen closed during the attempt.")
            return
        }
        requestGeneration += 1
        isStarting = false
        timer?.invalidate(); timer = nil
        reference.stop()
        referencePlaying = false
        referenceComplete = false
        engine.stop()
        level = 0
    }

    /// Retained API for callers, but guided targets cannot be manually advanced.
    func skipNote() { banner = "Keep following the guide." }

    private func handle(_ status: EngineStatus) {
        guard phase == .running else { return }
        switch status {
        case .interrupted: finish(incomplete: true, reason: "Audio interrupted. Restart rather than resume an uncertain timeline.", userMessage: "Recording was interrupted. Tap Practice Again when ready.", captureFault: true)
        case .failed(let message):
            NSLog("Practice microphone failed: %@", message)
            finish(incomplete: true, reason: message, userMessage: "Recording stopped. Check your microphone, then tap Practice Again.", captureFault: true)
        }
    }

    private func handle(_ frame: PitchFrame) {
        guard (phase == .running || phase == .finishing), let start = sessionStart, frame.time.isFinite else { return }
        level = min(1, max(0, frame.level / 0.15).squareRoot())
        let elapsed = frame.time - start
        guard let note = timeline.note(at: elapsed) else { return } // count-in/tail excluded
        let raw = frame.rawFrequency.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let observation = PracticeObservation(time: elapsed, frequency: raw, confidence: frame.confidence.isFinite ? frame.confidence : 0)
        observations.append(observation)
        // Smoothed display is independent of scoring and never bridges unvoiced data.
        let visible = observation.isReliable ? frame.frequency : nil
        graphPoints.append(GraphPoint(t: frame.time, hz: visible, targetHz: note.target.frequency, startsNewSegment: frame.startsNewSegment == true))
        // Keep the complete fixed exercise trace (at most 24 seconds).
        guard observation.isReliable, let f = raw else {
            detectedHz = nil; cents = nil
            feedback = "Keep singing with the guide."
            feedbackKind = .neutral
            return
        }
        lastVoicedTime = frame.time
        detectedHz = f
        let error = PitchMath.cents(detected: f, expected: note.target.frequency)
        cents = error
        switch thresholds.classify(error) {
        case .veryAccurate: feedback = "On note—keep going."; feedbackKind = .perfect
        case .onTarget: feedback = "On note—keep going."; feedbackKind = .onTarget
        case .needsAdjustment:
            if timeline.matchesForPractice(observation, thresholds: thresholds) {
                feedback = "Changing note—keep going."
                feedbackKind = .neutral
            } else {
                feedback = abs(error) > 100 ? "Follow the next target—keep singing." : (error > 0 ? "Slightly high—keep going" : "Slightly low—keep going")
                feedbackKind = error > 0 ? .high : .low
            }
        }
    }

    private struct Audit: Codable {
        let schemaVersion: Int
        let createdUTC: String
        let source: String
        let saHz: Double
        let timeline: PracticeTimeline
        let observations: [PracticeObservation]
        let thresholds: AccuracyThresholds
        let summary: PracticeSummary
        let results: [NoteResult]
        let route: CaptureRoute?
        let capture: PitchEngineDiagnostics
        let incomplete: Bool
        let reason: String?
    }

    private func writeAudit(incomplete: Bool, summary: PracticeSummary, results: [NoteResult],
                            diagnostics: PitchEngineDiagnostics, route: CaptureRoute?) {
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SwarSaathiReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audit = Audit(schemaVersion: 3, createdUTC: ISO8601DateFormatter().string(from: Date()), source: "AVAudioEngine microphone raw YIN observations", saHz: sa, timeline: timeline,
                              observations: observations, thresholds: thresholds, summary: summary, results: results,
                              route: route, capture: diagnostics,
                              incomplete: incomplete, reason: incompleteReason)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = directory.appendingPathComponent("practice-\(UUID().uuidString).json")
            try encoder.encode(audit).write(to: url, options: .atomic)
            auditURL = url
            NSLog("SwarSaathi audit saved %@; %.1f%%, observations %d", url.lastPathComponent, summary.accuracyPercent, observations.count)
        } catch {
            NSLog("Practice report export failed: %@", error.localizedDescription)
            errorMessage = "Your results are shown, but the report couldn’t be saved."
        }
    }
}
