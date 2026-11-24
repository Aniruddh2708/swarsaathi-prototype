import Foundation

/// Offline comparison. The detector receives PCM only. Reference labels enter
/// after inference, including all labelled silence and acquisition edges.
@main
struct ValidateRecording {
    struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Audio {
        let rate: Double
        let samples: [Float]

        init(url: URL) throws {
            let data = try Data(contentsOf: url)
            func tag(_ i: Int) -> String { String(decoding: data[i..<i + 4], as: UTF8.self) }
            func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
            func u32(_ i: Int) -> Int { Int(u16(i)) | Int(u16(i + 2)) << 16 }
            let invalid = InputError(message: "Expected a mono 16-bit PCM WAV file with a valid sample rate.")
            guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw invalid }
            var offset = 12, pcm: Range<Int>?, sampleRate: Double?
            while offset + 8 <= data.count {
                let size = u32(offset + 4), start = offset + 8, end = start + size
                guard end <= data.count else { throw invalid }
                switch tag(offset) {
                case "fmt ":
                    guard size >= 16, u16(start) == 1, u16(start + 2) == 1,
                          u16(start + 12) == 2, u16(start + 14) == 16 else { throw invalid }
                    sampleRate = Double(u32(start + 4))
                case "data": pcm = start..<end
                default: break
                }
                offset = end + size % 2
            }
            guard let pcm, !pcm.isEmpty, pcm.count.isMultiple(of: 2),
                  let sampleRate, (8000...192000).contains(sampleRate) else { throw invalid }
            rate = sampleRate
            samples = stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map {
                Float(Int16(bitPattern: u16($0))) / 32768
            }
        }
    }

    struct Metrics: Encodable {
        var labelledInstants = 0, referenceVoiced = 0, referenceUnvoiced = 0
        var voicedDetected = 0, falseVoiced = 0, missedVoiced = 0
        var within50Cents = 0, octaveErrors = 0
        var within50PercentOfReferenceVoiced: Double?
        var medianAbsCentsWhenBothVoiced: Double?
        var p95AbsCentsWhenBothVoiced: Double?
    }

    static func main() {
        do { try compare() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func compare() throws {
        guard CommandLine.arguments.count == 3 else {
            throw InputError(message: "Usage: validate_recording.sh mono.wav reference.csv")
        }
        let audio = try Audio(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let config = PitchConfig.forCapture(sampleRate: audio.rate)
        let detector = YINPitchDetector(sampleRate: audio.rate, config: config)
        if let error = detector.configurationError { throw InputError(message: error) }
        var pitches: [Double?] = []
        audio.samples.withUnsafeBufferPointer { pcm in
            var offset = 0
            while offset + config.frameSize <= pcm.count {
                pitches.append(detector.analyze(pcm.baseAddress! + offset, count: config.frameSize,
                                                time: Double(offset + config.frameSize / 2) / audio.rate).rawFrequency)
                offset += config.hopSize
            }
        }
        let csv = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        var metrics = Metrics(), errors: [Double] = [], previousTime = -Double.infinity
        var intervals: [Double] = [], firstTime: Double?
        for (index, line) in csv.split(whereSeparator: \.isNewline).enumerated() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count == 2, let t = Double(columns[0].trimmingCharacters(in: .whitespaces)),
                  let hz = Double(columns[1].trimmingCharacters(in: .whitespaces)),
                  hz.isFinite, hz >= 0, t.isFinite, t >= 0, t > previousTime,
                  t <= Double(audio.samples.count) / audio.rate else {
                throw InputError(message: "Invalid reference row \\(index + 1). Expected increasing seconds, Hz (0 for unvoiced), inside the WAV.")
            }
            if previousTime.isFinite { intervals.append(t - previousTime) }
            else { firstTime = t }
            previousTime = t
            let nearest = Int(((t * audio.rate - Double(config.frameSize) / 2) / Double(config.hopSize)).rounded())
            let observed = pitches.indices.contains(nearest) ? pitches[nearest] : nil
            metrics.labelledInstants += 1
            if hz == 0 {
                metrics.referenceUnvoiced += 1
                if observed != nil { metrics.falseVoiced += 1 }
            } else {
                metrics.referenceVoiced += 1
                guard let f = observed else { metrics.missedVoiced += 1; continue }
                metrics.voicedDetected += 1
                let error = abs(PitchMath.cents(detected: f, expected: hz))
                errors.append(error)
                if error <= 50 { metrics.within50Cents += 1 }
                if abs(error - 1200) <= 50 { metrics.octaveErrors += 1 }
            }
        }
        guard let step = PitchMath.median(intervals), let firstTime,
              firstTime <= step * 1.5, Double(audio.samples.count) / audio.rate - previousTime <= step * 1.5,
              intervals.allSatisfy({ $0 >= 0.5 * step && $0 <= 1.5 * step }) else {
            throw InputError(message: "Provide a regular reference grid covering the entire recording, including silence.")
        }
        if metrics.referenceVoiced > 0 {
            metrics.within50PercentOfReferenceVoiced = 100 * Double(metrics.within50Cents) / Double(metrics.referenceVoiced)
        }
        if !errors.isEmpty {
            metrics.medianAbsCentsWhenBothVoiced = PitchMath.median(errors)
            metrics.p95AbsCentsWhenBothVoiced = errors.sorted()[Int(ceil(0.95 * Double(errors.count))) - 1]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(metrics), as: UTF8.self))
    }
}
