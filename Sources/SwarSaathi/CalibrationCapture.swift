import Foundation

/// Capture decisions use the full timestamped recording, including silence and
/// unstable frames. A failed early estimate is a request for more evidence.
enum CalibrationCapture {
    static let minimumDuration = 3.2
    static let maximumDuration = 8.0
    static let retryInterval = 0.4

    enum Decision {
        case collecting
        case accepted(CalibrationSample)
        case rejected(String)
    }

    static func evaluate(_ observations: [CalibrationObservation], start: Double,
                         now: Double, manualStop: Bool = false) -> Decision {
        let elapsed = now - start
        guard start.isFinite, now.isFinite, elapsed >= 0 else {
            return .rejected("Invalid recording timestamps. Please retry.")
        }
        guard elapsed >= minimumDuration - 1e-9 else {
            return manualStop ? .rejected("The sample ended too soon. Hold one comfortable Aa for at least three seconds.") : .collecting
        }
        do {
            return .accepted(try CalibrationAnalyzer.summarize(observations,
                recordingStart: start, recordingEnd: now))
        } catch {
            if manualStop || elapsed >= maximumDuration - 1e-9 {
                return .rejected(error.localizedDescription)
            }
            return .collecting
        }
    }
}
