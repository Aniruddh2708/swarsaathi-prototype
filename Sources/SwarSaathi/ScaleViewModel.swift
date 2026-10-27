import Foundation
import SwiftUI
import QuartzCore

final class ScaleViewModel: ObservableObject {
    enum Test: Int, CaseIterable, Identifiable {
        case low, comfortable, high
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .low: return "Test A · Low Pitch"
            case .comfortable: return "Test B · Comfortable Pitch"
            case .high: return "Test C · High Pitch"
            }
        }
        var prompt: String {
            switch self {
            case .low: return "Sing a comfortable note in your lowest natural pitch."
            case .comfortable: return "Now sing a note that feels natural and comfortable."
            case .high: return "Finally, sing a comfortable note in your highest natural pitch."
            }
        }
        var icon: String {
            switch self {
            case .low: return "arrow.down.circle.fill"
            case .comfortable: return "equal.circle.fill"
            case .high: return "arrow.up.circle.fill"
            }
        }
    }

    @Published private(set) var results: [Test: Double] = [:]
    @Published private(set) var activeTest: Test?
    @Published private(set) var liveFrequency: Double?
    @Published private(set) var level: Double = 0
    @Published private(set) var recordingStatus = ""
    @Published private(set) var recordingElapsed: Double = 0
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published private(set) var sa: Double = 0
    @Published private(set) var isOpening = false
    @Published private(set) var isReferencePlaying = false
    @Published private var calibration = CalibrationSession()

    private var samples: [CalibrationObservation] = []
    private var summaries: [Test: CalibrationSample] = [:]
    private var measuredFrames: [Test: [CalibrationObservation]] = [:]
    private var measuredDurations: [Test: Double] = [:]
    private var missCount = 0
    private let engine: PitchEngine
    private let reference = ReferencePlayer()
    private var permissionGeneration = 0
    private var screenActive = true
    private var recordingStart = 0.0
    private var recordingTimer: Timer?

    init(engine: PitchEngine) {
        self.engine = engine
    }

    var isComplete: Bool { results.count == Test.allCases.count }
    var low: Double? { results[.low] }
    var comfortable: Double? { results[.comfortable] }
    var high: Double? { results[.high] }
    var recommendation: SaRecommendation? { calibration.recommendation }
    var canConfirm: Bool { calibration.canConfirm && !isOpening && activeTest == nil }
    var canPractice: Bool { calibration.confirmedSa == sa && sa > 0 && !isReferencePlaying && !isOpening && activeTest == nil }
    var isConfirmed: Bool { calibration.confirmedSa == sa && sa > 0 }
    var recordingControlsEnabled: Bool { !isOpening && !isReferencePlaying }

    var rangeSemitones: Double? {
        let values = results.values
        guard let l = values.min(), let h = values.max(), l > 0 else { return nil }
        return 12 * log2(h / l)
    }

    var orderLooksWrong: Bool {
        guard let l = low, let c = comfortable, let h = high else { return false }
        return !(l <= c && c <= h)
    }

    func isUnlocked(_ test: Test) -> Bool {
        guard test.rawValue > 0, let prev = Test(rawValue: test.rawValue - 1) else { return true }
        return results[prev] != nil
    }

    // MARK: Actions

    func toggle(_ test: Test) {
        if activeTest == test { stopAndSave() } else { startTest(test) }
    }

    private func startTest(_ test: Test) {
        guard screenActive, activeTest == nil, !isOpening, !isReferencePlaying else { return }
        errorMessage = nil
        permissionGeneration += 1
        let generation = permissionGeneration
        calibration.invalidate()
        sa = 0
        isOpening = true
        engine.requestPermission { [weak self] granted in
            guard let self = self, self.screenActive, self.permissionGeneration == generation else { return }
            self.isOpening = false
            guard granted else {
                self.permissionDenied = true
                self.errorMessage = "Microphone access is turned off. Please allow it in Settings so Swar Saathi can hear you sing."
                return
            }
            self.permissionDenied = false
            self.samples.removeAll()
            self.results.removeValue(forKey: test)
            self.summaries.removeValue(forKey: test)
            self.measuredFrames.removeValue(forKey: test)
            self.measuredDurations.removeValue(forKey: test)
            self.missCount = 0
            self.liveFrequency = nil
            self.engine.onFrame = { [weak self] frame in
                guard self?.permissionGeneration == generation else { return }
                self?.handle(frame)
            }
            self.engine.onStatus = { [weak self] status in
                guard self?.permissionGeneration == generation else { return }
                self?.handle(status)
            }
            do {
                try self.engine.start()
                self.recordingStart = CACurrentMediaTime()
                self.activeTest = test
                self.recordingElapsed = 0
                self.recordingStatus = "Hold one comfortable Aa. Small fluctuations are okay."
                self.recordingTimer?.invalidate()
                let timer = Timer(timeInterval: CalibrationCapture.retryInterval, repeats: true) { [weak self] _ in
                    guard self?.permissionGeneration == generation else { return }
                    self?.evaluateRecording()
                }
                self.recordingTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handle(_ frame: PitchFrame) {
        guard activeTest != nil else { return }
        level = min(1, (frame.level / 0.15).squareRoot())
        samples.append(CalibrationObservation(time: frame.time, frequency: frame.rawFrequency,
                                              confidence: frame.confidence))
        if let hz = frame.rawFrequency, hz.isFinite, hz > 0, frame.confidence >= CalibrationAnalyzer.minimumConfidence {
            missCount = 0
            liveFrequency = hz
        } else {
            missCount += 1
            if missCount > 4 { liveFrequency = nil }
        }
    }

    private func handle(_ status: EngineStatus) {
        switch status {
        case .interrupted:
            stopIfNeeded(markInactive: false)
            errorMessage = "Audio was interrupted. This sample was not accepted; retry when ready."
        case .resumed:
            stopIfNeeded(markInactive: false)
            errorMessage = "The microphone route changed. Retry this sample with the selected input."
        case .failed(let m):
            stopIfNeeded(markInactive: false)
            errorMessage = m
        }
    }

    private func stopAndSave() { evaluateRecording(manualStop: true) }

    private func evaluateRecording(manualStop: Bool = false) {
        guard activeTest != nil else { return }
        let now = CACurrentMediaTime()
        recordingElapsed = max(0, now - recordingStart)
        switch CalibrationCapture.evaluate(samples, start: recordingStart, now: now, manualStop: manualStop) {
        case .collecting:
            recordingStatus = recordingElapsed < CalibrationCapture.minimumDuration
                ? "Hold one comfortable Aa. Small fluctuations are okay."
                : "Still listening for a steady center. Keep singing comfortably; up to eight seconds."
        case .accepted(let sample):
            finishRecording(sample: sample, rejection: nil, recordingEnd: now)
        case .rejected(let message):
            finishRecording(sample: nil, rejection: message, recordingEnd: now)
        }
    }

    private func finishRecording(sample: CalibrationSample?, rejection: String?, recordingEnd: Double) {
        guard let test = activeTest else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        engine.stop()
        activeTest = nil
        liveFrequency = nil
        level = 0
        recordingStatus = ""
        measuredFrames[test] = samples
        measuredDurations[test] = recordingEnd - recordingStart
        guard let sample = sample else {
            errorMessage = rejection ?? "No reliable calibration sample was measured. Please retry."
            NSLog("Calibration rejected after %.2f s: %@", recordingEnd - recordingStart, errorMessage!)
            saveAudit(status: errorMessage!)
            return
        }
        do {
            summaries[test] = sample
            results[test] = sample.medianHz
            errorMessage = nil
            if let low = summaries[.low], let middle = summaries[.comfortable], let high = summaries[.high] {
                let proposal = try CalibrationAnalyzer.recommend(samples: [low, middle, high])
                calibration.propose(proposal)
                sa = proposal.saHz
            }
            NSLog("Calibration sample %@ after %.2f s: %.3f Hz, %.0f%% reliable coverage", test.title,
                  recordingEnd - recordingStart, sample.medianHz, 100 * sample.coverage)
        } catch {
            errorMessage = error.localizedDescription
            NSLog("Calibration recommendation rejected: %@", error.localizedDescription)
        }
        saveAudit(status: errorMessage ?? "Measured sample accepted")
    }

    func stopIfNeeded(markInactive: Bool = true) {
        permissionGeneration += 1
        if markInactive { screenActive = false }
        isOpening = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        reference.stop()
        isReferencePlaying = false
        engine.stop()
        activeTest = nil
        liveFrequency = nil
        level = 0
        recordingStatus = ""
        recordingElapsed = 0
    }

    func activate() { screenActive = true }

    func playReference() {
        guard let proposal = recommendation, activeTest == nil, !isOpening else { return }
        reference.stop()
        engine.stop()
        let frequency = proposal.saHz
        let generation = permissionGeneration
        isReferencePlaying = true
        do {
            try reference.playSa(hz: frequency) { [weak self] completed in
                guard let self = self, self.screenActive, self.permissionGeneration == generation else { return }
                self.isReferencePlaying = false
                self.calibration.referenceFinished(hz: frequency, successful: completed)
                if !completed { NSLog("Optional Sa reference playback stopped before completion") }
            }
        } catch {
            isReferencePlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func stopReference() {
        reference.stop()
        isReferencePlaying = false
    }

    func confirmSa() {
        guard canConfirm else { return }
        stopReference()
        do {
            try calibration.confirm()
            errorMessage = nil
            saveAudit(status: "Sa explicitly confirmed by singer; reference playback optional")
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Sa adjustment

    func shiftSa(semitones: Int) {
        adjustSa(to: sa * pow(2, Double(semitones) / 12))
    }

    func nudgeSa(hz: Double) {
        adjustSa(to: sa + hz)
    }

    private func adjustSa(to value: Double) {
        guard !isReferencePlaying, activeTest == nil, !isOpening else { return }
        do {
            try calibration.adjust(to: value)
            sa = value
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveAudit(status: String) {
        struct Audit: Codable {
            let created: Date
            let status: String
            let observations: [String: [CalibrationObservation]]
            let samples: [String: CalibrationSample]
            let recordingDurations: [String: Double]
            let recommendation: SaRecommendation?
            let confirmedSa: Double?
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let folder = documents.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rows = Dictionary(uniqueKeysWithValues: measuredFrames.map { ($0.key.title, $0.value) })
            let stats = Dictionary(uniqueKeysWithValues: summaries.map { ($0.key.title, $0.value) })
            let durations = Dictionary(uniqueKeysWithValues: measuredDurations.map { ($0.key.title, $0.value) })
            let audit = Audit(created: Date(), status: status, observations: rows, samples: stats, recordingDurations: durations,
                              recommendation: recommendation, confirmedSa: calibration.confirmedSa)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(audit).write(to: folder.appendingPathComponent("calibration-\(UUID().uuidString).json"), options: .atomic)
        } catch { NSLog("Calibration diagnostic export failed: %@", error.localizedDescription) }
    }
}
