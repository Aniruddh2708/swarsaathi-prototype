import Foundation

/// The actual schema-3 audit fields needed for research. Other fields (including
/// saved scores) remain untouched. Schema 3 lacks stable calibration/session IDs.
struct FocusPracticeReport: Decodable {
    struct Route: Decodable {
        let inputTypes: [String]
        let sampleRate: Double
        let channels: Int
        var fingerprint: String { inputTypes.sorted().joined(separator: "+") + ":\(sampleRate):\(channels)" }
    }
    let schemaVersion: Int
    let createdUTC: String
    let source: String
    let saHz: Double
    let timeline: PracticeTimeline
    let observations: [PracticeObservation]
    let thresholds: AccuracyThresholds
    let route: Route?
    let capture: PitchEngineDiagnostics
    let incomplete: Bool
    let reason: String?
}
/// External verified links, not inferred from filenames or similar Sa values.
/// Record-only must be established by the source revision/capture provenance.
struct FocusReportProvenance {
    let sessionID: String
    let calibrationID: String
    let sourceRevision: String
    let verifiedRecordOnly: Bool
}
struct FocusContext: Hashable {
    let calibrationID: String
    let saHz: Double
    let tuningID: String
    let evidencePolicy: String
    let sourceRevision: String
    let bpm: Double
    let routeFingerprint: String
}
enum FocusAttribution: String, Codable { case pitchEvidence, timingAmbiguous, octaveAmbiguous, missingOrUnclear }
struct FocusAttempt: Codable {
    let index: Int
    let key: SwarKey
    let attribution: FocusAttribution
    let interiorCells: Int
    let observedCells: Int
    let reliableCells: Int
    let matchingCells: Int
}
struct FocusHistorySession {
    let id: String
    let patternID: String
    let ended: Date
    let context: FocusContext
    let attempts: [FocusAttempt]
}
enum FocusExtractionError: Error { case unsupportedReport, missingProvenance, damagedCapture, invalidTimeline, invalidObservations }
enum FocusEvidencePolicy {
    static let version = "focus-evidence-v1-provisional"
    static let minimumCoverage = 0.80
    static let minimumReliableCells = 5
    static let minimumReliableSeconds = 0.20
    static let tolerance = 50.0
}
struct FocusEvidenceExtractor {
    func extract(data: Data, provenance: FocusReportProvenance) throws -> FocusHistorySession {
        try extract(report: JSONDecoder().decode(FocusPracticeReport.self, from: data), provenance: provenance)
    }
    /// Separate diagnostic evidence; never changes PracticeTimeline.score.
    func extract(report r: FocusPracticeReport, provenance p: FocusReportProvenance) throws -> FocusHistorySession {
        guard r.schemaVersion == 3, r.source == "AVAudioEngine microphone raw YIN observations",
              r.thresholds.onTargetCents == 50, r.thresholds.veryAccurateCents == 25,
              let ended = ISO8601DateFormatter().date(from: r.createdUTC) else { throw FocusExtractionError.unsupportedReport }
        guard !p.sessionID.isEmpty, !p.calibrationID.isEmpty, p.sourceRevision.count == 40,
              p.sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              p.verifiedRecordOnly else { throw FocusExtractionError.missingProvenance }
        let c = r.capture
        guard !r.incomplete, r.reason == nil, !c.hasCaptureLoss, c.workerStopped,
              c.droppedPackets == 0, c.droppedSamples == 0, c.discontinuities == 0,
              c.deliveryDroppedFrames == 0, c.invalidFormatPackets == 0,
              c.uncertainTimingPackets == 0, c.timestampFallbackPackets == 0,
              c.hostOnlyPackets == 0, c.processedFrames > 0,
              let route = r.route, !route.inputTypes.isEmpty, route.channels > 0,
              route.sampleRate == c.sampleRate, (8000...192000).contains(c.sampleRate) else { throw FocusExtractionError.damagedCapture }
        let tuning = TuningProfile.baseline, notes = r.timeline.notes
        guard (70...1000).contains(r.saHz), (40...120).contains(r.timeline.bpm),
              (1...128).contains(notes.count) else { throw FocusExtractionError.invalidTimeline }
        let beat = 60 / r.timeline.bpm
        var keys: [SwarKey] = []
        for (i, n) in notes.enumerated() {
            guard let key = SwarKey.legacyLabel(n.target.label), let hz = tuning.frequency(key, sa: r.saHz),
                  n.target.index == i, abs(n.start - Double(i)*beat) < 1e-8,
                  abs(n.end - Double(i+1)*beat) < 1e-8,
                  abs(hz - n.target.frequency) < 1e-6, abs(hz/r.saHz - n.target.ratio) < 1e-8,
                  (70...1000).contains(hz) else { throw FocusExtractionError.invalidTimeline }
            keys.append(key)
        }
        let obs = r.observations.sorted { $0.time < $1.time }
        guard obs.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < r.timeline.duration &&
            $0.confidence.isFinite && (0...1).contains($0.confidence) &&
            ($0.frequency.map { $0.isFinite && $0 > 0 } ?? true) }),
            Set(obs.map(\.time)).count == obs.count else { throw FocusExtractionError.invalidObservations }
        let shifted = hasConsistentTimingShift(obs, timeline: r.timeline)
        var attempts: [FocusAttempt] = []
        for (i, note) in notes.enumerated() {
            let duration = note.end - note.start
            let count = max(1, Int(ceil(duration / 0.04 - 1e-10)))
            let width = duration / Double(count), margin = min(0.15, 0.20 * duration)
            let interior = (0..<count).filter {
                let t = note.start + (Double($0)+0.5)*width
                return t >= note.start+margin && t < note.end-margin
            }
            let allowed = Set(interior)
            var chosen: [Int: PracticeObservation] = [:]
            for o in obs where o.time >= note.start && o.time < note.end {
                let index = min(count-1, Int((o.time-note.start)/width))
                guard allowed.contains(index) else { continue }
                let midpoint = note.start+(Double(index)+0.5)*width
                if let old = chosen[index], abs(old.time-midpoint) <= abs(o.time-midpoint) { continue }
                chosen[index] = o
            }
            let reliable = chosen.values.filter(\.isReliable)
            let errors = reliable.compactMap { $0.frequency.map { PitchMath.cents(detected: $0, expected: note.target.frequency) } }
            let matches = errors.filter { abs($0) <= FocusEvidencePolicy.tolerance + 1e-9 }.count
            let neighbors = [i-1,i+1].filter { notes.indices.contains($0) && keys[$0] != keys[i] }.map { notes[$0].target.frequency }
            let neighborHeld = reliable.filter { o in
                guard let hz = o.frequency else { return false }
                return abs(PitchMath.cents(detected: hz, expected: note.target.frequency)) > 50 &&
                    neighbors.contains { abs(PitchMath.cents(detected: hz, expected: $0)) <= 50 }
            }.count
            let octaveErrors = errors.filter { abs(abs($0)-1200) <= 50 }.count
            let enough = !interior.isEmpty && Double(chosen.count)/Double(interior.count) >= FocusEvidencePolicy.minimumCoverage &&
                Double(reliable.count)/Double(interior.count) >= FocusEvidencePolicy.minimumCoverage &&
                reliable.count >= FocusEvidencePolicy.minimumReliableCells &&
                Double(reliable.count)*width >= FocusEvidencePolicy.minimumReliableSeconds
            let attribution: FocusAttribution
            if !enough { attribution = .missingOrUnclear }
            else if shifted || neighborHeld >= max(2, Int(ceil(Double(reliable.count)*0.20))) { attribution = .timingAmbiguous }
            else if octaveErrors > 0 { attribution = .octaveAmbiguous }
            else { attribution = .pitchEvidence }
            attempts.append(FocusAttempt(index: i, key: keys[i], attribution: attribution, interiorCells: interior.count,
                observedCells: chosen.count, reliableCells: reliable.count, matchingCells: matches))
        }
        // Exact sequence identity, independent of display name or caller label.
        let patternID = keys.map { "\($0.variant.rawValue):\($0.octave)" }.joined(separator: ",")
        return FocusHistorySession(id: p.sessionID, patternID: patternID, ended: ended,
            context: FocusContext(calibrationID: p.calibrationID, saHz: r.saHz, tuningID: tuning.id,
                evidencePolicy: FocusEvidencePolicy.version, sourceRevision: p.sourceRevision, bpm: r.timeline.bpm,
                routeFingerprint: route.fingerprint), attempts: attempts)
    }
    /// Fixed reliable comparison set; requires improved matches at distinct
    /// transition boundaries. Does not realign timestamps or award credit.
    private func hasConsistentTimingShift(_ observations: [PracticeObservation], timeline: PracticeTimeline) -> Bool {
        let set = observations.filter { $0.isReliable && $0.time >= 0.2 && $0.time < timeline.duration-0.2 }
        guard set.count >= 10 else { return false }
        let boundaries = timeline.notes.dropFirst().map(\.start)
        func match(_ o: PracticeObservation, offset: Double) -> Bool {
            guard let n = timeline.note(at: o.time-offset), let hz = o.frequency else { return false }
            return abs(PitchMath.cents(detected: hz, expected: n.target.frequency)) <= 50
        }
        let original = set.map { match($0, offset: 0) }
        let baseline = original.filter { $0 }.count
        for step in -20...20 where abs(step) >= 6 {
            let offset = Double(step)/100
            let candidate = set.map { match($0, offset: offset) }
            let improvement = Double(candidate.filter { $0 }.count-baseline)/Double(set.count)
            if improvement + 1e-12 < 0.10 { continue }
            let improvedBoundaries = boundaries.filter { boundary in
                set.indices.contains { !original[$0] && candidate[$0] && abs(set[$0].time-boundary) <= 0.2 }
            }
            if improvedBoundaries.count >= 2 { return true }
        }
        return false
    }
}
