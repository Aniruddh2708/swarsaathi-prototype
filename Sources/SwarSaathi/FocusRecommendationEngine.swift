import Foundation

struct FocusWeakness {
    let key: SwarKey
    let percent: Double
    let count: Int
    let sessions: Int
    let patterns: Int
    let lowSessions: Int
    let sourceSessionIDs: [String]
}
/// Fixture status cannot be mistaken for documented human review.
enum FocusPatternReview: Equatable {
    case unreviewed, testFixture
    case teacherReviewed(reviewReference: String)
}
struct FocusPattern {
    let id: String
    let version: Int
    let review: FocusPatternReview
    let tuningID: String
    let notes: [SwarKey]
    let minBPM: Double
    let maxBPM: Double
    let difficulty: Int
}
enum FocusDecision {
    case insufficientHistory, noRecurringWeakness, noSafePattern
    case selected(FocusPattern, [SwarKey])
}
struct FocusRecommendationEngine {
    static let policyVersion = "focus-selection-v1-provisional"
    func assess(history: [FocusHistorySession], context: FocusContext, now: Date) -> [FocusWeakness] {
        guard context.evidencePolicy == FocusEvidencePolicy.version else { return [] }
        let cutoff = now.addingTimeInterval(-30*86400)
        let eligible = Dictionary(grouping: history, by: \.id).values.filter { $0.count == 1 }.map { $0[0] }
            .filter { !$0.id.isEmpty && !$0.patternID.isEmpty && $0.context == context && $0.ended >= cutoff && $0.ended <= now }
            .sorted { $0.ended == $1.ended ? $0.id < $1.id : $0.ended > $1.ended }
        let keys = Set(eligible.flatMap { $0.attempts.map(\.key) })
        var results: [FocusWeakness] = []
        for key in keys.sorted() {
            var rows: [(session: String, pattern: String, count: Int, score: Double)] = []
            for session in eligible {
                let valid = Dictionary(grouping: session.attempts, by: \.index).values.filter { $0.count == 1 }.map { $0[0] }
                    .filter { $0.index >= 0 && $0.key == key && $0.attribution == .pitchEvidence &&
                        $0.interiorCells >= $0.observedCells && $0.observedCells >= $0.reliableCells &&
                        $0.reliableCells >= FocusEvidencePolicy.minimumReliableCells &&
                        Double($0.reliableCells)/Double($0.interiorCells) >= FocusEvidencePolicy.minimumCoverage &&
                        (0...$0.reliableCells).contains($0.matchingCells) }
                    .sorted { $0.index < $1.index }
                guard !valid.isEmpty else { continue }
                let mean = valid.map { 100*Double($0.matchingCells)/Double($0.reliableCells) }.reduce(0,+)/Double(valid.count)
                rows.append((session.id,session.patternID,valid.count,mean))
                if rows.count == 5 { break }
            }
            let count = rows.map(\.count).reduce(0,+), patterns = Set(rows.map(\.pattern)).count
            guard count >= 10, rows.count >= 3, patterns >= 2, let median = PitchMath.median(rows.map(\.score)) else { continue }
            results.append(FocusWeakness(key:key, percent:median, count:count, sessions:rows.count, patterns:patterns,
                lowSessions:rows.filter { $0.score < 70 }.count, sourceSessionIDs:rows.map(\.session)))
        }
        return results.sorted { $0.percent == $1.percent ? $0.key < $1.key : $0.percent < $1.percent }
    }
    func recommend(evidence: [FocusWeakness], library: [FocusPattern], tuning: TuningProfile = .baseline,
                   sa: Double, lower: Double, upper: Double, bpm: Double, maxDifficulty: Int,
                   allowTestFixtures: Bool = false) -> FocusDecision {
        guard !evidence.isEmpty else { return .insufficientHistory }
        let focus = Array(evidence.filter { $0.percent.isFinite && $0.percent >= 0 && $0.percent < 70 &&
            $0.lowSessions >= 2 && $0.count >= 10 && $0.sessions >= 3 && $0.patterns >= 2 }
            .sorted { $0.percent == $1.percent ? $0.key < $1.key : $0.percent < $1.percent }.prefix(2).map(\.key))
        guard let primary = focus.first else { return .noRecurringWeakness }
        guard tuning.isValid, lower.isFinite, upper.isFinite, lower > 0, lower <= upper,
              (lower...upper).contains(sa), (70...1000).contains(sa), (40...120).contains(bpm) else { return .noSafePattern }
        let patterns = Dictionary(grouping: library, by: \.id).values.filter { $0.count == 1 }.map { $0[0] }
        var candidates: [(pattern: FocusPattern, covered: [SwarKey], count: Int)] = []
        for p in patterns {
            let reviewed: Bool
            switch p.review {
            case .teacherReviewed(let reference): reviewed = !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .testFixture: reviewed = allowTestFixtures
            case .unreviewed: reviewed = false
            }
            guard reviewed, !p.id.isEmpty, p.version > 0, p.tuningID == tuning.id,
                  p.minBPM.isFinite, p.maxBPM.isFinite, p.minBPM <= bpm, bpm <= p.maxBPM,
                  p.difficulty > 0, p.difficulty <= maxDifficulty, (5...32).contains(p.notes.count) else { continue }
            let hz = p.notes.compactMap { tuning.frequency($0, sa: sa) }
            guard hz.count == p.notes.count, hz.allSatisfy({ (lower...upper).contains($0) && (70...1000).contains($0) }),
                  zip(hz.dropFirst(), hz).allSatisfy({ abs(PitchMath.cents(detected: $0.0, expected: $0.1)) <= 400 + 1e-9 }) else { continue }
            let covered = focus.filter { key in p.notes.filter { $0 == key }.count >= 2 }
            guard covered.contains(primary) else { continue }
            candidates.append((p, covered, p.notes.filter { covered.contains($0) }.count))
        }
        let best = candidates.sorted { a,b in
            if a.covered.count != b.covered.count { return a.covered.count > b.covered.count }
            let left = a.count*b.pattern.notes.count, right = b.count*a.pattern.notes.count
            if left != right { return left > right }
            if a.pattern.difficulty != b.pattern.difficulty { return a.pattern.difficulty < b.pattern.difficulty }
            if a.pattern.notes.count != b.pattern.notes.count { return a.pattern.notes.count < b.pattern.notes.count }
            return a.pattern.id < b.pattern.id
        }.first
        guard let best else { return .noSafePattern }
        return .selected(best.pattern, best.covered)
    }
}
