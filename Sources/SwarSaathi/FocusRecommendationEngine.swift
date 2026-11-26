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
        let grouped: [String: [FocusHistorySession]] = Dictionary(grouping: history, by: { $0.id })
        var eligible: [FocusHistorySession] = []
        for group in grouped.values {
            guard group.count == 1, let session = group.first else { continue }
            guard !session.id.isEmpty, !session.patternID.isEmpty, session.context == context,
                  session.ended >= cutoff, session.ended <= now else { continue }
            eligible.append(session)
        }
        eligible.sort { a, b in
            if a.ended == b.ended { return a.id < b.id }
            return a.ended > b.ended
        }
        var keys = Set<SwarKey>()
        for session in eligible {
            for attempt in session.attempts { keys.insert(attempt.key) }
        }
        var results: [FocusWeakness] = []
        for key in keys.sorted() {
            var rows: [(session: String, pattern: String, count: Int, score: Double)] = []
            for session in eligible {
                let groupedAttempts: [Int: [FocusAttempt]] = Dictionary(grouping: session.attempts, by: { $0.index })
                var valid: [FocusAttempt] = []
                for group in groupedAttempts.values {
                    guard group.count == 1, let attempt = group.first else { continue }
                    guard attempt.index >= 0, attempt.key == key, attempt.attribution == .pitchEvidence,
                          attempt.interiorCells >= attempt.observedCells,
                          attempt.observedCells >= attempt.reliableCells,
                          attempt.reliableCells >= FocusEvidencePolicy.minimumReliableCells,
                          (0...attempt.reliableCells).contains(attempt.matchingCells) else { continue }
                    let coverage: Double = Double(attempt.reliableCells) / Double(attempt.interiorCells)
                    guard coverage >= FocusEvidencePolicy.minimumCoverage else { continue }
                    valid.append(attempt)
                }
                valid.sort { $0.index < $1.index }
                guard !valid.isEmpty else { continue }
                var sum: Double = 0
                for attempt in valid {
                    let percent: Double = 100.0 * Double(attempt.matchingCells) / Double(attempt.reliableCells)
                    sum += percent
                }
                let mean: Double = sum / Double(valid.count)
                rows.append((session.id, session.patternID, valid.count, mean))
                if rows.count == 5 { break }
            }
            var count: Int = 0
            var distinctPatterns = Set<String>()
            var scores: [Double] = []
            var sessionIDs: [String] = []
            var lowSessions: Int = 0
            for row in rows {
                count += row.count
                distinctPatterns.insert(row.pattern)
                scores.append(row.score)
                sessionIDs.append(row.session)
                if row.score < 70 { lowSessions += 1 }
            }
            let patterns: Int = distinctPatterns.count
            guard count >= 10, rows.count >= 3, patterns >= 2, let median = PitchMath.median(scores) else { continue }
            results.append(FocusWeakness(key:key, percent:median, count:count, sessions:rows.count, patterns:patterns,
                lowSessions:lowSessions, sourceSessionIDs:sessionIDs))
        }
        return results.sorted { $0.percent == $1.percent ? $0.key < $1.key : $0.percent < $1.percent }
    }
    func recommend(evidence: [FocusWeakness], library: [FocusPattern], tuning: TuningProfile = .baseline,
                   sa: Double, lower: Double, upper: Double, bpm: Double, maxDifficulty: Int,
                   allowTestFixtures: Bool = false) -> FocusDecision {
        guard !evidence.isEmpty else { return .insufficientHistory }
        let weak: [FocusWeakness] = evidence.filter { item in
            item.percent.isFinite && item.percent >= 0 && item.percent < 70 &&
            item.lowSessions >= 2 && item.count >= 10 && item.sessions >= 3 && item.patterns >= 2
        }
        let ranked: [FocusWeakness] = weak.sorted { a, b in
            a.percent == b.percent ? a.key < b.key : a.percent < b.percent
        }
        let focus: [SwarKey] = ranked.prefix(2).map { $0.key }
        guard let primary = focus.first else { return .noRecurringWeakness }
        guard tuning.isValid, lower.isFinite, upper.isFinite, lower > 0, lower <= upper,
              (lower...upper).contains(sa), (70...1000).contains(sa), (40...120).contains(bpm) else { return .noSafePattern }
        let groupedPatterns: [String: [FocusPattern]] = Dictionary(grouping: library, by: { $0.id })
        let patterns: [FocusPattern] = groupedPatterns.values.compactMap { group in
            group.count == 1 ? group.first : nil
        }
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
            let hz: [Double] = p.notes.compactMap { tuning.frequency($0, sa: sa) }
            guard hz.count == p.notes.count else { continue }
            let fitsRange: Bool = hz.allSatisfy { (lower...upper).contains($0) && (70...1000).contains($0) }
            guard fitsRange else { continue }
            let fitsIntervals: Bool = zip(hz.dropFirst(), hz).allSatisfy { pair in
                abs(PitchMath.cents(detected: pair.0, expected: pair.1)) <= 400 + 1e-9
            }
            guard fitsIntervals else { continue }
            var covered: [SwarKey] = []
            for key in focus {
                let occurrences: Int = p.notes.filter { $0 == key }.count
                if occurrences >= 2 { covered.append(key) }
            }
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
