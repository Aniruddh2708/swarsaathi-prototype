import Foundation
import SwiftUI

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
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published var sa: Double = 0

    private var samples: [Double] = []
    private var missCount = 0
    private let engine: PitchEngine

    init(engine: PitchEngine) {
        self.engine = engine
    }

    var isComplete: Bool { results.count == Test.allCases.count }
    var low: Double? { results[.low] }
    var comfortable: Double? { results[.comfortable] }
    var high: Double? { results[.high] }

    var rangeSemitones: Double? {
        guard let l = low, let h = high else { return nil }
        return 12 * log2(h / l)
    }

    var orderLooksWrong: Bool {
        guard let l = low, let c = comfortable, let h = high else { return false }
        return !(l < c && c < h)
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
        errorMessage = nil
        engine.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.permissionDenied = true
                self.errorMessage = "Microphone access is turned off. Please allow it in Settings so Swar Saathi can hear you sing."
                return
            }
            self.permissionDenied = false
            self.samples.removeAll()
            self.missCount = 0
            self.liveFrequency = nil
            self.engine.onFrame = { [weak self] frame in self?.handle(frame) }
            self.engine.onStatus = { [weak self] status in self?.handle(status) }
            do {
                try self.engine.start()
                self.activeTest = test
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handle(_ frame: PitchFrame) {
        guard activeTest != nil else { return }
        level = min(1, (frame.level / 0.15).squareRoot())
        if let hz = frame.frequency {
            missCount = 0
            liveFrequency = hz
            samples.append(hz)
        } else {
            missCount += 1
            if missCount > 4 { liveFrequency = nil }
        }
    }

    private func handle(_ status: EngineStatus) {
        switch status {
        case .interrupted: errorMessage = "Audio was interrupted. We'll resume listening automatically."
        case .resumed: errorMessage = nil
        case .failed(let m): errorMessage = m
        }
    }

    private func stopAndSave() {
        guard let test = activeTest else { return }
        engine.stop()
        activeTest = nil
        liveFrequency = nil
        level = 0

        // Drop onset transients, then keep the stable cluster around the median.
        let usable = Array(samples.dropFirst(4))
        guard usable.count >= 8, let med = PitchMath.median(usable) else {
            errorMessage = "We couldn't hear a clear note. Sing a little louder and hold one note for a couple of seconds."
            return
        }
        let stable = usable.filter { abs(PitchMath.cents(detected: $0, expected: med)) < 100 }
        guard stable.count >= 8,
              Double(stable.count) >= 0.5 * Double(usable.count),
              let value = PitchMath.median(stable) else {
            errorMessage = "Your note moved around too much. Try holding one steady note."
            return
        }
        errorMessage = nil
        results[test] = value
        if test == .comfortable { sa = value.rounded() }
    }

    func stopIfNeeded() {
        if activeTest != nil {
            engine.stop()
            activeTest = nil
            liveFrequency = nil
            level = 0
        }
    }

    // MARK: Sa adjustment

    func shiftSa(semitones: Int) {
        sa = min(max((sa * pow(2, Double(semitones) / 12)).rounded(), 60), 1000)
    }

    func nudgeSa(hz: Double) {
        sa = min(max(sa + hz, 60), 1000)
    }
}
