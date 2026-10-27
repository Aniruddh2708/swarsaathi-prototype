import Foundation

// Read a locally supplied audit using the production scorer. No audio is
// synthesized, no observation is changed, and nothing is uploaded.
struct RecordedAttempt: Decodable {
    let timeline: PracticeTimeline
    let observations: [PracticeObservation]
    let thresholds: AccuracyThresholds
}

@main
struct ReplayReport {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "SwarSaathi", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: sh scripts/replay_report.sh path/to/practice.json"])
        }
        let input = try JSONDecoder().decode(RecordedAttempt.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let scored = input.timeline.score(observations: input.observations, thresholds: input.thresholds)
        struct Output: Encodable { let summary: PracticeSummary; let results: [NoteResult] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(Output(summary: scored.summary, results: scored.results))
        print(String(decoding: output, as: UTF8.self))
    }
}
